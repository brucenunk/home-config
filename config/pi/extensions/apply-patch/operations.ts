import { randomUUID } from "node:crypto";
import { constants, type Stats } from "node:fs";
import {
  access,
  type FileHandle,
  lstat,
  mkdir,
  open,
  realpath,
  rename,
  rmdir,
  stat,
  unlink,
  writeFile,
} from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { applyDiff } from "./apply-diff.ts";

export type ApplyPatchOperation = {
  type: "create_file" | "update_file" | "delete_file";
  path: string;
  diff?: string;
};

export type MutationQueue = <T>(path: string, operation: () => Promise<T>) => Promise<T>;

export type ApplyPatchResult = {
  operation: ApplyPatchOperation["type"];
  path: string;
  absolutePath: string;
};

export type AtomicUpdateHooks = {
  signal?: AbortSignal;
  afterRead?: () => void | Promise<void>;
  afterFinalRead?: () => void | Promise<void>;
  writeTempFile?: (file: FileHandle, content: string) => Promise<void>;
  onTempCreated?: (path: string) => void | Promise<void>;
  beforePublish?: () => Promise<void>;
  rename?: (oldPath: string, newPath: string) => Promise<void>;
  removeTempFile?: (path: string) => Promise<void>;
};

const directMutation: MutationQueue = async (_path, operation) => operation();

export async function applyPatchOperation(
  operation: ApplyPatchOperation,
  cwd: string,
  withMutationQueue: MutationQueue = directMutation,
  atomicUpdateHooks: AtomicUpdateHooks = {},
): Promise<ApplyPatchResult> {
  const path = normalizePath(operation.path);
  const absolutePath = resolve(cwd, path);

  // Register the lexical path immediately to preserve request order. Pi's
  // shared queue resolves canonical keys inside its serialized registration
  // step, so aliases share a queue without pre-queue filesystem awaits here.
  await withMutationQueue(absolutePath, async () => {
    // A call can be cancelled while waiting for another mutation of this path.
    atomicUpdateHooks.signal?.throwIfAborted();
    switch (operation.type) {
      case "create_file": {
        const content = applyDiff("", requireDiff(operation), "create");
        atomicUpdateHooks.signal?.throwIfAborted();
        await mkdir(dirname(absolutePath), { recursive: true });
        atomicUpdateHooks.signal?.throwIfAborted();
        await writeFile(absolutePath, content, {
          encoding: "utf8",
          flag: "wx",
        });
        break;
      }
      case "update_file": {
        const mutationPath = await realpath(absolutePath);
        const targetFile = await open(
          mutationPath,
          constants.O_RDONLY | constants.O_NONBLOCK,
        );
        try {
          const targetStat = await targetFile.stat();
          if (!targetStat.isFile()) {
            throw new Error(`apply_patch update target is not a regular file: ${path}`);
          }
          const current = await targetFile.readFile("utf8");
          await atomicUpdateHooks.afterRead?.();
          const updated = applyDiff(current, requireDiff(operation));
          // Keep the original inode open until atomicUpdate has checked the
          // path identity so an unlinked inode cannot be reused in between.
          await atomicUpdate(
            absolutePath,
            mutationPath,
            targetStat,
            current,
            updated,
            atomicUpdateHooks,
          );
        } finally {
          await targetFile.close();
        }
        break;
      }
      case "delete_file":
        atomicUpdateHooks.signal?.throwIfAborted();
        await unlink(absolutePath);
        break;
      default:
        throw new Error(`Unsupported apply_patch operation: ${String(operation.type)}`);
    }
  });

  return { operation: operation.type, path, absolutePath };
}

