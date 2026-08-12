// Adapted from OpenAI Agents JS's applyDiff implementation.
// Copyright (c) 2025 OpenAI. See LICENSE.

/** Apply a headerless V4A diff to file contents. */
export function applyDiff(
  input: string,
  diff: string,
  mode: "default" | "create" = "default",
): string {
  const diffLines = normalizeDiffLines(diff);

  if (mode === "create") {
    return parseCreateDiff(diffLines);
  }

  const chunks = parseUpdateDiff(diffLines, input);
  return applyChunks(input, chunks);
}

type Chunk = { origIndex: number; delLines: string[]; insLines: string[] };
type ParserState = { lines: string[]; index: number; fuzz: number };

const END_PATCH = "*** End Patch";
const END_FILE = "*** End of File";
const END_SECTION_MARKERS = [
  END_PATCH,
  "*** Update File:",
  "*** Delete File:",
  "*** Add File:",
  END_FILE,
];
const SECTION_TERMINATORS = [
  END_PATCH,
  "*** Update File:",
  "*** Delete File:",
  "*** Add File:",
];

function normalizeDiffLines(diff: string): string[] {
  return diff
    .split(/\r?\n/)
    .map((line) => line.replace(/\r$/, ""))
    .filter((line, index, lines) => !(index === lines.length - 1 && line === ""));
}

function isDone(state: ParserState, prefixes: string[]): boolean {
  if (state.index >= state.lines.length) return true;
  return prefixes.some((prefix) => state.lines[state.index]?.startsWith(prefix));
}

function readStr(state: ParserState, prefix: string): string {
  const current = state.lines[state.index];
  if (typeof current === "string" && current.startsWith(prefix)) {
    state.index += 1;
    return current.slice(prefix.length);
  }
  return "";
}

function parseCreateDiff(lines: string[]): string {
  const parser: ParserState = {
    lines: [...lines, END_PATCH],
    index: 0,
    fuzz: 0,
  };
  const output: string[] = [];

  while (!isDone(parser, SECTION_TERMINATORS)) {
    const line = parser.lines[parser.index];
    parser.index += 1;
    if (!line.startsWith("+")) {
      throw new Error(`Invalid Add File Line: ${line}`);
    }
    output.push(line.slice(1));
  }

  return output.join("\n");
}

function parseUpdateDiff(lines: string[], input: string): Chunk[] {
  const parser: ParserState = {
    lines: [...lines, END_PATCH],
    index: 0,
    fuzz: 0,
  };
  const inputLines = input.split("\n");
  const chunks: Chunk[] = [];
  let cursor = 0;

  while (!isDone(parser, END_SECTION_MARKERS)) {
    const anchor = readStr(parser, "@@ ");
    const hasBareAnchor = !anchor && parser.lines[parser.index] === "@@";
    if (hasBareAnchor) parser.index += 1;

    if (!(anchor || hasBareAnchor || cursor === 0)) {
      throw new Error(`Invalid Line:\n${parser.lines[parser.index]}`);
    }

    let anchorFound = false;
    if (anchor.trim()) {
      const advanced = advanceCursorToAnchor(anchor, inputLines, cursor, parser);
      cursor = advanced.cursor;
      anchorFound = advanced.found;
    }

    const { nextContext, sectionChunks, endIndex, eof } = readSection(
      parser.lines,
      parser.index,
    );
    if (anchor.trim() && !anchorFound && nextContext.length === 0) {
      throw new Error(`Invalid Context ${cursor}: anchor not found: ${anchor}`);
    }
    const match = findContext(inputLines, nextContext, cursor, eof);

    if (match.newIndex === -1) {
      const context = nextContext.join("\n");
      if (eof) throw new Error(`Invalid EOF Context ${cursor}:\n${context}`);
      throw new Error(`Invalid Context ${cursor}:\n${context}`);
    }

    parser.fuzz += match.fuzz;
    for (const chunk of sectionChunks) {
      chunks.push({ ...chunk, origIndex: chunk.origIndex + match.newIndex });
    }

    cursor = match.newIndex + nextContext.length;
    parser.index = endIndex;
  }

  return chunks;
}

function advanceCursorToAnchor(
  anchor: string,
  inputLines: string[],
  cursor: number,
  parser: ParserState,
): { cursor: number; found: boolean } {
  for (let index = cursor; index < inputLines.length; index += 1) {
    if (inputLines[index] === anchor) {
      return { cursor: index + 1, found: true };
    }
  }

  for (let index = cursor; index < inputLines.length; index += 1) {
    if (inputLines[index].trim() === anchor.trim()) {
      parser.fuzz += 1;
      return { cursor: index + 1, found: true };
    }
  }

  return { cursor, found: false };
}

