import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import {
  chmod,
  link,
  lstat,
  mkdtemp,
  readFile,
  realpath,
  readdir,
  rm,
  stat,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { promisify } from "node:util";
import { applyDiff } from "./apply-diff.ts";
import { applyPatchOperation } from "./operations.ts";

const execFileAsync = promisify(execFile);

async function workspace(): Promise<string> {
  return mkdtemp(join(tmpdir(), "pi-apply-patch-test-"));
}

async function assertNoUpdateTemps(directory: string): Promise<void> {
  assert.deepEqual(
    (await readdir(directory)).filter((entry) => entry.includes(".apply-patch-")),
    [],
  );
}

async function snapshot(path: string) {
  const metadata = await stat(path);
  return {
    content: await readFile(path, "utf8"),
    dev: metadata.dev,
    gid: metadata.gid,
    ino: metadata.ino,
    mode: metadata.mode,
    mtimeMs: metadata.mtimeMs,
    size: metadata.size,
    uid: metadata.uid,
  };
}

test("create mode accepts plus-prefixed content and preserves a trailing newline", () => {
  assert.equal(applyDiff("", "+hello\n+world\n+", "create"), "hello\nworld\n");
});

test("create mode rejects unprefixed content", () => {
  assert.throws(() => applyDiff("", "+valid\ninvalid", "create"), /Invalid Add File Line/);
});

test("update mode applies anchored replacements and multiple hunks", () => {
  const input = "function one() {\n  return 1;\n}\n\nfunction two() {\n  return 2;\n}\n";
  const diff = [
    "@@ function one() {",
    "-  return 1;",
    "+  return 10;",
    " }",
    "@@ function two() {",
    "-  return 2;",
    "+  return 20;",
    " }",
  ].join("\n");

  assert.equal(
    applyDiff(input, diff),
    "function one() {\n  return 10;\n}\n\nfunction two() {\n  return 20;\n}\n",
  );
});

test("update mode rejects mismatched context", () => {
  assert.throws(
    () => applyDiff("one\ntwo\n", "@@\n missing\n-two\n+second"),
    /Invalid Context/,
  );
});

test("update mode rejects a pure insertion after a missing anchor", () => {
  assert.throws(
    () => applyDiff("one\ntwo\n", "@@ missing-anchor\n+inserted"),
    /anchor not found/,
  );
});

test("update mode searches forward for repeated anchors", () => {
  const input = "anchor\none\nanchor\ntwo\n";
  const diff = [
    "@@ anchor",
    "-one",
    "+ONE",
    "@@ anchor",
    "+inserted",
  ].join("\n");

  assert.equal(applyDiff(input, diff), "anchor\nONE\nanchor\ninserted\ntwo\n");
});

test("create_file creates parent directories and refuses to overwrite", async () => {
  const cwd = await workspace();
  const operation = {
    type: "create_file" as const,
    path: "nested/file.txt",
    diff: "+hello\n+",
  };

  await applyPatchOperation(operation, cwd);
  assert.equal(await readFile(join(cwd, "nested/file.txt"), "utf8"), "hello\n");
  await assert.rejects(() => applyPatchOperation(operation, cwd), /exist/i);
});

test("update_file resolves @ paths, uses the mutation queue, and preserves newlines", async () => {
  const cwd = await workspace();
  const path = join(cwd, "file.txt");
  await writeFile(path, "one\ntwo\n", "utf8");
  const queuedPaths: string[] = [];

  await applyPatchOperation(
    { type: "update_file", path: "@file.txt", diff: "@@ one\n-two\n+second" },
    cwd,
    async (queuedPath, operation) => {
      queuedPaths.push(queuedPath);
      return operation();
    },
  );

  assert.deepEqual(queuedPaths, [path]);
  assert.equal(await readFile(path, "utf8"), "one\nsecond\n");
  await assertNoUpdateTemps(cwd);
});

test("an atomic update preserves permission bits", async () => {
  const cwd = await workspace();
  const path = join(cwd, "file.txt");
  await writeFile(path, "original\n", "utf8");
  await chmod(path, 0o640);
  const before = await stat(path);

  await applyPatchOperation(
    { type: "update_file", path: "file.txt", diff: "@@\n-original\n+replacement" },
    cwd,
  );

  assert.equal(await readFile(path, "utf8"), "replacement\n");
  const after = await stat(path);
  assert.equal(after.mode & 0o7777, 0o640);
  assert.equal(after.uid, before.uid);
  assert.equal(after.gid, before.gid);
  await assertNoUpdateTemps(cwd);
});

test("an atomic update keeps temporary content private and clears set-id bits", async (t) => {
  const cwd = await workspace();
  const path = join(cwd, "file.txt");
  await writeFile(path, "original\n", "utf8");
  try {
    await chmod(path, 0o6750);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "EPERM") {
      t.skip("the build filesystem does not permit setting set-id bits");
      return;
    }
    throw error;
  }
  let temporaryDirectoryMode: number | undefined;
  let temporaryMode: number | undefined;

  await applyPatchOperation(
    { type: "update_file", path: "file.txt", diff: "@@\n-original\n+replacement" },
    cwd,
    undefined,
    {
      onTempCreated: async (tempPath) => {
        temporaryDirectoryMode = (await stat(join(tempPath, ".."))).mode & 0o7777;
      },
      writeTempFile: async (tempFile, content) => {
        await tempFile.writeFile(content, "utf8");
        temporaryMode = (await tempFile.stat()).mode & 0o7777;
      },
    },
  );

  assert.equal(temporaryDirectoryMode, 0o700);
  assert.equal(temporaryMode, 0o600);
  assert.equal((await stat(path)).mode & 0o7777, 0o750);
  await assertNoUpdateTemps(cwd);
});

