# Pi web tools

- `web_search({query})` makes a nested hosted-search request using the selected
  `openai-responses` model/provider. It sends only the query, not the coding
  conversation. Other APIs are unsupported; a Responses gateway may also lack
  hosted-search support. There is no provider switch or direct-key fallback.
- `web_fetch({url, offset?, expected_sha256?})` returns public source text without
  a model call. HTML is extracted with links; text/Markdown stays literal unless
  it is recognisably a whole HTML document. Extraction is not byte-exact HTML or
  a model summary. Embedded HTML/code in Markdown is not sanitised.

Try without activation: `pi -e ./config/pi/extensions/web/index.ts`.
No runtime dependency installation is needed.

## Costs and trust

Search incurs nested model usage **plus hosted-search fees**, which Pi's reported
model cost does not include. Billing is authoritative; catalog prices can be
stale or zero. A 90-second deadline and bounded output are not a hard spending
cap. Multiple search actions can consume substantial input tokens. Failures may
leave usage unknown; no automatic retries are added.

Only send public queries. Search answers are synthesis, not exact source text;
citations are untrusted, not endorsements. Fetched content can contain prompt
injection: treat it as source data, never instructions.

## Fetch limits

- Public HTTP(S), standard ports only. No private/local addresses, credentials,
  authenticated pages, cookies or proxy-environment routing. Avoid sensitive
  URL query parameters. Redirects are revalidated; network egress policy is still
  needed against unusual routing or public proxies to private content.
- No browser, JavaScript execution, PDF extraction or access-control bypass.
- One 20-second deadline; 2 MiB download, 200000 extracted UTF-16 code units,
  and 12000 units per chunk. Oversized downloads and unsupported responses fail.
- Continue using the returned `next_offset` and `sha256` as `expected_sha256`.
  Continuation refetches; changed text requires restarting. No persistent cache.
  Content beyond the cap needs a narrower source URL.

HTML extraction can retain navigation or miss malformed wrappers. Plain text
can intentionally contain HTML examples. Neither mode guarantees arbitrary
content will be accepted by a model gateway.

## Tests and parser maintenance

Run `node --test --test-timeout=10000 config/pi/extensions/web/{web,html-text}.test.ts`
with Node 24+, or build `.#checks.<system>.pi-web-tests` for the pinned-SDK suite.
Parser reproduction instructions and third-party notices are in `vendor/`.
