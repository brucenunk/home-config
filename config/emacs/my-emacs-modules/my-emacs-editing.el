;;; my-emacs-editing.el --- Editing aids configuration -*- lexical-binding: t -*-

;;; Commentary:

;; Basic editing settings, Markdown, editorconfig,
;; rainbow-delimiters, ws-butler, and autorevert configuration.

;;; Code:

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

(use-package markdown-mode
  :ensure nil
  :mode "\\.md\\'"
  :custom
  (markdown-fontify-code-blocks-natively t)
  :config
  (add-hook 'markdown-follow-link-functions
            #'my/markdown-follow-file-link-other-window))

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
