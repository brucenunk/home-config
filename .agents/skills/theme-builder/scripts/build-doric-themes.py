#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable


REPO_ROOT = Path(__file__).resolve().parents[4]
FUZZEL_THEME_DIR = REPO_ROOT / "config/fuzzel/themes"
GHOSTTY_THEME_DIR = REPO_ROOT / "config/ghostty/themes"
NIRI_THEME_DIR = REPO_ROOT / "config/niri/themes"
PI_THEME_DIR = REPO_ROOT / "config/pi/themes"
WAYBAR_THEME_DIR = REPO_ROOT / "config/waybar/themes"
PI_THEME_SCHEMA = (
    "https://raw.githubusercontent.com/badlogic/pi-mono/main/"
    "packages/coding-agent/src/modes/interactive/theme/theme-schema.json"
)
GENERATED_MARKER = "Do not edit directly; regenerate with build-doric-themes.py."


EMACS_EXTRACT = r"""
(progn
  (require 'json)
  (require 'package)
  (package-initialize)
  (require 'doric-themes)
  (defun theme-builder--palette-from-form (form palette-symbol)
    (cond
     ((and (listp form)
           (eq (car form) 'defvar)
           (eq (cadr form) palette-symbol))
      (eval (nth 2 form)))
     ((consp form)
      (or (theme-builder--palette-from-form (car form) palette-symbol)
          (theme-builder--palette-from-form (cdr form) palette-symbol)))
     (t nil)))
  (defun theme-builder--palette-from-file (file theme)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (let ((palette-symbol (intern (format "%s-palette" theme))))
        (catch 'palette
          (condition-case nil
              (while t
                (let ((form (read (current-buffer))))
                  (let ((palette (theme-builder--palette-from-form form palette-symbol)))
                    (when palette
                      (throw 'palette palette)))))
            (end-of-file
             (error "No palette found for %s in %s" theme file)))))))
  (defun theme-builder--extract-theme (theme)
    (let* ((package-dir (file-name-directory (locate-library "doric-themes")))
           (theme-file (expand-file-name (format "%s-theme.el" theme) package-dir))
           (palette (theme-builder--palette-from-file theme-file theme))
           (color (lambda (name)
                    (let ((entry (assoc name palette)))
                      (if entry
                          (cadr entry)
                        (error "Missing %s in %s" name theme))))))
      `((name . ,(symbol-name theme))
        (background_mode . ,(if (memq theme doric-themes-light-themes) "light" "dark"))
        (cursor . ,(funcall color 'cursor))
        (bg_main . ,(funcall color 'bg-main))
        (fg_main . ,(funcall color 'fg-main))
        (border . ,(funcall color 'border))
        (bg_shadow_subtle . ,(funcall color 'bg-shadow-subtle))
        (fg_shadow_subtle . ,(funcall color 'fg-shadow-subtle))
        (bg_neutral . ,(funcall color 'bg-neutral))
        (fg_neutral . ,(funcall color 'fg-neutral))
        (bg_shadow_intense . ,(funcall color 'bg-shadow-intense))
        (fg_shadow_intense . ,(funcall color 'fg-shadow-intense))
        (bg_accent . ,(funcall color 'bg-accent))
        (fg_accent . ,(funcall color 'fg-accent))
        (fg_red . ,(funcall color 'fg-red))
        (fg_green . ,(funcall color 'fg-green))
        (fg_yellow . ,(funcall color 'fg-yellow))
        (fg_blue . ,(funcall color 'fg-blue))
        (fg_magenta . ,(funcall color 'fg-magenta))
        (fg_cyan . ,(funcall color 'fg-cyan))
        (bg_red . ,(funcall color 'bg-red))
        (bg_green . ,(funcall color 'bg-green))
        (bg_yellow . ,(funcall color 'bg-yellow))
        (bg_blue . ,(funcall color 'bg-blue))
        (bg_magenta . ,(funcall color 'bg-magenta))
        (bg_cyan . ,(funcall color 'bg-cyan)))))
  (princ
   (json-encode
    (mapcar #'theme-builder--extract-theme doric-themes-collection))))
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate application themes from Doric Emacs palettes."
    )
    parser.add_argument(
        "--theme",
        action="append",
        default=[],
        help="Theme name to generate, for example doric-marble. Repeatable.",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Generate all Doric themes. This is the default when no --theme values are given.",
    )
    parser.add_argument(
        "--target",
        choices=("all", "both", *TARGETS),
        default="all",
        help=(
            "Which theme output type to generate "
            "(both is Ghostty and Pi for compatibility)."
        ),
    )
    return parser.parse_args()


def load_theme_data() -> list[dict[str, str]]:
    result = subprocess.run(
        ["emacs", "--batch", "-Q", "--eval", EMACS_EXTRACT],
        cwd=REPO_ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    theme_data = json.loads(result.stdout)
    return theme_data


def hex_to_rgb(color: str) -> tuple[int, int, int]:
    return tuple(int(color[index : index + 2], 16) for index in (1, 3, 5))


def rgb_to_hex(rgb: tuple[int, int, int]) -> str:
    return "#{:02x}{:02x}{:02x}".format(*rgb)


def mix_colors(left: str, right: str, ratio: float) -> str:
    left_rgb = hex_to_rgb(left)
    right_rgb = hex_to_rgb(right)
    mixed = tuple(
        round(component * (1 - ratio) + target * ratio)
        for component, target in zip(left_rgb, right_rgb)
    )
    return rgb_to_hex(mixed)


def soften_surface(theme: dict[str, str], source: str) -> str:
    if theme["background_mode"] == "light":
        return mix_colors(source, theme["bg_shadow_subtle"], 0.8)
    return mix_colors(source, theme["bg_main"], 0.25)


def mute_color(theme: dict[str, str], source: str, ratio: float = 0.6) -> str:
    return mix_colors(source, theme["bg_main"], ratio)


def pi_surface(theme: dict[str, str], source: str) -> str:
    if theme["background_mode"] == "light":
        return mix_colors(source, theme["bg_shadow_subtle"], 0.6)
    return soften_surface(theme, source)


def pi_secondary_text(theme: dict[str, str]) -> str:
    return theme["fg_neutral"]


def pi_soft_highlight(theme: dict[str, str], source: str) -> str:
    ratio = 0.3 if theme["background_mode"] == "dark" else 0.18
    return mix_colors(source, theme["fg_main"], ratio)


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def ghostty_theme_text(theme: dict[str, str]) -> str:
    return "\n".join(
        [
            f"# Generated from the installed Emacs doric-themes palette: {theme['name']}.",
            "# Do not edit directly; regenerate with build-doric-themes.py.",
            f"background = {theme['bg_main']}",
            f"foreground = {theme['fg_main']}",
            f"selection-background = {theme['bg_shadow_intense']}",
            f"selection-foreground = {theme['fg_main']}",
            f"cursor-color = {theme['cursor']}",
            "",
            "# black",
            f"palette = 0={theme['bg_shadow_subtle']}",
            f"palette = 8={theme['bg_neutral']}",
            "# red",
            f"palette = 1={theme['fg_red']}",
            f"palette = 9={theme['fg_red']}",
            "# green",
            f"palette = 2={theme['fg_green']}",
            f"palette = 10={theme['fg_green']}",
            "# yellow",
            f"palette = 3={theme['fg_yellow']}",
            f"palette = 11={theme['fg_yellow']}",
            "# blue",
            f"palette = 4={theme['fg_blue']}",
            f"palette = 12={theme['fg_blue']}",
            "# magenta",
            f"palette = 5={theme['fg_magenta']}",
            f"palette = 13={theme['fg_magenta']}",
            "# cyan",
            f"palette = 6={theme['fg_cyan']}",
            f"palette = 14={theme['fg_cyan']}",
            "# white",
            f"palette = 7={theme['fg_main']}",
            f"palette = 15={theme['fg_main']}",
            "",
        ]
    )


def fuzzel_color(color: str) -> str:
    return f"{color.removeprefix('#')}ff"


def fuzzel_theme_text(theme: dict[str, str]) -> str:
    colors = {
        "background": theme["bg_main"],
        "text": theme["fg_main"],
        "message": theme["fg_neutral"],
        "prompt": theme["fg_accent"],
        "placeholder": theme["fg_neutral"],
        "input": theme["fg_main"],
        "match": theme["fg_accent"],
        "selection": theme["bg_shadow_intense"],
        "selection-text": theme["fg_main"],
        "selection-match": theme["fg_accent"],
        "counter": theme["fg_neutral"],
        "border": theme["border"],
    }
    return "\n".join(
        [
            f"# Generated from the installed Emacs doric-themes palette: {theme['name']}.",
            "# Do not edit directly; regenerate with build-doric-themes.py.",
            "[colors]",
            *(f"{name}={fuzzel_color(color)}" for name, color in colors.items()),
            "",
        ]
    )


def pi_theme_json(theme: dict[str, str]) -> str:
    secondary_text = pi_secondary_text(theme)
    vars_block = {
        "accent": theme["fg_accent"],
        "border": theme["border"],
        "borderAccent": theme["cursor"],
        "borderMuted": mute_color(theme, theme["border"]),
        "success": theme["fg_green"],
        "error": theme["fg_red"],
        "warning": theme["fg_yellow"],
        "muted": theme["fg_neutral"],
        "dim": theme["fg_shadow_subtle"],
        "text": theme["fg_main"],
        "thinkingText": secondary_text,
        "selectedBg": theme["bg_shadow_intense"],
        "userMessageBg": theme["bg_shadow_subtle"],
        "userMessageText": theme["fg_main"],
        "customMessageBg": theme["bg_accent"],
        "customMessageText": theme["fg_main"],
        "customMessageLabel": pi_soft_highlight(theme, theme["fg_magenta"]),
        "toolPendingBg": pi_surface(theme, theme["bg_blue"]),
        "toolSuccessBg": pi_surface(theme, theme["bg_green"]),
        "toolErrorBg": pi_surface(theme, theme["bg_red"]),
        "toolTitle": theme["fg_main"],
        "toolOutput": secondary_text,
        "mdHeading": theme["fg_yellow"],
        "mdLink": theme["fg_blue"],
        "mdLinkUrl": secondary_text,
        "mdCode": theme["fg_accent"],
        "mdCodeBlock": theme["fg_green"],
        "mdCodeBlockBorder": theme["border"],
        "mdQuote": secondary_text,
        "mdQuoteBorder": theme["fg_neutral"],
        "mdHr": theme["fg_neutral"],
        "mdListBullet": theme["fg_accent"],
        "toolDiffAdded": theme["fg_green"],
        "toolDiffRemoved": theme["fg_red"],
        "toolDiffContext": secondary_text,
        "syntaxComment": theme["fg_accent"],
        "syntaxKeyword": theme["fg_blue"],
        "syntaxFunction": theme["fg_yellow"],
        "syntaxVariable": theme["fg_main"],
        "syntaxString": theme["fg_green"],
        "syntaxNumber": theme["fg_magenta"],
        "syntaxType": theme["fg_cyan"],
        "syntaxOperator": theme["fg_main"],
        "syntaxPunctuation": secondary_text,
        "thinkingOff": mute_color(theme, theme["border"]),
        "thinkingMinimal": theme["fg_neutral"],
        "thinkingLow": pi_soft_highlight(theme, theme["fg_blue"]),
        "thinkingMedium": pi_soft_highlight(theme, theme["fg_cyan"]),
        "thinkingHigh": pi_soft_highlight(theme, theme["fg_magenta"]),
        "thinkingXhigh": pi_soft_highlight(
            theme, mix_colors(theme["fg_magenta"], theme["fg_red"], 0.35)
        ),
        "bashMode": theme["fg_green"],
    }
    payload = {
        "$schema": PI_THEME_SCHEMA,
        "name": theme["name"],
        "vars": vars_block,
        "colors": {name: name for name in vars_block},
        "export": {
            "pageBg": theme["bg_main"],
            "cardBg": theme["bg_shadow_subtle"],
            "infoBg": soften_surface(theme, theme["bg_yellow"]),
        },
    }
    return json.dumps(payload, indent=2) + "\n"


def waybar_theme_text(theme: dict[str, str]) -> str:
    return "\n".join(
        [
            f"/* Generated from the installed Emacs doric-themes palette: {theme['name']}. */",
            "/* Do not edit directly; regenerate with build-doric-themes.py. */",
            f"@define-color background {theme['bg_main']};",
            f"@define-color surface {theme['bg_shadow_subtle']};",
            f"@define-color surface_alt {theme['bg_neutral']};",
            f"@define-color text {theme['fg_main']};",
            f"@define-color muted {theme['fg_neutral']};",
            f"@define-color border {theme['border']};",
            f"@define-color accent {theme['fg_accent']};",
            f"@define-color shadow {mix_colors(theme['bg_main'], '#000000', 0.55)};",
            f"@define-color success {theme['fg_green']};",
            f"@define-color warning {theme['fg_yellow']};",
            f"@define-color error {theme['fg_red']};",
            "",
        ]
    )


def with_alpha(color: str, alpha: str) -> str:
    return f"{color}{alpha}"


def niri_theme_text(theme: dict[str, str]) -> str:
    return "\n".join(
        [
            f"// Generated from the installed Emacs doric-themes palette: {theme['name']}.",
            "// Do not edit directly; regenerate with build-doric-themes.py.",
            "layout {",
            f'    background-color "{theme["bg_shadow_subtle"]}"',
            "",
            "    focus-ring {",
            f'        active-color "{theme["fg_accent"]}"',
            f'        inactive-color "{theme["border"]}"',
            f'        urgent-color "{theme["fg_red"]}"',
            "    }",
            "",
            "    border {",
            f'        active-color "{theme["fg_accent"]}"',
            f'        inactive-color "{theme["border"]}"',
            f'        urgent-color "{theme["fg_red"]}"',
            "    }",
            "",
            "    shadow {",
            f'        color "{with_alpha(mix_colors(theme["bg_main"], "#000000", 0.55), "70")}"',
            f'        inactive-color "{with_alpha(mix_colors(theme["bg_main"], "#000000", 0.55), "45")}"',
            "    }",
            "",
            "    tab-indicator {",
            f'        active-color "{theme["fg_accent"]}"',
            f'        inactive-color "{theme["border"]}"',
            f'        urgent-color "{theme["fg_red"]}"',
            "    }",
            "",
            "    insert-hint {",
            f'        color "{with_alpha(theme["fg_accent"], "80")}"',
            "    }",
            "}",
            "",
            "overview {",
            f'    backdrop-color "{theme["bg_shadow_subtle"]}"',
            "}",
            "",
        ]
    )


@dataclass(frozen=True)
class Target:
    output_dir: Path
    filename: Callable[[str], str]
    render: Callable[[dict[str, str]], str]


def unchanged_filename(theme_name: str) -> str:
    return theme_name


def ini_filename(theme_name: str) -> str:
    return f"{theme_name}.ini"


def json_filename(theme_name: str) -> str:
    return f"{theme_name}.json"


def kdl_filename(theme_name: str) -> str:
    return f"{theme_name}.kdl"


def css_filename(theme_name: str) -> str:
    return f"{theme_name}.css"


TARGETS = {
    "fuzzel": Target(FUZZEL_THEME_DIR, ini_filename, fuzzel_theme_text),
    "ghostty": Target(GHOSTTY_THEME_DIR, unchanged_filename, ghostty_theme_text),
    "niri": Target(NIRI_THEME_DIR, kdl_filename, niri_theme_text),
    "pi": Target(PI_THEME_DIR, json_filename, pi_theme_json),
    "waybar": Target(WAYBAR_THEME_DIR, css_filename, waybar_theme_text),
}


def write_text(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")


def remove_stale_generated_themes(
    target: Target, theme_data: list[dict[str, str]]
) -> int:
    expected_names = {target.filename(theme["name"]) for theme in theme_data}
    removed = 0
    for path in target.output_dir.iterdir():
        if not path.is_file() or path.name in expected_names:
            continue
        if GENERATED_MARKER not in path.read_text(encoding="utf-8"):
            continue
        path.unlink()
        removed += 1
    return removed


def main() -> int:
    args = parse_args()
    if args.all and args.theme:
        print("--all cannot be combined with --theme.", file=sys.stderr)
        return 1
    theme_data = load_theme_data()
    requested = set(args.theme)
    if requested:
        theme_data = [theme for theme in theme_data if theme["name"] in requested]
        missing = sorted(requested - {theme["name"] for theme in theme_data})
        if missing:
            print(f"Unknown Doric theme(s): {', '.join(missing)}", file=sys.stderr)
            return 1

    if args.target == "all":
        targets = set(TARGETS)
    elif args.target == "both":
        targets = {"ghostty", "pi"}
    else:
        targets = {args.target}

    for target_name in targets:
        ensure_dir(TARGETS[target_name].output_dir)

    removed = 0
    if not requested:
        for target_name in targets:
            removed += remove_stale_generated_themes(TARGETS[target_name], theme_data)

    for theme in theme_data:
        for target_name in targets:
            target = TARGETS[target_name]
            write_text(
                target.output_dir / target.filename(theme["name"]),
                target.render(theme),
            )

    target_dirs = [
        TARGETS[target].output_dir.relative_to(REPO_ROOT) for target in sorted(targets)
    ]
    print(
        "Generated "
        f"{len(theme_data)} Doric theme(s) for {args.target} under "
        + ", ".join(str(path) for path in target_dirs)
        + "."
    )
    if removed:
        print(f"Removed {removed} stale generated theme(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
