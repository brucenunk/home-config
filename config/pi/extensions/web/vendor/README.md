# Vendored HTML parser

`htmlparser2.mjs` is a standalone ESM bundle exporting only `Parser`, built from
htmlparser2 12.0.0 with esbuild 0.28.2. The extension imports this committed file
directly; Home Manager copies it with the extension directory. No npm resolution,
Python, or build step is needed at runtime or during the Nix build.

To reproduce/update the bundle, from this directory with Node 24+ and npm:

```sh
npm ci --ignore-scripts
npm run build
```

`package-lock.json` pins the complete build dependency graph and npm integrity
hashes. Commit the bundle and generated `THIRD-PARTY-LICENSES.txt` together with
any manifest/lock changes; do not commit `node_modules`. The notices include the
parser's complete dependency set, including modules removed by tree shaking.
esbuild is a build-time-only tool. Review updates and rerun the web tests before
delivery. This parser does not execute scripts, fetch resources or expand
external entities; HTML extraction is not a prompt-injection sanitizer.