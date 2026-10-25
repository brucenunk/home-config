# Emacs major-mode selection

This policy targets the pinned Emacs 32.0.50. Nix supplies packages and grammars;
`config/emacs/init.el` owns language selection and Eglot configuration.
These are repository and isolated-batch observations, not shared-daemon evidence.

## Selection policy

Configure one automatic editing mode per language. Keep external modes when they
provide working language-specific behaviour; grammar availability is not a reason
to replace them. Built-in legacy commands remain available manually.

`treesit-enabled-modes` contains only `bash-ts-mode`, `json-ts-mode`, and
`python-ts-mode`. Its Custom setter installs the corresponding
remaps from `sh-mode`, `js-json-mode`, and `python-mode`. Do not replace
that setter with plain `setq`, or overwrite the resulting remap list later.

| Filename / language | Before this change | Configured selection |
| --- | --- | --- |
| `.excalidraw` | `fundamental-mode` | `json-ts-mode`, explicit association |
| `.json` | `js-json-mode` | `json-ts-mode`, curated remap |
| `.yaml`, `.yml` | External `yaml-mode` | Same mode, now with an explicit association |
| `.py` | `python-mode` | `python-ts-mode`, curated remap |
| `.sh` / shell interpreter associations | `bash-ts-mode`, explicit `sh-mode` remap | Same mode, curated remap |
| `.nix` | `nix-ts-mode` | Unchanged explicit association |
| `.go` | `go-ts-mode` | Unchanged explicit association |
| `go.mod`, `go.work` | `go-mod-ts-mode`, `go-work-ts-mode` | Unchanged built-in grammar-aware associations |
| Dockerfile | `dockerfile-ts-mode` | Unchanged built-in grammar-aware association |
| `.jsonnet`, `.libsonnet` | `jsonnet-mode` | Unchanged external package associations |
| `.rego` | `rego-mode` | Unchanged external package association |
| `.tf` | `terraform-mode` | Unchanged external package association |
| `BUILD.bazel` | `bazel-build-mode` | Unchanged external package association |
| `.md` | `markdown-mode` | Unchanged; explicit configuration in `my-emacs-editing.el` |
| `.excalidsl` | `excali-dsl-mode` | Unchanged explicit association in `my-emacs-excali.el` |
| `.el`, `.js`, `.css` | `emacs-lisp-mode`, `js-mode`, `css-mode` | Unchanged built-in associations |

Raw `.excalidraw` visits do not invoke the graphical editor or modify drawing
contents. `my/excali-open` remains the explicit native drawing entry point.

Emacs 32's grammar-aware `*-mode-maybe` associations can select some tree-sitter
modes even when `treesit-enabled-modes` is nil. That option is not a global
prohibition on other tree-sitter modes. Package autoloads also affect precedence:
before this change, normal package activation selected external `yaml-mode`,
whereas a batch probe without package activation selected `yaml-ts-mode`.

TypeScript (`.ts`), `.mjs`, and KDL (`.kdl`) selected `fundamental-mode` in the
baseline isolated audit. They are explicitly outside this task's migration;
there are no new packages, grammars, or associations for them.

## Declarative grammar inventory

`flake-modules/features/emacs.nix` retains the existing grammar set:

- Active tree-sitter editing: Bash, Dockerfile, Go, Go module, Go work, JSON,
  Nix, Python.
- Installed but not selected as replacement editing modes by this policy:
  Go templates, HCL, Jsonnet, Markdown, Markdown inline, Rego, YAML.
- No JavaScript, TypeScript, or CSS grammars are configured. Starlark is not
  exposed by the pinned nixpkgs grammar set.

The external `yaml-mode` package is retained as the sole configured YAML choice.
The pinned `yaml-ts-mode` has no YAML-aware indentation rules and uses generic
`indent-relative`; replacing the external mode would lose its interactive
indentation and cycling. The YAML grammar remains installed but does not select
the configured mode. The separate `yaml` parsing library remains a dependency of
other configuration. No parser installation or download is added to Emacs startup.

## Eglot and formatting

| Automatic Eglot hook | Required executable | Server / preserved configuration |
| --- | --- | --- |
| `bash-ts-mode` | `bash-language-server` | Eglot built-in server definition |
| `go-ts-mode` | `gopls` | Eglot built-in server definition |
| `jsonnet-mode` | `jsonnet-language-server` | Explicit lint, double-quoted formatting, completion documentation options |
| `nix-ts-mode` | `nixd` | Explicit server definition with `nixfmt` formatter |
| `python-ts-mode` | `pylsp` | Existing Ruff plugin configuration |
| `rego-mode` | `regal` | Explicit `regal language-server` command |
| `terraform-mode` | `terraform-ls` | Explicit `terraform-ls serve`; existing Terraform format-on-save |
| `yaml-mode` | `yaml-language-server` | Explicit `yaml-language-server --stdio` command |

The same exact modes appear in the executable allowlist. Legacy `python-mode`
no longer has automatic Eglot wiring; `yaml-ts-mode` has none. Availability checks retain
remote executable lookup. No broad `prog-mode` Eglot hook is installed.

JSON (including drawing text), Go module/work files, Dockerfile, Markdown,
Bazel, JS, CSS, and Emacs Lisp have no automatic Eglot startup hook from this
configuration. This change does not introduce servers for them.

The existing `eglot-managed-mode-hook` installs buffer-local
`eglot-format-buffer` before-save handling only in managed buffers. Selecting a
JSON text mode alone does not enable Eglot formatting. Existing general
`prog-mode` customisations (Jinx, rainbow delimiters, whitespace cleanup) remain
unchanged, as do Bazel buildifier-on-save and Terraform formatting settings.

## Isolated verification

`checks.x86_64-linux.emacs-mode-selection` uses the final Nix Emacs package,
temporary HOME, normal package autoload activation, and the actual language forms
from init without running the rest of user startup. It checks real filename mode
selection with installed parsers, retained YAML indentation, curated remaps, affected hooks, executable
availability gating, server settings, and managed-buffer formatting. Drawing text
is checked for content preservation and no implicit graphical opening.

The separate `emacs-excali` check covers native drawing integration. The prescribed
Wampa Home Manager build checks configuration delivery without activating it.
Neither build success nor these batch checks prove shared-runtime pickup.