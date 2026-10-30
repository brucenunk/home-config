# Create an Excalidraw drawing from Org

In a saved, writable Org document, run **`M-x my/excali-org-new`**
and choose a new drawing path. There is no dedicated Org keybinding. Completion starts in
`my/excali-directory` (`~/work/docs/diagrams/`); other existing directories
are allowed. A name without an extension gets `.excalidraw` appended.
Existing files, dangling symlinks, and paths reserved by another open workflow
are rejected. No scene file or link is created merely by entering the editor.

The drawing opens in the current window using the existing theme/palette policy.
Only drawings created through this workflow get these bindings:

| Key | Action |
| --- | --- |
| `C-c C-c` | Save, insert one relative `excali:` link, return and preview |
| `C-c C-k` | Cancel and return, confirming before discarding unsaved work |
| `C-x C-s` / `s-s` | Save without inserting a link or returning |

Saving uses the chosen path without another filename prompt. The first write
checks for a collision again and refuses to overwrite a file that appeared
since creation. Later saves update the workflow's own saved file normally.
Ordinary saves refresh existing previews through the existing integration.

The origin is a buffer-local marker, not a copied position. It follows edits;
text inserted exactly there goes before the eventual link. Deleting surrounding
text moves the marker according to normal Emacs rules. Save-and-return leaves
the drawing buffer available; invoking it again saves and returns without
inserting a second link, even if you have since removed or undone that link.
The Org document is modified, not automatically saved.

The originating window is reused if it survives; otherwise the current window
is used. Other windows are not rearranged, and window changes made while drawing
are not undone. If the origin has died, is no longer Org, is read-only, or its
marker is detached or outside the accessible narrowed region, the saved drawing
is preserved and its path reported without inserting elsewhere. Fixing a
temporary restriction permits retrying save-and-return. A preview failure does
not roll back an inserted link or permit a duplicate on retry.

Cancellation kills only this drawing buffer. Unsaved scene changes, including
style/default changes, require confirmation; declining leaves the workflow open.
A previously saved file is never deleted. Closing one of these workflow buffers
also checks for unsaved work, but never saves automatically. Unrelated drawing
buffers retain native keybindings and close/save behavior.

Existing link insertion, saved-scene rendering, caching and palette behavior are
documented in [`config/excali/README.md`](../config/excali/README.md).

## Verification

The isolated `my-emacs-org-excali-tests.el` entry point loads both the editor and
Org ERT suites. New workflow checks use native scenes/saves/rendering with GUI
presentation stubbed. They are not live graphical acceptance evidence.

Run with the configured Emacs package:

```sh
emacs --batch -Q -L config/emacs/my-emacs-modules \
  --load my-emacs-org-excali-tests --funcall ert-run-tests-batch-and-exit
```

### Graphical acceptance checklist (not yet run)

These checks require a graphical Emacs carrying the changed configuration.
Deployment and live-process testing require separate permission and the Emacs
server safety procedure; passing batch tests or building Home Manager does not
prove deployment or runtime pickup.

1. Split a frame, open a saved Org document, place point on a blank line, and
   run `M-x my/excali-org-new`. Name a new diagram. Confirm only the selected window changes,
   the active theme's canvas/defaults appear, and no link or scene file exists.
2. Draw a labelled shape. Press `C-c C-c`. Confirm the file is saved, the original
   window returns to Org, and exactly one relative link appears as an inline
   preview. Save the Org document normally.
3. Return to the still-open drawing, edit the shape, and use `C-x C-s`. Confirm
   it stays in the drawing and the displayed Org preview refreshes. Use `C-c C-c`
   again and confirm no second link is inserted.
4. Start another drawing and cancel immediately. Confirm no file/link appears.
   Repeat after drawing: decline the discard prompt, then cancel and accept it.
   Repeat after ordinary save; confirm cancellation preserves the saved file.
5. Start two workflows at different positions, edit text around both markers,
   and finish in reverse order. Confirm each link lands at its own tracked point.
6. Delete the originating window while drawing, then finish. Confirm the current
   window returns to Org without recreating the old split layout.
7. Make an origin read-only, then finish. Confirm the saved path is reported
   without insertion. Make it writable and retry: exactly one link appears.
   Repeat with a killed origin and verify no other document is modified.