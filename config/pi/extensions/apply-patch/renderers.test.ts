import assert from "node:assert/strict";
import test from "node:test";
import { visibleWidth } from "@earendil-works/pi-tui";
import { renderCall, renderResult } from "./renderers.ts";

// A small theme double keeps assertions independent of palette/terminal mode.
// Real Pi loading and HTML conversion are checked separately.
const colors: string[] = [];
const theme = {
  fg(color: string, text: string) { colors.push(color); return text; },
  bold: (text: string) => text,
} as Parameters<typeof renderCall>[1];

function context(args: unknown = {}, isError = false) {
  return {
    args, isError, toolCallId: "test", invalidate() {}, lastComponent: undefined,
    state: {}, cwd: "/workspace", executionStarted: true, argsComplete: true,
    isPartial: false, expanded: false, showImages: false,
  };
}

function result(text: string, args: unknown = {}, options = { expanded: false, isPartial: false }, isError = false) {
  return renderResult({ content: [{ type: "text", text }], details: undefined },
    options, theme, context(args, isError));
}

test("call headers distinguish create, update, and delete", () => {
  for (const [type, verb] of [["create_file", "create"], ["update_file", "update"], ["delete_file", "delete"]]) {
    assert.deepEqual(renderCall({ operation: { type, path: "src/file.ts" } }, theme, context()).render(100),
      [`apply_patch ${verb} src/file.ts`]);
  }
});

test("call rendering tolerates missing, partial, and malformed arguments", () => {
  for (const args of [undefined, null, {}, { operation: null }, { operation: "bad" },
    { operation: { path: 123, type: [], diff: {} } }]) {
    assert.deepEqual(renderCall(args, theme, context()).render(100), ["apply_patch pending"]);
  }
  assert.deepEqual(renderCall({ operation: { type: "update_file" } }, theme, context()).render(100),
    ["apply_patch update"]);
});

test("successful create/update results show labeled submitted patches and diff colors", () => {
  for (const type of ["create_file", "update_file"]) {
    colors.length = 0;
    const lines = result("Updated file.ts", { operation: { type, diff: "@@ anchor\n-old\n+new\n context" } }).render(100);
    assert.equal(lines[0], "Updated file.ts");
    assert.match(lines[1], /Submitted patch.*not a computed filesystem diff/);
    assert.deepEqual(lines.slice(2), ["@@ anchor", "-old", "+new", " context"]);
    assert.ok(colors.includes("toolDiffAdded"));
    assert.ok(colors.includes("toolDiffRemoved"));
    assert.ok(colors.includes("toolDiffContext"));
  }
});

test("delete and historical results without arguments/details remain readable", () => {
  assert.deepEqual(result("Deleted file.ts", { operation: { type: "delete_file", diff: "+ignored" } }).render(100),
    ["Deleted file.ts"]);
  assert.deepEqual(result("Created file.ts").render(100), ["Created file.ts"]);
});

test("partial results are not shown as successful", () => {
  colors.length = 0;
  assert.deepEqual(result("", {}, { expanded: false, isPartial: true }).render(100), ["Applying patch…"]);
  assert.ok(!colors.includes("success"));
});

test("failed results show errors, never a success or applied patch preview", () => {
  colors.length = 0;
  const lines = result("Invalid Context\nmissing anchor", { operation: { diff: "+not applied" } },
    { expanded: false, isPartial: false }, true).render(100);
  assert.deepEqual(lines, ["Patch failed", "Invalid Context", "missing anchor"]);
  assert.ok(colors.includes("error"));
  assert.ok(!colors.includes("success"));
});

test("expansion reveals more lines, with bounded previews and explicit truncation", () => {
  const args = { operation: { type: "update_file", diff: Array.from({ length: 100 }, (_, i) => `+line ${i}`).join("\n") } };
  const collapsed = result("Updated file.ts", args).render(100);
  const expanded = result("Updated file.ts", args, { expanded: true, isPartial: false }).render(100);
  assert.equal(collapsed.filter((line) => line.startsWith("+line")).length, 8);
  assert.equal(expanded.filter((line) => line.startsWith("+line")).length, 80);
  assert.ok(collapsed.some((line) => line.includes("Expand tool output")));
  assert.ok(expanded.some((line) => line.includes("preview truncated")));
  const huge = result("Updated file.ts", { operation: { diff: "+" + "x".repeat(30_000) } },
    { expanded: true, isPartial: false }).render(100);
  assert.ok(huge.some((line) => line.includes("preview truncated")));
});

test("error previews are bounded and expandable too", () => {
  const text = Array.from({ length: 100 }, (_, i) => `error ${i}`).join("\n");
  for (const expanded of [false, true]) {
    const lines = result(text, {}, { expanded, isPartial: false }, true).render(100);
    assert.equal(lines.filter((line) => line.startsWith("error ")).length, expanded ? 80 : 8);
    assert.equal(lines.at(-1), "… preview truncated");
  }
});

test("narrow widths and Unicode never exceed the supplied terminal width", () => {
  const args = { operation: { type: "create_file", path: "目录/🙂.ts", diff: "+🙂界e\u0301\twide" } };
  for (const width of [0, 1, 2, 5, 10, 80]) {
    for (const rendered of [renderCall(args, theme, context()), result("Created 目录/🙂.ts", args)]) {
      for (const line of rendered.render(width)) assert.ok(visibleWidth(line) <= width, `${width}: ${line}`);
    }
  }
});

test("terminal controls in paths, diffs, and errors are displayed as text", () => {
  const args = { operation: { type: "create_file", path: "bad\x1b[2J\nname", diff: "+\x1b[31mred\r\x07" } };
  for (const rendered of [renderCall(args, theme, context()), result("Created file", args), result("error\x1b]0;title\x07", {}, undefined, true)]) {
    const text = rendered.render(100).join("\n");
    assert.ok(!/[\x1b\x07\r]/.test(text));
    assert.match(text, /\\x1b/);
  }
});

test("rendering reevaluates the theme after invalidation", () => {
  let prefix = "first:";
  const changingTheme = { fg: (_color: string, text: string) => prefix + text, bold: (text: string) => text } as typeof theme;
  const rendered = renderCall({}, changingTheme, context());
  assert.match(rendered.render(100)[0], /^first:/);
  prefix = "second:";
  rendered.invalidate();
  assert.match(rendered.render(100)[0], /^second:/);
});