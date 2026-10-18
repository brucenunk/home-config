import assert from "node:assert/strict";
import { test } from "node:test";
import { createServer } from "node:http";
import { chunkText, download, fetchText, htmlDocument, htmlText, publicAddress, publicLookup, requestPage, validateUrl } from "./fetch.ts";
import { SearchEvidence, search, searchPayload, searchResult, sourceUrl } from "./search.ts";

const signal = () => AbortSignal.timeout(2000);
const usage = { input: 10, output: 4, cacheRead: 2, cacheWrite: 0, totalTokens: 16, cost: { input: 1, output: 2, cacheRead: 0, cacheWrite: 0, total: 3 } };
const message: any = { provider: "fixture", model: "fixture", stopReason: "stop", content: [{ type: "text", text: "Synthesized answer." }], usage };
function evidence() {
  const e = new SearchEvidence();
  e.observe({ type: "response.output_item.done", item: { type: "web_search_call", status: "completed", action: { type: "search", sources: [{ url: "https://example.com/doc" }] } } });
  e.observe({ type: "response.output_item.done", item: { type: "message", content: [{ annotations: [{ type: "url_citation", title: "Docs", url: "https://example.com/doc", start_index: 1, end_index: 7 }] }] } });
  e.observe({ type: "response.completed", response: { status: "completed" } });
  return e;
}

test("hosted request requires web_search, not preview; disables storage", () => {
  const p = searchPayload({ model: "fixture", tools: [{ type: "function" }] });
  assert.deepEqual(p.tools, [{ type: "web_search", search_context_size: "low" }]);
  assert.equal(p.tool_choice, "required");
  assert.equal(p.store, false);
  assert.deepEqual(p.include, ["web_search_call.action.sources"]);
});

test("citation offsets, URLs, completed actions and usage survive into text/details", () => {
  const result = searchResult(message, evidence());
  assert.equal(result.isError, undefined);
  assert.equal(result.usage, usage);
  assert.equal(result.details.citations[0].start_index, 1);
  assert.equal(result.details.sources.length, 1);
  assert.match(result.content[0].text, /Model-synthesized/);
  assert.match(result.content[0].text, /https:\/\/example.com\/doc/);
  assert.match(result.content[0].text, /Hosted search fees are additional/);
});

test("plausible answers, incomplete searches and provider errors are failures, keeping usage", () => {
  for (const stopReason of ["error", "aborted", "length", "toolUse"]) {
    const result = searchResult({ ...message, stopReason }, evidence());
    assert.equal(result.isError, true);
    assert.deepEqual(result.usage, usage);
  }
  assert.equal(searchResult(message, new SearchEvidence()).isError, true);
  const e = evidence(); e.actions = [];
  assert.equal(searchResult(message, e).isError, true);
  e.actions = [{ type: "search" }]; e.sources = []; e.citations = [];
  assert.equal(searchResult(message, e).isError, true);
});

test("malformed metadata is ignored and bounded; unsafe source URLs are dropped", () => {
  const e = new SearchEvidence();
  for (const data of [null, {}, { type: "response.output_item.done", item: { type: "message", content: {} } }, { type: "response.output_item.done", item: { type: "web_search_call", action: {} } }]) e.observe(data);
  assert.equal(e.actions.length, 0);
  for (const url of ["javascript:alert(1)", "file:///etc/passwd", "https://user:secret@example.com", "not a url"]) assert.equal(sourceUrl(url), undefined);
  for (let i = 0; i < 100; i++) e.observe({ type: "response.output_item.done", item: { type: "message", content: [{ annotations: [{ type: "url_citation", url: `https://example.com/${i}`, title: "x".repeat(10000) }] }] } });
  assert.equal(e.citations.length, 64);
  assert.equal(e.citations[0].title.length, 300);
  assert.ok(searchResult(message, { ...e, completed: true, actions: [{ type: "search" }] } as any).content[0].text.length < 33000);
});