function readSection(
  lines: string[],
  startIndex: number,
): {
  nextContext: string[];
  sectionChunks: Chunk[];
  endIndex: number;
  eof: boolean;
} {
  const context: string[] = [];
  let delLines: string[] = [];
  let insLines: string[] = [];
  const sectionChunks: Chunk[] = [];
  let mode: "keep" | "add" | "delete" = "keep";
  let index = startIndex;
  const origIndex = index;

  while (index < lines.length) {
    const raw = lines[index];
    if (
      raw.startsWith("@@") ||
      raw.startsWith(END_PATCH) ||
      raw.startsWith("*** Update File:") ||
      raw.startsWith("*** Delete File:") ||
      raw.startsWith("*** Add File:") ||
      raw.startsWith(END_FILE)
    ) {
      break;
    }
    if (raw === "***") break;
    if (raw.startsWith("***")) throw new Error(`Invalid Line: ${raw}`);

    index += 1;
    const lastMode = mode;
    let line = raw || " ";

    if (line[0] === "+") mode = "add";
    else if (line[0] === "-") mode = "delete";
    else if (line[0] === " ") mode = "keep";
    else throw new Error(`Invalid Line: ${line}`);

    line = line.slice(1);

    if (mode === "keep" && lastMode !== mode && (insLines.length || delLines.length)) {
      sectionChunks.push({
        origIndex: context.length - delLines.length,
        delLines,
        insLines,
      });
      delLines = [];
      insLines = [];
    }

    if (mode === "delete") {
      delLines.push(line);
      context.push(line);
    } else if (mode === "add") {
      insLines.push(line);
    } else {
      context.push(line);
    }
  }

  if (insLines.length || delLines.length) {
    sectionChunks.push({
      origIndex: context.length - delLines.length,
      delLines,
      insLines,
    });
  }

  if (index < lines.length && lines[index] === END_FILE) {
    return {
      nextContext: context,
      sectionChunks,
      endIndex: index + 1,
      eof: true,
    };
  }

  if (index === origIndex) {
    throw new Error(`Nothing in this section - index=${index} ${lines[index]}`);
  }

  return { nextContext: context, sectionChunks, endIndex: index, eof: false };
}

function findContext(
  lines: string[],
  context: string[],
  start: number,
  eof: boolean,
): { newIndex: number; fuzz: number } {
  if (eof) {
    const endStart = Math.max(0, lines.length - context.length);
    const endMatch = findContextCore(lines, context, endStart);
    if (endMatch.newIndex !== -1) return endMatch;
    const fallback = findContextCore(lines, context, start);
    return { newIndex: fallback.newIndex, fuzz: fallback.fuzz + 10000 };
  }
  return findContextCore(lines, context, start);
}

function findContextCore(
  lines: string[],
  context: string[],
  start: number,
): { newIndex: number; fuzz: number } {
  if (!context.length) return { newIndex: start, fuzz: 0 };

  for (let index = start; index < lines.length; index += 1) {
    if (equalsSlice(lines, context, index, (line) => line)) {
      return { newIndex: index, fuzz: 0 };
    }
  }
  for (let index = start; index < lines.length; index += 1) {
    if (equalsSlice(lines, context, index, (line) => line.trimEnd())) {
      return { newIndex: index, fuzz: 1 };
    }
  }
  for (let index = start; index < lines.length; index += 1) {
    if (equalsSlice(lines, context, index, (line) => line.trim())) {
      return { newIndex: index, fuzz: 100 };
    }
  }

  return { newIndex: -1, fuzz: 0 };
}

function equalsSlice(
  source: string[],
  target: string[],
  start: number,
  map: (value: string) => string,
): boolean {
  if (start + target.length > source.length) return false;
  for (let index = 0; index < target.length; index += 1) {
    if (map(source[start + index]) !== map(target[index])) return false;
  }
  return true;
}

function applyChunks(input: string, chunks: Chunk[]): string {
  const origLines = input.split("\n");
  const destLines: string[] = [];
  let origIndex = 0;

  for (const chunk of chunks) {
    if (chunk.origIndex > origLines.length) {
      throw new Error(
        `applyDiff: chunk.origIndex ${chunk.origIndex} > input length ${origLines.length}`,
      );
    }
    if (origIndex > chunk.origIndex) {
      throw new Error(
        `applyDiff: overlapping chunk at ${chunk.origIndex} (cursor ${origIndex})`,
      );
    }

    destLines.push(...origLines.slice(origIndex, chunk.origIndex));
    origIndex = chunk.origIndex;
    destLines.push(...chunk.insLines);
    origIndex += chunk.delLines.length;
  }

  destLines.push(...origLines.slice(origIndex));
  return destLines.join("\n");
}
