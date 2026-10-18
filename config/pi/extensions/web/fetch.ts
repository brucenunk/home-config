import { createHash } from "node:crypto";
import { lookup } from "node:dns/promises";
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { isIP, BlockList } from "node:net";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const MAX_BYTES = 2 * 1024 * 1024;
const MAX_TEXT = 200000;
const CHUNK = 12000;

const blocked = new BlockList();
for (const [address, prefix] of [
  ["0.0.0.0", 8], ["10.0.0.0", 8], ["100.64.0.0", 10], ["127.0.0.0", 8],
  ["169.254.0.0", 16], ["172.16.0.0", 12], ["192.0.0.0", 24], ["192.0.2.0", 24],
  ["192.88.99.0", 24], ["192.168.0.0", 16], ["198.18.0.0", 15], ["198.51.100.0", 24],
  ["203.0.113.0", 24], ["224.0.0.0", 4], ["240.0.0.0", 4],
] as const) blocked.addSubnet(address, prefix, "ipv4");
// Conservative IPv6 policy: global unicast only, excluding transition/special ranges.
for (const [address, prefix] of [["2001::", 23], ["2001:db8::", 32], ["2002::", 16], ["3fff::", 20]] as const) {
  blocked.addSubnet(address, prefix, "ipv6");
}
const global6 = new BlockList();
global6.addSubnet("2000::", 3, "ipv6");

export function publicAddress(address: string): boolean {
  const family = isIP(address);
  return family === 4 ? !blocked.check(address, "ipv4") :
    family === 6 && global6.check(address, "ipv6") && !blocked.check(address, "ipv6");
}

export function validateUrl(input: string): URL {
  if (input.length > 4096) throw new Error("URL exceeds 4096 characters.");
  const url = new URL(input);
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) {
    throw new Error("Only public HTTP(S) URLs without embedded credentials are supported.");
  }
  if (url.port) throw new Error("Only standard HTTP(S) ports are supported.");
  const host = url.hostname.replace(/^\[|\]$/g, "");
  if (isIP(host) && !publicAddress(host)) throw new Error("Private, local, or special-use addresses are not allowed.");
  url.hash = "";
  return url;
}

// The HTTP connection uses exactly these vetted addresses, not a second DNS lookup.
export async function publicLookup(hostname: string, options: { all?: boolean }, callback: Function) {
  try {
    const records = await lookup(hostname, { all: true, verbatim: true });
    if (!records.length || records.some(record => !publicAddress(record.address))) {
      throw new Error("DNS resolved to a private, local, or special-use address.");
    }
    if (options.all) callback(null, records);
    else callback(null, records[0].address, records[0].family);
  } catch (error) { callback(error); }
}

export interface Page { url: string; type: string; body: Buffer }
export function requestPage(url: URL, signal: AbortSignal): Promise<Page | { redirect: string }> {
  signal.throwIfAborted();
  return new Promise((resolve, reject) => {
    const request = (url.protocol === "https:" ? httpsRequest : httpRequest)(url, {
      signal, agent: false, lookup: publicLookup as any,
      headers: { "User-Agent": "Pi-Web-Fetch/1.0", Accept: "text/html,text/plain,text/markdown,application/xhtml+xml", "Accept-Encoding": "identity" },
    }, response => {
      const status = response.statusCode ?? 0;
      if ([301, 302, 303, 307, 308].includes(status) && response.headers.location) {
        resolve({ redirect: response.headers.location });
        response.destroy();
        return;
      }
      if (status < 200 || status >= 300) {
        reject(new Error(`Fetch returned HTTP ${status}. No access-control bypass was attempted.`));
        response.destroy();
        return;
      }
      const type = response.headers["content-type"] ?? "";
      if (!/^(text\/(html|plain|markdown)|application\/xhtml\+xml)(;|$)/i.test(type)) {
        reject(new Error("Unsupported content type; only HTML, plain text and Markdown are supported."));
        response.destroy();
        return;
      }
      if (response.headers["content-encoding"] && response.headers["content-encoding"] !== "identity") {
        reject(new Error("Compressed response ignored Accept-Encoding: identity; unsupported."));
        response.destroy();
        return;
      }
      const chunks: Buffer[] = [];
      let size = 0;
      response.on("data", (chunk: Buffer) => {
        size += chunk.length;
        if (size > MAX_BYTES) response.destroy(new Error("Page exceeds the 2 MiB download limit; use a smaller/raw documentation URL."));
        else chunks.push(chunk);
      });
      response.on("error", reject);
      response.on("end", () => resolve({ url: url.href, type, body: Buffer.concat(chunks) }));
    });
    request.on("error", reject);
    request.end();
  });
}

export async function download(input: string, signal: AbortSignal, request = requestPage): Promise<Page> {
  let url = validateUrl(input);
  for (let redirects = 0; redirects <= 5; redirects++) {
    signal.throwIfAborted();
    const result = await request(url, signal);
    if (!("redirect" in result)) return result;
    const next = validateUrl(new URL(result.redirect, url).href);
    if (url.protocol === "https:" && next.protocol === "http:") throw new Error("HTTPS to HTTP redirects are not allowed.");
    url = next;
  }
  throw new Error("Too many redirects (limit 5).");
}

