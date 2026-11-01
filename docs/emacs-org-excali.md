# Create a drawing from Org

In a saved, writable Org document, run **`M-x my/excali-org-new`** and choose a
new drawing path. Completion starts in `~/work/docs/diagrams/`; other existing
directories are allowed. `.excalidraw` is appended when no extension is given.
Existing files are rejected. Entering the editor creates neither a file nor a link.

| Key | Action |
| --- | --- |
| `C-c C-c` | Save, insert one relative `excali:` link, return and preview. |
| `C-c C-k` | Cancel and return; confirm discarding unsaved changes. |
| `C-x C-s` / `s-s` | Save without inserting a link or returning. |

The insertion point follows edits in the original Org buffer. The Org document
is modified but not saved automatically. Repeating save-and-return never inserts
a second link, even if the first was undone or removed.

If the origin is unavailable, read-only or narrowed away, the drawing is saved
and its path reported without inserting elsewhere. Fix a temporary restriction
and retry. A preview failure does not permit duplicate insertion. Cancelling
kills only the drawing buffer and never deletes a previously saved file.

See [`config/excali/README.md`](../config/excali/README.md) for palettes,
existing-link insertion, previews and publication export.
