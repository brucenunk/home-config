import { StringEnum } from "@earendil-works/pi-ai";
import {
  type ExtensionAPI,
  withFileMutationQueue,
} from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { applyPatchOperation, type ApplyPatchOperation } from "./operations.ts";

const operationSchema = Type.Object({
  type: StringEnum(["create_file", "update_file", "delete_file"] as const, {
    description: "The file operation to perform",
  }),
  path: Type.String({
    minLength: 1,
    description: "File path, relative to the current working directory or absolute",
  }),
  diff: Type.Optional(
    Type.String({
      description:
        "Headerless V4A diff. Required for create_file and update_file; omit for delete_file",
    }),
  ),
});

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "apply_patch",
    label: "Apply Patch",
    description:
      "Create, update, or delete one file using an OpenAI-style operation. " +
      "For create_file, diff contains every file line prefixed with '+'. " +
      "For update_file, diff is a headerless V4A diff using @@ anchors and space/+/- line prefixes. " +
      "For delete_file, omit diff. Failed updates leave the file unchanged.",
    promptSnippet: "Create, update, or delete files using structured V4A diffs",
    promptGuidelines: [
      "Prefer apply_patch for file mutations; use edit or write only when apply_patch is unsuitable or a patch fails.",
    ],
    parameters: Type.Object({ operation: operationSchema }),

    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      const result = await applyPatchOperation(
        params.operation as ApplyPatchOperation,
        ctx.cwd,
        withFileMutationQueue,
        { signal },
      );
      const verb =
        result.operation === "create_file"
          ? "Created"
          : result.operation === "update_file"
            ? "Updated"
            : "Deleted";

      return {
        content: [{ type: "text", text: `${verb} ${result.path}` }],
        details: result,
      };
    },
  });
}