test("an atomic update follows a symlink and preserves the link", async () => {
  const cwd = await workspace();
  const targetPath = join(cwd, "target.txt");
  const linkPath = join(cwd, "link.txt");
  await writeFile(targetPath, "original\n", "utf8");
  await chmod(targetPath, 0o600);
  await symlink("target.txt", linkPath);
  const canonicalQueueKeys: string[] = [];
  const queuedPaths: string[] = [];

  await applyPatchOperation(
    { type: "update_file", path: "link.txt", diff: "@@\n-original\n+replacement" },
    cwd,
    async (queuedPath, operation) => {
      queuedPaths.push(queuedPath);
      canonicalQueueKeys.push(await realpath(queuedPath));
      return operation();
    },
  );

  assert.deepEqual(queuedPaths, [linkPath]);
  assert.deepEqual(canonicalQueueKeys, [await realpath(targetPath)]);
  assert.equal((await lstat(linkPath)).isSymbolicLink(), true);
  assert.equal(await readFile(targetPath, "utf8"), "replacement\n");
  assert.equal((await stat(targetPath)).mode & 0o777, 0o600);
  await assertNoUpdateTemps(cwd);
});

test("an update refuses to break hard links", async () => {
  const cwd = await workspace();
  const path = join(cwd, "file.txt");
  const otherPath = join(cwd, "other.txt");
  await writeFile(path, "original\n", "utf8");
  await link(path, otherPath);
  const before = await snapshot(path);

  await assert.rejects(
    () =>
      applyPatchOperation(
        { type: "update_file", path: "file.txt", diff: "@@\n-original\n+replacement" },
        cwd,
      ),
    /multiple hard links/,
  );

  assert.deepEqual(await snapshot(path), before);
  assert.equal(await readFile(otherPath, "utf8"), "original\n");
  await assertNoUpdateTemps(cwd);
});

test("an update does not bypass target write permissions", async () => {
  const cwd = await workspace();
  const path = join(cwd, "file.txt");
  await writeFile(path, "original\n", "utf8");
  await chmod(path, 0o444);
  const before = await snapshot(path);

  await assert.rejects(
    () =>
      applyPatchOperation(
        { type: "update_file", path: "file.txt", diff: "@@\n-original\n+replacement" },
        cwd,
      ),
    /EACCES|permission denied/i,
  );

  assert.deepEqual(await snapshot(path), before);
  await assertNoUpdateTemps(cwd);
});

test("an update supports a maximum-length target basename", async () => {
  const cwd = await workspace();
  const basename = "a".repeat(255);
  const path = join(cwd, basename);
  await writeFile(path, "original\n", "utf8");

  await applyPatchOperation(
    { type: "update_file", path: basename, diff: "@@\n-original\n+replacement" },
    cwd,
  );

  assert.equal(await readFile(path, "utf8"), "replacement\n");
  await assertNoUpdateTemps(cwd);
});