test("nested search sends only query, preserves cancellation and uses selected runtime", async () => {
  let called = false;
  const controller = new AbortController();
  const ctx: any = { model: { api: "openai-responses", id: "fixture" }, modelRegistry: { streamSimple(model: any, context: any, options: any) {
    called = true;
    assert.equal(model, ctx.model);
    assert.equal(context.messages.length, 2);
    assert.equal(context.messages[1].content, "lookup");
    assert.equal(options.maxRetries, 0);
    controller.abort();
    assert.equal(options.signal.aborted, true);
    return { result: async () => ({ ...message, stopReason: "aborted" }) };
  } } };
  const result = await search("lookup", ctx, controller.signal);
  assert.equal(called, true);
  assert.equal(result.isError, true);
  assert.deepEqual(result.usage, usage);
  await assert.rejects(search("lookup", { model: { api: "anthropic-messages" } } as any), /requires.*openai-responses/);
  await assert.rejects(search(" ", ctx), /1–2000/);
  const cancelled = await search("lookup", ctx, controller.signal);
  assert.equal(cancelled.isError, true);
  assert.equal("failure" in cancelled.details && cancelled.details.failure, "cancelled");
  assert.equal(cancelled.usage, undefined);
});

test("setup throws and result rejections become bounded allowlisted failures with optional usage", async () => {
  const sentinel = "SENTINEL_RAW_BODY credential-secret stack-secret ";
  for (const mode of ["setup", "result"]) {
    for (const [metadata, expected] of [
      [{ status: 403 }, "blocked"], [{ response: { status: 429 } }, "rate_limited"],
      [{ statusCode: 401 }, "authentication"], [{ name: "TimeoutError" }, "timeout"],
      [{ name: "AbortError" }, "cancelled"], [{}, "provider_error"],
    ] as const) {
      for (const reported of [undefined, { ...usage, raw: sentinel, cost: { ...usage.cost, raw: sentinel } }]) {
        const error = Object.assign(new Error(sentinel + "x".repeat(100000)), metadata, { usage: reported });
        const ctx: any = { model: { api: "openai-responses" }, modelRegistry: { streamSimple() {
          if (mode === "setup") throw error;
          return { result: async () => { throw error; } };
        } } };
        const result = await search("lookup", ctx);
        assert.equal(result.isError, true);
        assert.equal("failure" in result.details && result.details.failure, expected);
        assert.deepEqual(result.usage, reported ? usage : undefined);
        assert.equal("usage" in result, !!reported);
        const serialized = JSON.stringify(result);
        assert.ok(serialized.length < 2000);
        for (const secret of ["SENTINEL_RAW_BODY", "credential-secret", "stack-secret"]) assert.equal(serialized.includes(secret), false);
      }
    }
  }
});

test("normalized failures discard raw bodies and partial source metadata too", () => {
  const e = evidence();
  e.citations[0].title = "SENTINEL_RAW_BODY";
  const result = searchResult({ ...message, stopReason: "error", errorMessage: "403 SENTINEL_RAW_BODY " + "x".repeat(100000) }, e);
  assert.equal("failure" in result.details && result.details.failure, "blocked");
  assert.equal(JSON.stringify(result).includes("SENTINEL_RAW_BODY"), false);
  assert.deepEqual(result.usage, usage);
});

test("response status and bounded textual hints classify errors without copying them", async () => {
  for (const [error, status, expected] of [
    [new Error("HTTP 429 private body"), undefined, "rate_limited"],
    [new Error("Unauthorized private body"), undefined, "authentication"],
    [new Error("private body"), 403, "blocked"],
    ["timeout private body", undefined, "timeout"],
    [{ get message() { throw new Error("private body"); } }, undefined, "provider_error"],
  ] as const) {
    const ctx: any = { model: { api: "openai-responses" }, modelRegistry: { streamSimple(_m: any, _c: any, options: any) {
      options.onResponse({ status });
      return { result: async () => { throw error; } };
    } } };
    const result = await search("lookup", ctx);
    assert.equal("failure" in result.details && result.details.failure, expected);
    assert.equal(JSON.stringify(result).includes("private body"), false);
  }
});

