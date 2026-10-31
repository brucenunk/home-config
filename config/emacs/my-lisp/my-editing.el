;;; my-editing.el --- Editing and prose helpers -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; Implementation for the configuration in my-emacs.org.
;; Public functions/commands:
;;   - my/ask-user-about-supersession-threat-accept
;;   - my/install-supersession-policy
;;   - my/markdown-follow-file-link-other-window
;;   - my/prose-wrap-indicators
;;   - my/prose-wrap
;;   - my/markdown-refresh-heading-scaling
;;   - my/org-fontify-comment-block
;;   - my/org-refresh-heading-scaling

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-parse)

(defvar markdown-open-image-command)

(defvar markdown-translate-filename-function)

;;;###autoload
(defun my/ask-user-about-supersession-threat-accept (_filename)
  "Handle stale visited files without interactive prompts.
If the buffer is unmodified, refresh it from disk before continuing.
If the buffer already has local edits, keep them and continue editing."
  (if (buffer-modified-p)
      nil
    (revert-buffer nil t)))

;;;###autoload
(defun my/install-supersession-policy (&optional loaded-file)
  "Install automatic supersession policy for stale-file checks.
When LOADED-FILE is non-nil, only re-apply on userlock loads."
  (when (or (null loaded-file)
            (string-match-p "/userlock\\.elc?\\'" loaded-file))
    (defalias 'ask-user-about-supersession-threat
      #'my/ask-user-about-supersession-threat-accept)))

;;;###autoload
(defun my/markdown-follow-file-link-other-window (url)
  "Visit a local Markdown link URL in another window.
Return non-nil when URL was handled.  Leave absolute URLs and images with a
configured external opener to Markdown's default link handler."
  (let* ((parsed (url-generic-parse-url url))
         (file (car (url-path-and-query parsed))))
    (when (and (not (url-fullness parsed))
               file
               (not (string-empty-p file)))
      (let ((file (funcall markdown-translate-filename-function file)))
        (unless (and markdown-open-image-command
                     (string-match-p (image-file-name-regexp) file))
          (find-file-other-window file)
          t)))))

;;;###autoload
(defun my/prose-wrap-indicators ()
  "Hide continuation indicators without changing unrelated fringe settings."
  (when (and visual-line-mode (derived-mode-p 'org-mode 'markdown-mode))
    (setq-local visual-line-fringe-indicators '(nil nil))
    (setq-local fringe-indicator-alist
                (cons '(continuation nil nil)
                      (assq-delete-all 'continuation
                                       (copy-tree fringe-indicator-alist))))))

;;;###autoload
(defun my/prose-wrap ()
  "Enable soft wrapping without inserting physical newlines."
  ;; `visual-line-mode' copies this option into `fringe-indicator-alist'.
  (setq-local visual-line-fringe-indicators '(nil nil))
  (visual-line-mode 1)
  (add-hook 'visual-line-mode-hook #'my/prose-wrap-indicators nil t)
  (add-hook 'writeroom-mode-hook #'my/prose-wrap-indicators nil t)
  (my/prose-wrap-indicators))

;;;###autoload
(defun my/markdown-refresh-heading-scaling (&optional _theme)
  "Reapply Markdown's heading scaling after loading a theme."
  (markdown-update-header-faces markdown-header-scaling))

(defface my/org-comment-block
  '((t :inherit shadow :slant italic))
  "Theme-derived styling for the contents of Org comment blocks."
  :group 'org-faces)

;;;###autoload
(defun my/org-fontify-comment-block (fontify limit)
  "Extend Org's native block FONTIFY up to LIMIT with comment-body styling.
Reuse its multiline region and invalidation rather than scanning on edits."
  (let ((start (point))
        (result (funcall fontify limit)))
    (when result
      (save-excursion
        (let ((end (point)) (case-fold-search t))
          (goto-char start)
          (when (and (re-search-forward "^[ \t]*#\\+begin_\\([[:alnum:]]+\\)\\b.*\n" end t)
                     (equal (downcase (match-string 1)) "comment"))
            (let ((body (point)))
              (when (re-search-forward "^[ \t]*#\\+end_comment\\b" end t)
                (put-text-property body (line-beginning-position)
                                   'face 'my/org-comment-block)))))))
    result))

;;;###autoload
(defun my/org-refresh-heading-scaling (&optional _theme)
  "Reapply Org heading heights without replacing theme colours or styling."
  (cl-loop for level from 1 to 8
           for height in '(2.0 1.7 1.4 1.1 1.0 1.0 1.0 1.0)
           do (set-face-attribute (intern (format "org-level-%d" level))
                                  nil :height height)))

(provide 'my-editing)
;;; my-editing.el ends here