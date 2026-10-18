import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { fetchText } from "./fetch.ts";
import { search } from "./search.ts";

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "web_search",
    label: "Web Search",
    description: "Search the public web for a query using the selected OpenAI Responses model's hosted search. Use this tool for public web searches rather than shell HTTP clients. For GitHub-specific lookups, use gh or gh api instead; never use curl, wget, or another direct HTTP client for GitHub, even if this tool fails or is unavailable. If gh cannot access the required content, report the limitation. Returns a model-synthesized answer with source URLs, not exact source text. Sends only this query, not session history. Incurs nested model usage and additional search fees. Requires a compatible openai-responses model/gateway.",
    parameters: Type.Object({ query: Type.String({ minLength: 1, maxLength: 2000 }) }),
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: false, openWorldHint: true },
    async execute(_id, params, signal, _update, ctx) {
      return search(params.query, ctx, signal);
    },
  });
  pi.registerTool({
    name: "web_fetch",
    label: "Web Fetch",
    description: "Retrieve a specific public HTTP(S) URL as source text, not a summary. Use this tool for public web retrieval rather than shell HTTP clients. For GitHub URLs (including raw content and API URLs), use gh or gh api instead; never use curl, wget, or another direct HTTP client for GitHub, even if this tool fails or is unavailable. If gh cannot access the required content, report the limitation. Declared HTML and detected whole HTML documents are extracted to readable text with links. Other text/Markdown is literal: embedded HTML and code examples are preserved, not sanitized. Returns 12000-character chunks with explicit hash-checked continuation. No JavaScript/browser, authenticated pages, private/local URLs, PDFs or access-control bypass. 2 MiB download and 200000-character extraction limits.",
    parameters: Type.Object({
      url: Type.String({ minLength: 1, maxLength: 4096 }),
      offset: Type.Optional(Type.Integer({ minimum: 0, maximum: 200000, description: "Omit or use 0 for the first chunk; use next_offset from the previous result to continue." })),
      expected_sha256: Type.Optional(Type.String({ pattern: "^[a-f0-9]{64}$", description: "Only for continuation: copy sha256 from the previous result. Do not guess. Ignored at offset 0." })),
    }),
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true },
    async execute(_id, params, signal) {
      return fetchText(params.url, params.offset, params.expected_sha256, signal);
    },
  });
}