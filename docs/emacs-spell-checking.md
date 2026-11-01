# Spell checking

Jinx checks prose in text buffers and highlighted comments/docstrings in code.
Use `M-x jinx-mode` to toggle it. Ordinary code strings are excluded; checking
is face-based, so unfamiliar modes may skip prose or check unmarked code.

| Command | Action |
| --- | --- |
| `M-$` | Correct the nearest misspelling or active region. |
| `C-u M-$` | Correct all misspellings. |
| `C-u C-u M-$` | Correct the word at point even if accepted. |
| `M-x jinx-occur` | List misspellings. |
| `C-M-$` | Choose buffer languages. |

Australian English (`en_AU`) is the default; `en_US` is also installed. Choosing
both accepts words from either dictionary, not consistent spelling. Decline
saving file-local variables for a buffer-only language change. `C-u C-M-$`
changes the session default; toggle Jinx in existing buffers to reload it.

In the correction prompt, choose `@word` under the intended personal dictionary
to save a word (`@@word` selects the second dictionary when both are active).
Use `M-x jinx-remove-word` to remove it. Hunspell personal dictionaries live in
`$XDG_CONFIG_HOME/enchant/{en_AU,en_US}.dic`; these are writable user data.
File/directory acceptance entries modify local-variable configuration instead.

Downstream startup configuration can set a work default before opening buffers:

```elisp
(with-eval-after-load 'my-emacs-editing
  (setq-default jinx-languages "en_US"))
```

If dictionaries are unavailable, check that Emacs inherited Home Manager's
`DICPATH`. No runtime package installation or compilation is needed.