for (const [name, hooks] of [
  [
    "temporary-file setup failure",
    { onTempCreated: async () => Promise.reject(new Error("injected setup failure")) },
  ],
  [
    "temporary-file write failure",
    {
      writeTempFile: async (tempFile) => {
        await tempFile.writeFile("partial", "utf8");
        throw new Error("injected write failure");
      },
    },
  ],
  [
    "rename failure",
    { rename: async () => Promise.reject(new Error("injected rename failure")) },
  ],
] as const) {
  test(`${name} leaves target bytes and metadata unchanged`, async () => {
    const cwd = await workspace();
    const path = join(cwd, "file.txt");
    await writeFile(path, "original\n", "utf8");
    await chmod(path, 0o640);
    const before = await snapshot(path);

    await assert.rejects(
      () =>
        applyPatchOperation(
          { type: "update_file", path: "file.txt", diff: "@@\n-original\n+replacement" },
          cwd,
          undefined,
          hooks,
        ),
      /injected/,
    );

    assert.deepEqual(await snapshot(path), before);
    await assertNoUpdateTemps(cwd);
  });
}

test("cancellation before publication leaves target bytes and metadata unchanged", async () => {
  const cwd = await workspace();
  const path = join(cwd, "file.txt");
  await writeFile(path, "original\n", "utf8");
  await chmod(path, 0o640);
  const before = await snapshot(path);
  const controller = new AbortController();

  await assert.rejects(
    () =>
      applyPatchOperation(
        { type: "update_file", path: "file.txt", diff: "@@\n-original\n+replacement" },
        cwd,
        undefined,
        {
          signal: controller.signal,
          beforePublish: async () => {
            controller.abort();
          },
        },
      ),
    { name: "AbortError" },
  );

  assert.deepEqual(await snapshot(path), before);
  await assertNoUpdateTemps(cwd);
});

test("a concurrent target replacement is not overwritten", async () => {
  const cwd = await workspace();
  const path = join(cwd, "file.txt");
  await writeFile(path, "original\n", "utf8");

  await assert.rejects(
    () =>
      applyPatchOperation(
        { type: "update_file", path: "file.txt", diff: "@@\n-original\n+replacement" },
        cwd,
        undefined,
        {
          beforePublish: async () => {
            await rm(path);
            await writeFile(path, "concurrent\n", "utf8");
          },
        },
      ),
    /target changed during atomic update/,
  );

  assert.equal(await readFile(path, "utf8"), "concurrent\n");
  await assertNoUpdateTemps(cwd);
});

test("an identical replacement after reading is not overwritten", async () => {
  const cwd = await workspace();
  const path = join(cwd, "file.txt");
  await writeFile(path, "original\n", "utf8");

  await assert.rejects(
    () =>
      applyPatchOperation(
        { type: "update_file", path: "file.txt", diff: "@@\n-original\n+replacement" },
        cwd,
        undefined,
        {
          afterRead: async () => {
            await rm(path);
            await writeFile(path, "original\n", "utf8");
          },
        },
      ),
    /target changed after it was read/,
  );

  assert.equal(await readFile(path, "utf8"), "original\n");
  await assertNoUpdateTemps(cwd);
});

test("a concurrently added hard link prevents publication", async () => {
  const cwd = await workspace();
  const path = join(cwd, "file.txt");
  const otherPath = join(cwd, "other.txt");
  await writeFile(path, "original\n", "utf8");

  await assert.rejects(
    () =>
      applyPatchOperation(
        { type: "update_file", path: "file.txt", diff: "@@\n-original\n+replacement" },
        cwd,
        undefined,
        { beforePublish: async () => link(path, otherPath) },
      ),
    /target changed during atomic update/,
  );

  assert.equal(await readFile(path, "utf8"), "original\n");
  assert.equal(await readFile(otherPath, "utf8"), "original\n");
  await assertNoUpdateTemps(cwd);
});

test("a concurrently retargeted symlink prevents publication", async () => {
  const cwd = await workspace();
  const targetPath = join(cwd, "target.txt");
  const otherPath = join(cwd, "other.txt");
  const linkPath = join(cwd, "link.txt");
  await writeFile(targetPath, "original\n", "utf8");
  await writeFile(otherPath, "other\n", "utf8");
  await symlink("target.txt", linkPath);

  await assert.rejects(
    () =>
      applyPatchOperation(
        { type: "update_file", path: "link.txt", diff: "@@\n-original\n+replacement" },
        cwd,
        undefined,
        {
          beforePublish: async () => {
            await rm(linkPath);
            await symlink("other.txt", linkPath);
          },
        },
      ),
    /target changed during atomic update/,
  );

  assert.equal(await readFile(targetPath, "utf8"), "original\n");
  assert.equal(await readFile(otherPath, "utf8"), "other\n");
  await assertNoUpdateTemps(cwd);
});

