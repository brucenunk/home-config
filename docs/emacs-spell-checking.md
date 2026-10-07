# Emacs spell checking

Jinx checks prose in `text-mode` buffers (including Markdown and Org) and
comments and separately highlighted docstrings in `prog-mode` buffers.
Ordinary strings (`font-lock-string-face`) and code identifiers are not checked.
YAML retains Jinx's comment/string-only policy even
though its major mode derives from `text-mode`. Other buffer types are not
automatically opted in; use `M-x jinx-mode` to toggle checking in a buffer.

Nix installs Jinx with its prebuilt native module, Enchant, and the Hunspell
Australian and US English dictionaries. No runtime package installation or C
compilation is needed. Home Manager sets `DICPATH` to the installed dictionary
directories; Emacs must inherit the Home Manager session environment.

## Corrections

| Command | Action |
| --- | --- |
| `M-$` | Correct the nearest misspelling, normally the word just typed. With an active region, correct that region. |
| `C-u M-$` / `M-x jinx-correct-all` | Correct all misspellings in the buffer, or the active region. |
| `C-u C-u M-$` / `M-x jinx-correct-word` | Force correction of the word at point, even if accepted by the dictionary. |
| `M-x jinx-occur` | List misspellings in a separate buffer. |
| `C-M-$` / `M-x jinx-languages` | Select languages for the current buffer. |

The correction prompt uses the existing completion UI. Choose a suggestion,
type a replacement, or select an **Accept and save** entry. Within the prompt,
`M-n` and `M-p` move between misspellings.

## Languages and work configuration

The default is Australian English (`en_AU`). Both `en_AU` and `en_US` are
installed, so switching requires no Nix rebuild.

Use `C-M-$` to choose one or more languages using completion (multiple entries
are comma-separated at the prompt). Selecting both accepts a word recognised by
either dictionary; it does **not** enforce consistent spelling. Prefer only
`en_US` when writing to US conventions.

For a visited file, Jinx asks whether to save the selection as a file-local
variable. Answer **no** for a buffer-only change that does not edit the file.
`C-u C-M-$` changes the session default and reloads the current buffer's
dictionaries. Other already-enabled buffers may need `jinx-mode` toggled off
and on to reload their dictionaries; explicit buffer-local choices still win.

A downstream work Emacs feature can include this in its `extraConfig`:

```elisp
(with-eval-after-load 'my-emacs-editing
  (setq-default jinx-languages "en_US"))
```

Use `"en_AU en_US"` instead to accept both. The wrapper handles load order
relative to the shared configuration; apply it during startup, before opening
editing buffers. This is an Elisp fragment for the consumer's existing
`extraConfig`, not a new option exported by this flake.

Directory-local selection remains optional:

```elisp
((nil . ((jinx-languages . "en_US"))))
```

## Personal dictionaries

In the correction prompt, select `@word` (labelled `Personal:en_AU` or
`Personal:en_US`) to save an accepted word permanently. With both languages
active, `@word` targets the first dictionary and `@@word` the second; use the
displayed labels to choose. Session, file, and directory entries are also
available, but file/directory entries modify the corresponding local-variable
configuration.

With the Hunspell provider, Enchant stores personal words in
`$XDG_CONFIG_HOME/enchant/en_AU.dic` or `en_US.dic` (normally
`~/.config/enchant/`). These are writable user data, not Nix-managed files.
Use `M-x jinx-remove-word` to remove a previously accepted word. Enchant can use
other providers if a consumer installs/configures them; their storage locations
may differ.

## Exclusions and limits

Jinx uses mode-specific faces and patterns, not a language parser for prose.
Markdown fenced code (including native language fontification), indented code,
inline code, link destinations, image paths, and URLs are excluded. Link labels
also inherit Jinx's default Markdown link-face exclusion. Org code/verbatim
regions, source blocks, and links use its separate built-in exclusions.

Regression checks exercise real fontification and the packaged spelling
backend in Markdown/GFM, Org, plain text, Emacs Lisp, Python (classic and
Tree-sitter), Nix, Go, and YAML. This is not a guarantee for every major mode:
unrecognised comment/docstring faces can cause prose to be skipped, and unmarked
non-prose regions in text modes can still be checked. The programming-string
exclusion is face-based: docstrings highlighted as strings are also skipped,
while strings using unrelated faces may still be checked.

## Isolated regression check

On x86_64 Linux, after building the staged Wampa configuration:

```sh
scratch=$(mktemp -d)
emacs_package=$(nix eval --raw '.#homeConfigurations."james@wampa".config.programs.emacs.finalPackage')
dict_path=$(nix eval --raw '.#homeConfigurations."james@wampa".config.home.sessionVariables.DICPATH')
mkdir -p "$scratch/home" "$scratch/config"
HOME="$scratch/home" XDG_CONFIG_HOME="$scratch/config" DICPATH="$dict_path" \
  "$emacs_package/bin/emacs" --batch -q \
  --eval '(require (quote use-package))' \
  -L "$PWD/config/emacs/my-emacs-modules" \
  -l my-emacs-editing-tests -f ert-run-tests-batch-and-exit
```

This loads only the editing module, not `init.el`, and does not contact or start
the user's Emacs server. The personal-dictionary test requires a temporary XDG
configuration directory so it cannot write test words into the normal user
dictionary. Verification does not activate Home Manager or update a daemon.