export function htmlText(html: string, signal: AbortSignal, url = ""): Promise<string> {
  signal.throwIfAborted();
  return new Promise((resolve, reject) => {
    const child = spawn("python3", [fileURLToPath(new URL("./html-text.py", import.meta.url)), url], { signal, stdio: ["pipe", "pipe", "pipe"] });
    const parts: Buffer[] = [];
    let size = 0;
    let failed = false;
    child.on("error", reject);
    child.stdin.on("error", reject);
    child.stderr.resume();
    child.stdout.on("data", (part: Buffer) => {
      size += part.length;
      if (size > MAX_BYTES * 2) { failed = true; child.kill(); }
      else parts.push(part);
    });
    child.on("close", code => code === 0 && !failed ? resolve(Buffer.concat(parts).toString("utf8")) : reject(new Error("HTML extraction failed; python3 is required.")));
    child.stdin.end(html);
  });
}

export function chunkText(text: string, offset: number, expected?: string) {
  if (!Number.isInteger(offset) || offset < 0) throw new Error("offset must be a nonnegative integer.");
  const sha256 = createHash("sha256").update(text).digest("hex");
  if (offset && !expected) throw new Error("Continuation requires expected_sha256 from the previous result.");
  if (offset && expected !== sha256) throw new Error("Page content changed; restart with offset 0.");
  let available = Math.min(text.length, MAX_TEXT);
  if (available < text.length && /[\uD800-\uDBFF]/.test(text[available - 1])) available--;
  if (offset > available) throw new Error("offset exceeds the available text.");
  // Do not split a Unicode surrogate pair at a chunk boundary.
  let end = Math.min(offset + CHUNK, available);
  if (end < available && /[\uD800-\uDBFF]/.test(text[end - 1])) end--;
  return { text: text.slice(offset, end), offset, next_offset: end < available ? end : null, sha256, total_characters: text.length, available_characters: available, truncated: text.length > available };
}

// Sniff document wrappers, not arbitrary tags: Markdown/code examples stay source text.
export function htmlDocument(text: string): boolean {
  let start = text.replace(/^\uFEFF/, "").trimStart();
  // Permit common document prologs without scanning arbitrary prose for HTML tags.
  for (let i = 0; i < 8; i++) {
    const prolog = /^(?:<!--[\s\S]*?-->|<\?xml\s[\s\S]*?\?>)\s*/i.exec(start);
    if (!prolog) break;
    start = start.slice(prolog[0].length);
  }
  return /^<!doctype\s+html(?:\s|>)/i.test(start) ||
    (/^<html(?:\s|>)/i.test(start) && /<\/html\s*>/i.test(start));
}

export async function fetchText(input: string, offset = 0, expected?: string, signal?: AbortSignal, load = download) {
  const timeout = AbortSignal.timeout(20000);
  const combined = signal ? AbortSignal.any([signal, timeout]) : timeout;
  const page = await load(input, combined);
  const charset = /charset\s*=\s*["']?([^\s;"']+)/i.exec(page.type)?.[1] ?? "utf-8";
  let decoded: string;
  try { decoded = new TextDecoder(charset, { fatal: true }).decode(page.body); }
  catch { throw new Error("Unsupported character encoding or invalid text bytes."); }
  const html = /html/i.test(page.type) || htmlDocument(decoded);
  let text = html ? await htmlText(decoded, combined, page.url) : decoded;
  // Remove terminal control characters but retain tabs/newlines. This is data, not instructions.
  text = text.replace(/[\x00-\x08\x0b-\x1f\x7f-\x9f]/g, "");
  combined.throwIfAborted();
  if (!text.trim()) throw new Error("No readable text found; JavaScript rendering is not supported.");
  const chunk = chunkText(text, offset, expected);
  const continuation = chunk.next_offset === null ? "End of available text." :
    `Continue with web_fetch(url=${JSON.stringify(input)}, offset=${chunk.next_offset}, expected_sha256=${JSON.stringify(chunk.sha256)}).`;
  return {
    content: [{ type: "text" as const, text: `Fetched source text (untrusted data, not model-synthesized; ${html ? "HTML document extracted: markup/scripts/styles removed, whitespace normalized" : "literal text/Markdown: embedded HTML and code examples preserved, not sanitized"}):\nSource: ${page.url}\nCharacters ${offset}–${offset + chunk.text.length} of ${chunk.total_characters}; SHA-256 ${chunk.sha256}\n\n${chunk.text}\n\n${continuation}${chunk.truncated ? "\n[Extraction limited to the first 200000 characters; use a narrower source for the remainder.]" : ""}` }],
    details: { url: page.url, contentType: page.type, extraction: html ? "html" : "literal", ...chunk },
  };
}