test("a concurrent replacement with a FIFO is rejected without reading it", async () => {
  const cwd = await workspace();
  const path = join(cwd, "file.txt");
  await writeFile(path, "original\n", "utf8");

  await assert.rejects(
    () =>
      applyPatchOperation(
        { type: "update_file", path: "file.txt", diff: "@@\n-original\n+replacement" },
        cwd,
        undefined,
        {
          beforePublish: async () => {
            await rm(path);
            await execFileAsync("mkfifo", [path]);
          },
        },
      ),
    /target changed during atomic update/,
  );

  assert.equal((await lstat(path)).isFIFO(), true);
  await rm(path);
  await assertNoUpdateTemps(cwd);
});

test("an in-place change during final validation is not overwritten", async () => {
  const cwd = await workspace();
  const path = join(cwd, "file.txt");
  await writeFile(path, "original\n", "utf8");

  await assert.rejects(
    () =>
      applyPatchOperation(
        { type: "update_file", path: "file.txt", diff: "@@\n-original\n+replacement" },
        cwd,
        undefined,
        { afterFinalRead: async () => writeFile(path, "concurrent\n", "utf8") },
      ),
    /target changed during atomic update/,
  );

  assert.equal(await readFile(path, "utf8"), "concurrent\n");
  await assertNoUpdateTemps(cwd);
});

test("successful publication does not unlink the vacated temporary path", async () => {
  const cwd = await workspace();
  const path = join(cwd, "file.txt");
  await writeFile(path, "original\n", "utf8");
  let cleanupAttempted = false;

  await applyPatchOperation(
    { type: "update_file", path: "file.txt", diff: "@@\n-original\n+replacement" },
    cwd,
    undefined,
    {
      removeTempFile: async () => {
        cleanupAttempted = true;
        throw new Error("injected cleanup failure");
      },
    },
  );

  assert.equal(await readFile(path, "utf8"), "replacement\n");
  assert.equal(cleanupAttempted, false);
  await assertNoUpdateTemps(cwd);
});

test("cleanup failure after publication failure preserves the publication error", async () => {
  const cwd = await workspace();
  const path = join(cwd, "file.txt");
  await writeFile(path, "original\n", "utf8");
  let tempPath: string | undefined;

  await assert.rejects(
    () =>
      applyPatchOperation(
        { type: "update_file", path: "file.txt", diff: "@@\n-original\n+replacement" },
        cwd,
        undefined,
        {
          onTempCreated: (candidatePath) => {
            tempPath = candidatePath;
          },
          rename: async () => Promise.reject(new Error("injected publication failure")),
          removeTempFile: async () => Promise.reject(new Error("injected cleanup failure")),
        },
      ),
    /injected publication failure/,
  );

  assert.equal(await readFile(path, "utf8"), "original\n");
  assert.ok(tempPath);
  assert.equal((await lstat(tempPath)).isFile(), true);
  await rm(tempPath);
});

test("a failed update leaves existing content unchanged", async () => {
  const cwd = await workspace();
  const path = join(cwd, "file.txt");
  await writeFile(path, "original\n", "utf8");

  await assert.rejects(
    () =>
      applyPatchOperation(
        { type: "update_file", path: "file.txt", diff: "@@\n-missing\n+replacement" },
        cwd,
      ),
    /Invalid Context/,
  );
  assert.equal(await readFile(path, "utf8"), "original\n");
});

test("create_file and update_file require a diff", async () => {
  const cwd = await workspace();
  await assert.rejects(
    () => applyPatchOperation({ type: "create_file", path: "file.txt" }, cwd),
    /requires a V4A diff/,
  );
});

test("create_file and delete_file honor cancellation after queueing", async () => {
  const cwd = await workspace();
  const path = join(cwd, "file.txt");
  await writeFile(path, "keep me", "utf8");
  const controller = new AbortController();
  controller.abort();

  for (const operation of [
    { type: "create_file" as const, path: "new.txt", diff: "+new" },
    { type: "delete_file" as const, path: "file.txt" },
  ]) {
    await assert.rejects(
      () => applyPatchOperation(operation, cwd, undefined, { signal: controller.signal }),
      { name: "AbortError" },
    );
  }

  await assert.rejects(() => readFile(join(cwd, "new.txt"), "utf8"), /ENOENT/);
  assert.equal(await readFile(path, "utf8"), "keep me");
});

test("delete_file removes an existing file and fails for a missing file", async () => {
  const cwd = await workspace();
  const path = join(cwd, "file.txt");
  await writeFile(path, "remove me", "utf8");

  await applyPatchOperation({ type: "delete_file", path: "file.txt" }, cwd);
  await assert.rejects(() => readFile(path, "utf8"), /ENOENT/);
  await assert.rejects(
    () => applyPatchOperation({ type: "delete_file", path: "file.txt" }, cwd),
    /ENOENT/,
  );
});