async function atomicUpdate(
  path: string,
  targetPath: string,
  openedTargetStat: Stats,
  expectedContent: string,
  content: string,
  hooks: AtomicUpdateHooks,
): Promise<void> {
  // Preserve write-through behavior for symlinks while publishing beside the
  // referent, so rename(2) does not replace the symlink itself.
  hooks.signal?.throwIfAborted();
  const targetStat = await stat(targetPath);
  if (
    targetStat.dev !== openedTargetStat.dev ||
    targetStat.ino !== openedTargetStat.ino
  ) {
    throw new Error(`apply_patch target changed after it was read: ${path}`);
  }
  if (!targetStat.isFile()) {
    throw new Error(`apply_patch update target is not a regular file: ${path}`);
  }
  if (targetStat.nlink !== 1) {
    throw new Error(`apply_patch refuses to replace a file with multiple hard links: ${path}`);
  }
  // Preserve the prior update authorization boundary: atomic replacement also
  // requires parent-directory access, but must not bypass an unwritable target.
  await access(targetPath, constants.W_OK);
  const targetDirectory = dirname(targetPath);
  const directoryStat = await stat(targetDirectory);
  if ((directoryStat.mode & 0o022) !== 0 && (directoryStat.mode & 0o1000) === 0) {
    throw new Error(
      `apply_patch refuses atomic update in a non-sticky shared-writable directory: ${targetDirectory}`,
    );
  }
  const tempDirectory = join(targetDirectory, `.apply-patch-${randomUUID()}`);
  await mkdir(tempDirectory, { mode: 0o700 });
  const tempPath = join(tempDirectory, "updated");
  const finalMode = targetStat.mode & 0o1777;
  let tempFile: FileHandle | undefined;
  let tempIdentity: Stats | undefined;
  let published = false;
  try {
    tempFile = await open(tempPath, "wx", 0o600);
    tempIdentity = await tempFile.stat();
    await hooks.onTempCreated?.(tempPath);
    await (hooks.writeTempFile ?? ((file, data) => file.writeFile(data, "utf8")))(
      tempFile,
      content,
    );
    const writtenStat = await tempFile.stat();
    if (writtenStat.uid !== targetStat.uid || writtenStat.gid !== targetStat.gid) {
      try {
        await tempFile.chown(targetStat.uid, targetStat.gid);
      } catch (error) {
        throw new Error(
          `apply_patch cannot preserve target ownership for atomic update: ${path}`,
          { cause: error },
        );
      }
    }
    // Match ordinary write semantics by retaining access and sticky bits while
    // clearing setuid/setgid after content modification.
    await tempFile.chmod(finalMode);
    hooks.signal?.throwIfAborted();
    await hooks.beforePublish?.();
    const latestFile = await open(
      targetPath,
      constants.O_RDONLY | constants.O_NONBLOCK,
    );
    let openedLatestStat: Stats;
    let latestStat: Stats;
    let latestContent: string;
    try {
      openedLatestStat = await latestFile.stat();
      if (!openedLatestStat.isFile()) {
        throw new Error(`apply_patch target changed during atomic update: ${path}`);
      }
      latestContent = await latestFile.readFile("utf8");
      await hooks.afterFinalRead?.();
      latestStat = await latestFile.stat();
    } finally {
      await latestFile.close();
    }
    const latestPathStat = await stat(targetPath);
    const latestRequestedTarget = await realpath(path);
    await access(targetPath, constants.W_OK);
    if (
      latestRequestedTarget !== targetPath ||
      openedLatestStat.dev !== latestStat.dev ||
      openedLatestStat.ino !== latestStat.ino ||
      openedLatestStat.mode !== latestStat.mode ||
      openedLatestStat.uid !== latestStat.uid ||
      openedLatestStat.gid !== latestStat.gid ||
      openedLatestStat.nlink !== latestStat.nlink ||
      openedLatestStat.size !== latestStat.size ||
      openedLatestStat.mtimeMs !== latestStat.mtimeMs ||
      latestPathStat.dev !== latestStat.dev ||
      latestPathStat.ino !== latestStat.ino ||
      latestPathStat.mode !== latestStat.mode ||
      latestPathStat.uid !== latestStat.uid ||
      latestPathStat.gid !== latestStat.gid ||
      latestPathStat.nlink !== latestStat.nlink ||
      latestPathStat.size !== latestStat.size ||
      latestPathStat.mtimeMs !== latestStat.mtimeMs ||
      latestStat.dev !== targetStat.dev ||
      latestStat.ino !== targetStat.ino ||
      latestStat.nlink !== 1 ||
      latestStat.mode !== targetStat.mode ||
      latestStat.uid !== targetStat.uid ||
      latestStat.gid !== targetStat.gid ||
      latestStat.size !== targetStat.size ||
      latestStat.mtimeMs !== targetStat.mtimeMs ||
      latestContent !== expectedContent
    ) {
      throw new Error(`apply_patch target changed during atomic update: ${path}`);
    }
    hooks.signal?.throwIfAborted();
    await tempFile.close();
    const publishStat = await lstat(tempPath);
    if (publishStat.dev !== tempIdentity.dev || publishStat.ino !== tempIdentity.ino) {
      throw new Error(`apply_patch temporary file changed during atomic update: ${path}`);
    }
    hooks.signal?.throwIfAborted();
    await (hooks.rename ?? rename)(tempPath, targetPath);
    published = true;
  } finally {
    await tempFile?.close().catch(() => undefined);
    if (!published) {
      // Cleanup is best effort and only removes the inode created above. A
      // cleanup error must not mask the publication error that caused it.
      const cleanupStat = await lstat(tempPath).catch(() => undefined);
      if (
        tempIdentity !== undefined &&
        cleanupStat?.dev === tempIdentity.dev &&
        cleanupStat.ino === tempIdentity.ino
      ) {
        await (hooks.removeTempFile ?? unlink)(tempPath).catch(() => undefined);
      }
    }
    // rmdir only removes the private staging directory when it is empty; it
    // cannot recursively delete an entry introduced by another actor.
    await rmdir(tempDirectory).catch(() => undefined);
  }
}

function normalizePath(path: string): string {
  const normalized = path.startsWith("@") ? path.slice(1) : path;
  if (!normalized) throw new Error("apply_patch path must not be empty");
  return normalized;
}

function requireDiff(operation: ApplyPatchOperation): string {
  if (typeof operation.diff !== "string") {
    throw new Error(`${operation.type} requires a V4A diff`);
  }
  return operation.diff;
}
