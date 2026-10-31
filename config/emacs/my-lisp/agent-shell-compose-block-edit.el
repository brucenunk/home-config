;;; agent-shell-compose-block-edit.el --- Native-mode draft block editing -*- lexical-binding: t -*-

;;; Commentary:
;; C-c ' in a composer opens a complete Org/Markdown source block in its native
;; mode.  C-c C-c (or C-c ') finishes; C-c C-k cancels.  Nothing is submitted.
;; This is a separate editable copy, not an indirect buffer: cancellation can
;; truly discard changes.  Any intervening composer text edit, submission, or
;; edit/view transition makes write-back fail closed, retaining the edit copy.

;;; Code:

(require 'agent-shell-compose)

(defvar-local agent-shell-compose-block-edit--source nil)
(defvar-local agent-shell-compose-block-edit--source-window nil)
(defvar-local agent-shell-compose-block-edit--generation nil)
(defvar-local agent-shell-compose-block-edit--tick nil)
(defvar-local agent-shell-compose-block-edit--block nil)

(defvar agent-shell-compose-block-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'agent-shell-compose-block-edit-finish)
    (define-key map (kbd "C-c '") #'agent-shell-compose-block-edit-finish)
    (define-key map (kbd "C-c C-k") #'agent-shell-compose-block-edit-cancel)
    map))

(define-minor-mode agent-shell-compose-block-edit-mode
  "Edit a composer block; finish with C-c C-c or cancel with C-c C-k."
  :lighter " Compose-Block"
  :keymap agent-shell-compose-block-edit-mode-map)

;; An untyped/unknown block may need a manually selected language mode.  Keep
;; the editing session and its finish/cancel controls across that mode change.
(dolist (variable '(agent-shell-compose-block-edit-mode
                    agent-shell-compose-block-edit--source
                    agent-shell-compose-block-edit--source-window
                    agent-shell-compose-block-edit--generation
                    agent-shell-compose-block-edit--tick
                    agent-shell-compose-block-edit--block))
  (put variable 'permanent-local t))

(defun agent-shell-compose-block-edit ()
  "Edit the complete source block at point in its native language mode.
Preserve raw indentation and body text.  Unknown languages use
`fundamental-mode'.  Unclosed blocks must be closed before editing."
  (interactive)
  (unless (derived-mode-p 'agent-shell-viewport-edit-mode)
    (user-error "Not in a native agent-shell composer"))
  (let* ((block (or (agent-shell-compose-block-at-point)
                    (user-error "Point is not in a complete source block")))
         (source (current-buffer))
         (source-window (selected-window))
         (generation agent-shell-compose--generation)
         (tick (buffer-chars-modified-tick))
         (beg (plist-get block :body-begin))
         (end (plist-get block :body-end))
         (offset (max 0 (min (- (point) beg) (- end beg))))
         (text (buffer-substring-no-properties beg end))
         (directory default-directory)
         (mode (agent-shell-compose-block-mode block))
         (editor (generate-new-buffer "*agent-shell-compose-block*")))
    (condition-case err
        (progn
          (when (text-property-not-all beg end 'agent-shell-context-image nil)
            (user-error "Move image attachments outside the block before editing it"))
          (with-current-buffer editor
            (setq default-directory directory)
            (funcall mode)
            (insert text)
            (setq-local agent-shell-compose-block-edit--source source
                        agent-shell-compose-block-edit--source-window source-window
                        agent-shell-compose-block-edit--generation generation
                        agent-shell-compose-block-edit--tick tick
                        agent-shell-compose-block-edit--block block)
            (agent-shell-compose-block-edit-mode 1)
            (goto-char (+ (point-min) offset))
            ;; Loading the original body is not a user edit to undo.
            (setq buffer-undo-list nil)
            (set-buffer-modified-p nil))
          (pop-to-buffer editor))
      (error
       (kill-buffer editor)
       (signal (car err) (cdr err))))))

(defun agent-shell-compose-block-edit--return ()
  "Dismiss this editing copy and return to its original composer window."
  (let* ((editor (current-buffer))
         (source agent-shell-compose-block-edit--source)
         (source-window agent-shell-compose-block-edit--source-window)
         (editor-window (get-buffer-window editor)))
    (set-buffer-modified-p nil)
    ;; Unlike `kill-buffer', `quit-window' also removes a popup split or
    ;; restores a reused window, following display-buffer's quit-restore data.
    (if (window-live-p editor-window)
        (quit-window 'kill editor-window)
      (kill-buffer editor))
    (when (buffer-live-p source)
      (if (and (window-live-p source-window)
               (eq (window-buffer source-window) source))
          (select-window source-window)
        (pop-to-buffer source '(display-buffer-reuse-window))))))

(defun agent-shell-compose-block-edit-finish ()
  "Write this block edit back, refusing any intervening composer change.
Leave the editor and its text intact on conflict.  Refuse body text that
would close the containing block; never silently escape or convert code."
  (interactive)
  (unless agent-shell-compose-block-edit-mode
    (user-error "Not in a composer block editor"))
  (let* ((source agent-shell-compose-block-edit--source)
         (generation agent-shell-compose-block-edit--generation)
         (tick agent-shell-compose-block-edit--tick)
         (block agent-shell-compose-block-edit--block)
         (text (save-restriction
                 (widen)
                 (buffer-substring-no-properties (point-min) (point-max))))
         (offset (save-restriction (widen) (- (point) (point-min))))
         (case-fold-search (eq (plist-get block :markup) 'org)))
    (unless (buffer-live-p source)
      (user-error "Composer was killed; edited code remains in this buffer"))
    (when (string-match-p (plist-get block :invalid-body-regexp) text)
      (user-error "Edited code would break the containing source block"))
    ;; Keep the closing delimiter on its own line even if the native editor
    ;; removed the body's final newline.  Empty blocks need no extra line.
    (unless (or (string-empty-p text) (string-suffix-p "\n" text))
      (setq text (concat text "\n")))
    (with-current-buffer source
      (unless (and (derived-mode-p 'agent-shell-viewport-edit-mode)
                   (eq generation agent-shell-compose--generation)
                   (= tick (buffer-chars-modified-tick))
                   (not buffer-read-only))
        (user-error "Composer changed; edited code remains in the block editor"))
      (let ((beg (plist-get block :body-begin))
            (end (plist-get block :body-end)))
        (atomic-change-group
          (delete-region beg end)
          (goto-char beg)
          (insert text))))
    (agent-shell-compose-block-edit--return)
    ;; Restoring a reused window (or selecting the original source window)
    ;; restores its saved window-point too.  Set the edit position afterwards.
    (goto-char (+ (plist-get block :body-begin) (min offset (length text))))))

(defun agent-shell-compose-block-edit-cancel ()
  "Discard this editing copy without touching or submitting the draft."
  (interactive)
  (unless agent-shell-compose-block-edit-mode
    (user-error "Not in a composer block editor"))
  (agent-shell-compose-block-edit--return))

(provide 'agent-shell-compose-block-edit)
;;; agent-shell-compose-block-edit.el ends here