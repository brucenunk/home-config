import type { Theme, ToolDefinition } from "@earendil-works/pi-coding-agent";
import { type Component, truncateToWidth } from "@earendil-works/pi-tui";

const collapsedLines = 8;
const expandedLines = 80;
const maxPreviewCharacters = 16_000;

// Treat file paths, patch content, and error messages as text, not terminal
// instructions. Bound individual lines before applying theme escape sequences.
function plainText(text: string): string {
  return text.slice(0, 2_000).replace(/[\x00-\x1f\x7f-\x9f]/g, (character) =>
    character === "\t" ? "  " : `\\x${character.charCodeAt(0).toString(16).padStart(2, "0")}`,
  ) + (text.length > 2_000 ? "…" : "");
}

function component(lines: () => string[]): Component {
  return {
    render: (width) => lines().map((line) => truncateToWidth(line, Math.max(0, width))),
    // Styling is evaluated on every render, including after theme invalidation.
    invalidate() {},
  };
}

function operationFrom(args: unknown): { type?: string; path?: string; diff?: string } {
  if (!args || typeof args !== "object" || !("operation" in args)) return {};
  const operation = args.operation;
  if (!operation || typeof operation !== "object") return {};
  return {
    type: "type" in operation && typeof operation.type === "string" ? operation.type : undefined,
    path: "path" in operation && typeof operation.path === "string" ? operation.path : undefined,
    diff: "diff" in operation && typeof operation.diff === "string" ? operation.diff : undefined,
  };
}

function preview(text: string, limit: number, theme: Theme, diff = false): string[] {
  const bounded = text.slice(0, maxPreviewCharacters);
  const lines = bounded.split("\n", limit + 1);
  const truncated = text.length > bounded.length || lines.length > limit;
  const output = lines.slice(0, limit).map((line) => {
    const color = diff
      ? line.startsWith("+")
        ? "toolDiffAdded"
        : line.startsWith("-")
          ? "toolDiffRemoved"
          : "toolDiffContext"
      : "toolOutput";
    return theme.fg(color, plainText(line));
  });
  if (truncated) output.push(theme.fg("muted", "… preview truncated"));
  return output;
}

export const renderCall: NonNullable<ToolDefinition["renderCall"]> = (args, theme) => {
  const operation = operationFrom(args);
  const verb = operation.type === "create_file" ? "create"
    : operation.type === "update_file" ? "update"
      : operation.type === "delete_file" ? "delete" : "pending";
  return component(() => [
    theme.fg("toolTitle", theme.bold(`apply_patch ${verb}`)) +
      (operation.path ? ` ${theme.fg("accent", plainText(operation.path))}` : ""),
  ]);
};

export const renderResult: NonNullable<ToolDefinition["renderResult"]> = (
  result, { expanded, isPartial }, theme, context,
) => component(() => {
  if (isPartial) return [theme.fg("warning", "Applying patch…")];
  const text = result.content
    .filter((block) => block.type === "text")
    .map((block) => block.text)
    .join("\n");
  const limit = expanded ? expandedLines : collapsedLines;
  // Pi supplies error status through context, not result, in the TUI.
  if (context.isError) {
    return [theme.fg("error", "Patch failed"), ...preview(text, limit, theme)];
  }
  const output = [theme.fg("success", plainText(text || "Patch applied"))];
  const operation = operationFrom(context.args);
  if (operation.type !== "delete_file" && operation.diff !== undefined) {
    output.push(theme.fg("muted", "Submitted patch (not a computed filesystem diff):"));
    output.push(...preview(operation.diff, limit, theme, true));
    if (!expanded && (operation.diff.length > maxPreviewCharacters ||
      operation.diff.split("\n", collapsedLines + 1).length > collapsedLines)) {
      output.push(theme.fg("muted", "Expand tool output for more patch lines"));
    }
  }
  return output;
});