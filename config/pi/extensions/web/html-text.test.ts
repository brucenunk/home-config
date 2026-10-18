import assert from "node:assert/strict";
import { test } from "node:test";
import { fetchText, htmlText } from "./fetch.ts";

const extract = (html: string, url = "https://example.com/docs/start") =>
  htmlText(html, new AbortController().signal, url);

test("parser handles named/numeric entities, case and malformed block/list markup", async () => {
  assert.equal(await extract("<DIV>A &amp; B&nbsp;&copy; &#x1f600;</DIV><ul><li>one<li>two</ul>"),
    "A & B © 😀\n\n- one\n\n- two");
  assert.equal(await extract("<p>one<div>two</div>three"), "one\n\ntwo\nthree");
});

test("hidden nesting, raw script/style text and unclosed hidden elements stay suppressed", async () => {
  for (const tag of ["head", "script", "style", "noscript", "template", "svg"]) {
    const text = await extract(`<${tag}>SENTINEL_HIDDEN</${tag}><p>Visible</p>`);
    assert.equal(text, "Visible", tag);
  }
  assert.equal(await extract("<template><template>inner</template>outer</template>Visible"), "Visible");
  assert.equal(await extract("Visible<script>unfinished <p>hidden"), "Visible");
  assert.equal(await extract("<div><template>hidden</div>Visible"), "Visible");
  assert.equal(await extract("<template>".repeat(64) + "<span>".repeat(64) + "hidden"), "");
});

test("nesting is bounded before adversarial ancestor closes can stall the parser", { timeout: 2000 }, async () => {
  const adversarial = "<main>" + "<i>".repeat(300000) + "hidden</main>";
  for (const type of ["text/html", "application/xhtml+xml"]) {
    await assert.rejects(htmlText(adversarial, new AbortController().signal, "", type),
      { message: "HTML nesting exceeds the 256-element extraction limit." });
  }
  assert.equal(await extract("<span>".repeat(256) + "Visible" + "</span>".repeat(256)), "Visible");
  await assert.rejects(extract("<span>".repeat(257)), /nesting exceeds/);
  assert.equal(await extract("<main>" + "<span>".repeat(200) + "</main>Visible"), "Visible");
  // Implicit and void closes must release depth rather than accumulate it.
  assert.ok((await extract("<p>x<br>".repeat(1000))).includes("x"));
});

test("XHTML self-closing script/style elements retain subsequent readable text", async () => {
  const url = "https://example.com/doc";
  const body = Buffer.from('<html xmlns="http://www.w3.org/1999/xhtml"><head><script/><style/></head><body><script/><style/><p>Visible &amp; readable</p><script>hidden</script><style>hidden</style></body></html>');
  const result = await fetchText(url, 0, undefined, undefined, async () => ({
    url, type: "Application/XHTML+XML; charset=utf-8", body,
  }));
  assert.equal(result.details.extraction, "html");
  assert.equal(result.details.text, "Visible & readable");
  for (const tag of ["script", "style"]) {
    // In ordinary HTML the slash does not close a raw-text element.
    assert.equal(await extract(`<${tag}/><p>still hidden</p>`), "");
    assert.equal(await extract(`<${tag}/>hidden</${tag}><p>Visible</p>`), "Visible");
  }
});

test("resolved links are bounded, credential-free HTTP(S); malformed URLs keep anchor text", async () => {
  assert.equal(await extract('<a href="../next?q=1&amp;x=2">Next</a>'), "Next (https://example.com/next?q=1&x=2)");
  for (const href of ["javascript:alert(1)", "mailto:a@example.com", "https://user:secret@example.com/", "http://[bad", ""]) {
    assert.equal(await extract(`<a href="${href}">Label</a>`), "Label");
  }
  assert.equal(await extract(`<a href="https://example.com/${"x".repeat(4096)}">Long</a>`), "Long");
  assert.equal(await extract('<a href="https://example.com/">Absolute</a>', ""), "Absolute (https://example.com/)");
});

test("streaming parser keeps tags, entities and Unicode intact across write boundaries", async () => {
  const prefix = "x".repeat(16382);
  assert.equal(await extract(`${prefix}&amp;<p>😀 &NotEqualTilde;</p>`), `${prefix}&\n😀 ≂̸`);
  assert.equal(await extract(`${"x".repeat(16383)}😀`), `${"x".repeat(16383)}😀`);
  assert.equal(await extract(`${" ".repeat(16382)}<template>hidden</template>Visible`), "Visible");
});

test("input and expanded-link output limits fail explicitly", async () => {
  await assert.rejects(extract("x".repeat(2 * 1024 * 1024 + 1)), /input limit/);
  const base = `https://example.com/${"x".repeat(4000)}/`;
  await assert.rejects(extract('<a href="n">n</a>'.repeat(1100), base), /output limit/);
});

test("cancellation yields to the event loop after parsing starts", async () => {
  const controller = new AbortController();
  const pending = htmlText("<p>text &amp; more</p>".repeat(50000), controller.signal);
  setImmediate(() => controller.abort());
  await assert.rejects(pending, { name: "AbortError" });
});