;;; my-emacs-editing.el --- Editing aids configuration -*- lexical-binding: t -*-

;;; Commentary:

;; Basic editing settings, read-only file defaults, Markdown, editorconfig,
;; rainbow-delimiters, ws-butler, and autorevert configuration.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'url-parse)

(declare-function server-visit-files "server" (files proc &optional nowait))
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

(defgroup my-read-only-file-buffers nil
  "Read-only defaults for ordinary file buffers."
  :group 'editing)

(defcustom my/global-read-only-file-buffers-editor-file-names
  '("COMMIT_EDITMSG"
    "MERGE_MSG"
    "TAG_EDITMSG"
    "SQUASH_MSG"
    "git-rebase-todo"
    "addp-hunk-edit.diff")
  "File names that should stay editable for external-editor workflows.
This list covers filename-based exceptions.  Waiting `emacsclient' visits,
including Pi message edits launched through the Emacs server, are handled
separately by `my/global-read-only-file-buffers-mode'."
  :type '(repeat string)
  :group 'my-read-only-file-buffers)

(defcustom my/global-read-only-file-buffers-writable-directories
  (list (expand-file-name "~/work/tasks/"))
  "Directories whose file buffers should stay writable by default.
These are workflow-owned files that commands may update directly, even when
visited in an ordinary file buffer.  Directory values are expanded before
comparison."
  :type '(repeat directory)
  :group 'my-read-only-file-buffers)

(defun my/global-read-only-file-buffers-editor-file-p ()
  "Return non-nil when the current buffer is for external-editor input."
  (and buffer-file-name
       (member (file-name-nondirectory buffer-file-name)
               my/global-read-only-file-buffers-editor-file-names)))

(defun my/global-read-only-file-buffers-writable-directory-p ()
  "Return non-nil when the current buffer is under a writable directory."
  (and buffer-file-name
       (let ((file (expand-file-name buffer-file-name)))
         (seq-some
          (lambda (dir)
            (file-in-directory-p file (file-name-as-directory
                                       (expand-file-name dir))))
          my/global-read-only-file-buffers-writable-directories))))

(defun my/global-read-only-file-buffers-writable-file-p ()
  "Return non-nil when the current buffer should stay writable by default."
  (or (my/global-read-only-file-buffers-editor-file-p)
      (my/global-read-only-file-buffers-writable-directory-p)))

(defun my/global-read-only-file-buffers-file-p ()
  "Return non-nil when the current buffer should default to read-only."
  (and buffer-file-name
       (file-exists-p buffer-file-name)
       (file-regular-p buffer-file-name)
       (not (my/global-read-only-file-buffers-writable-file-p))))

(defun my/global-read-only-file-buffers-enable ()
  "Apply read-only defaults for ordinary existing file buffers.
This applies to file buffers opened via `find-file', Dired, file links,
and other file-visiting commands.  Use `read-only-mode' (`C-x C-q') to
make a buffer editable when needed.  Workflow-owned files stay writable."
  (when (and buffer-file-name
             (file-exists-p buffer-file-name)
             (file-regular-p buffer-file-name))
    (if (my/global-read-only-file-buffers-writable-file-p)
        (read-only-mode -1)
      (read-only-mode 1))))

(defvar my/global-read-only-file-buffers--server-waiting-visit nil
  "Non-nil while the Emacs server is visiting files for a waiting client.")

(defun my/global-read-only-file-buffers-server-visit-files-advice
    (orig-fn files proc &optional nowait)
  "Track whether `server-visit-hook' is running for a waiting client."
  (let ((my/global-read-only-file-buffers--server-waiting-visit (not nowait)))
    (funcall orig-fn files proc nowait)))

(defun my/global-read-only-file-buffers-disable-for-server-visit ()
  "Keep waiting external-editor buffers opened through the Emacs server editable."
  (when (and buffer-file-name
             my/global-read-only-file-buffers--server-waiting-visit)
    (read-only-mode -1)))

(define-minor-mode my/global-read-only-file-buffers-mode
  "Toggle read-only defaults for ordinary file buffers.
When enabled, ordinary existing file buffers open read-only by default.
External-editor files named in
`my/global-read-only-file-buffers-editor-file-names' stay editable, as do
waiting external-editor visits opened through the Emacs server."
  :global t
  :group 'my-read-only-file-buffers
  (if my/global-read-only-file-buffers-mode
      (progn
        (add-hook 'find-file-hook #'my/global-read-only-file-buffers-enable)
        (add-hook 'server-visit-hook
                  #'my/global-read-only-file-buffers-disable-for-server-visit)
        (with-eval-after-load 'server
          (when (and my/global-read-only-file-buffers-mode
                     (not (advice-member-p
                           #'my/global-read-only-file-buffers-server-visit-files-advice
                           #'server-visit-files)))
            (advice-add #'server-visit-files :around
                        #'my/global-read-only-file-buffers-server-visit-files-advice))))
    (remove-hook 'find-file-hook #'my/global-read-only-file-buffers-enable)
    (remove-hook 'server-visit-hook
                 #'my/global-read-only-file-buffers-disable-for-server-visit)
    (when (fboundp 'server-visit-files)
      (advice-remove #'server-visit-files
                     #'my/global-read-only-file-buffers-server-visit-files-advice))))

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
  (my/global-read-only-file-buffers-mode 1)
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
