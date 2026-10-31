;;; my-emacs-editing.el --- Editing aids configuration -*- lexical-binding: t -*-

;;; Commentary:

;; Basic editing settings, Markdown and Org, Jinx spell checking, editorconfig,
;; rainbow-delimiters, ws-butler, and autorevert configuration.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-parse)

(defvar markdown-open-image-command)
(defvar markdown-translate-filename-function)

(defun my/ask-user-about-supersession-threat-accept (_filename)
  "Handle stale visited files without interactive prompts.
If the buffer is unmodified, refresh it from disk before continuing.
If the buffer already has local edits, keep them and continue editing."
  (if (buffer-modified-p)
      nil
    (revert-buffer nil t)))

(defun my/install-supersession-policy (&optional loaded-file)
  "Install automatic supersession policy for stale-file checks.
When LOADED-FILE is non-nil, only re-apply on userlock loads."
  (when (or (null loaded-file)
            (string-match-p "/userlock\\.elc?\\'" loaded-file))
    (defalias 'ask-user-about-supersession-threat
      #'my/ask-user-about-supersession-threat-accept)))

(my/install-supersession-policy nil)
;; Unlike one-time package configuration, this must survive userlock reloads.
(add-hook 'after-load-functions #'my/install-supersession-policy)

(use-package emacs
  :ensure nil
  :custom
  (ring-bell-function 'ignore)
  (visible-bell nil)
  (scroll-conservatively 101)
  :config
  (delete-selection-mode)
  (electric-pair-mode)
  (pixel-scroll-precision-mode)
  (setq-default indent-tabs-mode nil))

(use-package editorconfig
  :ensure nil
  :config
  (editorconfig-mode 1))

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

(defun my/prose-wrap-indicators ()
  "Hide continuation indicators without changing unrelated fringe settings."
  (when (and visual-line-mode (derived-mode-p 'org-mode 'markdown-mode))
    (setq-local visual-line-fringe-indicators '(nil nil))
    (setq-local fringe-indicator-alist
                (cons '(continuation nil nil)
                      (assq-delete-all 'continuation
                                       (copy-tree fringe-indicator-alist))))))

(defun my/prose-wrap ()
  "Enable soft wrapping without inserting physical newlines."
  ;; `visual-line-mode' copies this option into `fringe-indicator-alist'.
  (setq-local visual-line-fringe-indicators '(nil nil))
  (visual-line-mode 1)
  (add-hook 'visual-line-mode-hook #'my/prose-wrap-indicators nil t)
  (add-hook 'writeroom-mode-hook #'my/prose-wrap-indicators nil t)
  (my/prose-wrap-indicators))

(use-package markdown-mode
  :ensure nil
  :mode "\\.md\\'"
  :hook (markdown-mode . my/prose-wrap)
  :custom
  (markdown-fontify-code-blocks-natively t)
  (markdown-header-scaling t)
  :config
  (defun my/markdown-refresh-heading-scaling (&optional _theme)
    "Reapply Markdown's heading scaling after loading a theme."
    (markdown-update-header-faces markdown-header-scaling))
  ;; Themes can replace the heights installed by the option's Custom setter.
  (add-hook 'enable-theme-functions #'my/markdown-refresh-heading-scaling)
  (my/markdown-refresh-heading-scaling)
  (add-hook 'markdown-follow-link-functions
            #'my/markdown-follow-file-link-other-window))

(use-package org
  :ensure nil
  :defer t
  :hook (org-mode . my/prose-wrap)
  :config
  (defface my/org-comment-block
    '((t :inherit shadow :slant italic))
    "Theme-derived styling for the contents of Org comment blocks."
    :group 'org-faces)
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
  (advice-add 'org-fontify-meta-lines-and-blocks :around
              #'my/org-fontify-comment-block)
  (defun my/org-refresh-heading-scaling (&optional _theme)
    "Reapply Org heading heights without replacing theme colours or styling."
    (cl-loop for level from 1 to 8
             for height in '(2.0 1.7 1.4 1.1 1.0 1.0 1.0 1.0)
             do (set-face-attribute (intern (format "org-level-%d" level))
                                    nil :height height)))
  (add-hook 'enable-theme-functions #'my/org-refresh-heading-scaling)
  (my/org-refresh-heading-scaling))

(use-package jinx
  :ensure nil
  :hook ((text-mode . jinx-mode)
         (prog-mode . jinx-mode))
  :bind (("M-$" . jinx-correct)
         ("C-M-$" . jinx-languages))
  :custom
  (jinx-languages "en_AU")
  :config
  ;; Check programming comments and docstrings, but not ordinary strings.
  (cl-pushnew 'font-lock-string-face (alist-get 'prog-mode jinx-exclude-faces))
  ;; Indented Markdown code uses this face rather than markdown-code-face.
  ;; Preserve Jinx's other per-mode exclusions, including native fenced code.
  (cl-pushnew 'markdown-pre-face (alist-get 'markdown-mode jinx-exclude-faces)))

(use-package rainbow-delimiters
  :ensure nil
  :hook (emacs-lisp-mode prog-mode))

(use-package ws-butler
  :ensure nil
  :hook prog-mode)

(use-package autorevert
  :ensure nil
  :hook (after-init . global-auto-revert-mode)
  :custom
  (auto-revert-avoid-polling t)
  (global-auto-revert-non-file-buffers t)
  ;; Controls revert prompts; supersession edit/save prompts are handled above.
  (revert-without-query '(".*")))

(provide 'my-emacs-editing)
;;; my-emacs-editing.el ends here
