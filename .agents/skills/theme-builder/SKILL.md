---
name: theme-builder
description: "Generate and verify the public Doric theme assets for Fuzzel, Ghostty, Niri, Pi, and Waybar. Use when adding, refreshing, or checking application themes derived from Doric Emacs palettes."
---

# Theme Builder

Use this skill for Doric theme generation owned by this repository. Run every
command from the root of a standard `brucenunk/home-config` task worktree and
write only that worktree.

The generator reads palettes from the installed Emacs `doric-themes` package.
Its supported targets and output trees are:

| Target | Output tree |
| --- | --- |
| `fuzzel` | `config/fuzzel/themes/` |
| `ghostty` | `config/ghostty/themes/` |
| `niri` | `config/niri/themes/` |
| `pi` | `config/pi/themes/` |
| `waybar` | `config/waybar/themes/` |

`--target all` generates all five targets. The legacy `--target both` alias
generates Ghostty and Pi. `--theme doric-NAME` is repeatable; with no
`--theme`, or with `--all`, the generator processes the complete installed
Doric collection. Full-collection runs also remove stale files carrying the
generator's ownership marker; selective `--theme` runs never prune files.

## Before regeneration

1. Confirm the current task permits changes to every requested output tree.
2. Start with those trees clean so pre-existing edits cannot be mistaken for
   generated changes:

   ```bash
   git status --short -- \
     config/fuzzel/themes config/ghostty/themes config/niri/themes \
     config/pi/themes config/waybar/themes
   ```

3. Check which installed package supplies the source palettes:

   ```bash
   emacs --batch -Q --eval \
     '(progn (require (quote package)) (package-initialize) (princ (locate-library "doric-themes")))'
   ```

Do not regenerate from a different repository, copy machine-specific state
into an output, or accept generated churn without tracing it to an intended
palette or generator change.

## Generate

Generate the full theme set for all applications:

```bash
.agents/skills/theme-builder/scripts/build-doric-themes.py --all --target all
```

Generate one theme or one application when the task is intentionally narrower:

```bash
.agents/skills/theme-builder/scripts/build-doric-themes.py \
  --theme doric-obsidian --target ghostty
```

The generator emits each target's canonical text formatting. Do not run a
separate formatter over generated INI, Ghostty, KDL, JSON, or CSS files.

## Verify

Check the generator itself and enumerate its command-line targets:

```bash
(
  pycache=$(mktemp -d)
  trap 'rm -rf "$pycache"' EXIT
  PYTHONPYCACHEPREFIX="$pycache" python3 -m py_compile \
    .agents/skills/theme-builder/scripts/build-doric-themes.py
)
ruff check .agents/skills/theme-builder/scripts/build-doric-themes.py
ruff format --check .agents/skills/theme-builder/scripts/build-doric-themes.py
.agents/skills/theme-builder/scripts/build-doric-themes.py --help
```

To prove every supported output independently reproduces the complete tracked
theme tree, begin with clean output trees, run:

```bash
for target in fuzzel ghostty niri pi waybar; do
  .agents/skills/theme-builder/scripts/build-doric-themes.py \
    --all --target "$target"
done
```

Then inspect both tracked and untracked differences across all five trees:

```bash
git status --short -- \
  config/fuzzel/themes config/ghostty/themes config/niri/themes \
  config/pi/themes config/waybar/themes
git diff --check
git diff -- \
  config/fuzzel/themes config/ghostty/themes config/niri/themes \
  config/pi/themes config/waybar/themes
```

An empty scoped status proves byte-for-byte reproduction, including removal of
stale generator-owned themes. Otherwise review and explain every changed,
removed, or newly generated file before keeping it. After an
approved generated change, run the repository-prescribed public boundary and
Home Manager checks; do not apply or claim runtime pickup unless the task
explicitly calls for deployment.