test("only public IPs, HTTP(S), standard ports and credential-free URLs", () => {
  for (const address of ["127.0.0.1", "10.1.2.3", "172.16.0.1", "192.168.0.1", "169.254.169.254", "100.64.0.1", "192.0.2.1", "0.0.0.0", "224.0.0.1", "::1", "::ffff:8.8.8.8", "fc00::1", "fe80::1", "2001:db8::1", "2002:0808:0808::", "3fff::1"]) assert.equal(publicAddress(address), false, address);
  for (const address of ["8.8.8.8", "1.1.1.1", "2606:4700:4700::1111"]) assert.equal(publicAddress(address), true, address);
  for (const url of ["file:///etc/passwd", "http://u:p@example.com", "http://127.1", "http://0x7f000001", "http://[::1]", "https://example.com:8443"]) assert.throws(() => validateUrl(url));
  assert.equal(validateUrl("https://example.com/doc#anchor").href, "https://example.com/doc");
});

test("DNS pinning rejects localhost before any request", async () => {
  await new Promise<void>(resolve => publicLookup("localhost", {}, (error: Error) => { assert.match(error.message, /private|local/); resolve(); }));
  const server = createServer((_req, res) => { res.end("should not be reached"); assert.fail("private target reached"); });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  try {
    const address = server.address() as any;
    // Exercise the connection's actual pinned lookup, independently of validateUrl's port guard.
    await assert.rejects(requestPage(new URL(`http://localhost:${address.port}`), signal()), /private|local/);
  } finally { await new Promise<void>(resolve => server.close(() => resolve())); }
});

test("redirects revalidate destinations, reject downgrades and loops", async () => {
  const page = { url: "https://example.com/doc", type: "text/plain", body: Buffer.from("ok") };
  let count = 0;
  const result = await download("https://example.com", signal(), async url => ++count === 1 ? { redirect: "/doc" } : { ...page, url: url.href });
  assert.equal(result.url, page.url);
  for (const redirect of ["http://127.0.0.1", "http://example.com", "http://[::ffff:127.0.0.1]"]) {
    await assert.rejects(download("https://example.com", signal(), async () => ({ redirect })));
  }
  await assert.rejects(download("https://example.com", signal(), async () => ({ redirect: "/loop" })), /Too many/);
});

test("extraction removes executable markup, preserves readable text and resolved links", async () => {
  const html = '<head><title>Ignore</title><style>bad css</style></head><h1>Docs &amp; more</h1><p>Hello <b>world</b>.</p><script>bad js</script><noscript>hidden</noscript><a href="../next">Next</a><a href="javascript:bad()">Unsafe</a><pre>a\n b</pre>';
  const text = await htmlText(html, signal(), "https://example.com/docs/start");
  assert.match(text, /Docs & more\n+Hello world\./);
  assert.match(text, /Next \(https:\/\/example.com\/next\)/);
  assert.doesNotMatch(text, /bad css|bad js|hidden|javascript:|<h1>|Ignore/);
  assert.equal(await htmlText("<template><template>inner</template>outer</template><p>Visible</p>", signal()), "Visible");
});

test("continuation is bounded and hash-checked, with Unicode-safe boundaries", () => {
  const text = "x".repeat(11999) + "🙂" + "y".repeat(220000);
  const first = chunkText(text, 0);
  assert.deepEqual(chunkText(text, 0, "0".repeat(64)), first, "initial calls ignore guessed hashes");
  assert.equal(first.text.length, 11999);
  assert.equal(first.truncated, true);
  const second = chunkText(text, first.next_offset!, first.sha256);
  assert.ok(second.text.startsWith("🙂"));
  assert.throws(() => chunkText(text, 12000), /requires/);
  assert.throws(() => chunkText(text + "changed", 12000, first.sha256), /changed/);
  assert.throws(() => chunkText(text, -1));
  assert.throws(() => chunkText(text, 200001, first.sha256));
  const atCap = "x".repeat(199999) + "🙂";
  const capHash = chunkText(atCap, 0).sha256;
  const capChunk = chunkText(atCap, 192000, capHash);
  assert.equal(capChunk.available_characters, 199999);
  assert.equal(capChunk.next_offset, null);
  assert.ok(capChunk.text.endsWith("x"));
  const last = chunkText("hello", 0);
  assert.equal(last.next_offset, null);
});

test("complete HTML is extracted despite misleading plain/Markdown content types", async () => {
  const document = '<!DOCTYPE html><html><head><style>SENTINEL_STYLE</style></head><body><h1>Readable docs</h1><script>SENTINEL_SCRIPT</script><p>Source paragraph.</p></body></html>';
  for (const type of ["text/plain", "text/markdown", "text/plain; charset=utf-8"]) {
    for (const html of [document, '\uFEFF \n<!-- prolog -->' + document, '<HTML lang="en"><BODY>Readable docs<script>SENTINEL_SCRIPT</script></BODY></HTML><!-- trailing comment --><script>SENTINEL_SCRIPT</script>']) {
      const result = await fetchText("https://example.com", 0, undefined, signal(), async () => ({ url: "https://example.com/", type, body: Buffer.from(html) }));
      assert.equal(result.details.extraction, "html");
      assert.match(result.content[0].text, /Readable docs/);
      assert.doesNotMatch(JSON.stringify(result), /SENTINEL_SCRIPT|SENTINEL_STYLE|<script>|<html>/i);
    }
  }
});

test("Markdown embedded HTML and code examples are literal source, not sanitized HTML", async () => {
  const markdown = '# Examples\n\nEmbedded <b>HTML</b> and <script>literal example</script>.\n\n```html\n<!doctype html>\n<html><script>fenced example</script></html>\n```\n\n~~~html\n<html>tilde example</html>\n~~~\n\n    <html>indented example</html>\n\nUse `<T>` and a < b, or <https://example.com>.\n';
  for (const type of ["text/markdown", "text/plain"]) {
    const result = await fetchText("https://example.com", 0, undefined, signal(), async () => ({ url: "https://example.com/", type, body: Buffer.from(markdown) }));
    assert.equal(result.details.extraction, "literal");
    assert.equal(result.details.text, markdown);
    assert.match(result.content[0].text, /embedded HTML and code examples preserved, not sanitized/);
  }
  for (const example of ["<T> generic type", "a < b", "<https://example.com>", '```html\n<html>example</html>\n```', '~~~html\n<!doctype html>\n<html>example</html>\n~~~']) assert.equal(htmlDocument(example), false);
});

test("HTTP body handling enforces types, limits, status and cancellation", async () => {
  // Low-level HTTP fixture only: the public download entry point never permits this local URL.
  const server = createServer((req, res) => {
    assert.equal(req.headers["accept-encoding"], "identity");
    assert.equal(req.headers.authorization, undefined);
    assert.equal(req.headers.cookie, undefined);
    if (req.url === "/slow") { res.writeHead(200, { "content-type": "text/plain" }); res.write("a"); return; }
    if (req.url === "/failed") { res.writeHead(403); res.end(); return; }
    if (req.url === "/binary") { res.writeHead(200, { "content-type": "application/pdf" }); res.end("pdf"); return; }
    if (req.url === "/compressed") { res.writeHead(200, { "content-type": "text/plain", "content-encoding": "gzip" }); res.end("not decoded"); return; }
    if (req.url === "/redirect") { res.writeHead(302, { location: "/text" }); res.end(); return; }
    res.writeHead(200, { "content-type": "text/plain" });
    res.end(req.url === "/large" ? "x".repeat(2 * 1024 * 1024 + 1) : "source text");
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const url = (path: string) => new URL(`http://127.0.0.1:${(server.address() as any).port}${path}`);
  try {
    const page = await requestPage(url("/text"), signal());
    assert.equal("body" in page && page.body.toString(), "source text");
    assert.deepEqual(await requestPage(url("/redirect"), signal()), { redirect: "/text" });
    for (const [path, error] of [["/failed", /403/], ["/binary", /content type/], ["/compressed", /Compressed/], ["/large", /2 MiB/]] as const) {
      await assert.rejects(requestPage(url(path), signal()), error);
    }
    await assert.rejects(requestPage(url("/slow"), AbortSignal.timeout(30)), /abort/i);
  } finally {
    server.closeAllConnections();
    await new Promise<void>(resolve => server.close(() => resolve()));
  }
});

test("aborted fetch/extraction do not start work", async () => {
  const controller = new AbortController(); controller.abort();
  await assert.rejects(fetchText("https://example.com", 0, undefined, controller.signal), /abort/i);
  await assert.rejects(async () => htmlText("<p>Hi</p>", controller.signal), /abort/i);
});