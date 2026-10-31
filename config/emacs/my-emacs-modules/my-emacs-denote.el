;;; my-emacs-denote.el --- Denote notes and task capture configuration -*- lexical-binding: t -*-

;;; Commentary:

;; Denote configuration for task files, templates, links, and auto-refresh.

;;; Code:

(declare-function my/denote-task-file-p "my-denote-task" ())

(defcustom my/denote-task-auto-revert-debounce-interval 0.3
  "Seconds to wait before reverting a task file after a change notification.
Lower values make reverts more responsive; higher values coalesce more
edits into a single revert.  The default (0.3s) balances responsiveness
with avoiding redundant reverts during rapid agent edits."
  :type 'number
  :group 'my-denote-task)

(defvar-local my/denote-task-auto-revert-debounce-timer nil
  "Debounce timer for task file auto-revert notifications.")

(defun my/denote-template (filename)
  "Read FILENAME from the Emacs denote-templates directory."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name filename (locate-user-emacs-file "denote-templates/")))
    (buffer-string)))

(defvar my/denote-startup-notes-buffer nil
  "Reusable notes buffer for empty startup and no-file clients.")

(defun my/denote-startup-buffer ()
  "Return all Denote files sorted newest first, or the scratch buffer.
Do not leave the caller's window layout changed while preparing the buffer."
  (let ((scratch (get-scratch-buffer-create)))
    (if (not (file-directory-p denote-directory))
        scratch
      (save-window-excursion
        (if (and (buffer-live-p my/denote-startup-notes-buffer)
                 (with-current-buffer my/denote-startup-notes-buffer
                   (derived-mode-p 'dired-mode)))
            (progn
              (switch-to-buffer my/denote-startup-notes-buffer)
              (revert-buffer nil t))
          (switch-to-buffer scratch)
          (denote-sort-dired "" 'identifier t nil))
        (if (derived-mode-p 'dired-mode)
            (setq my/denote-startup-notes-buffer (current-buffer))
          (setq my/denote-startup-notes-buffer nil)
          scratch)))))

(defun my/denote-startup ()
  "Show notes on empty startup, preserving explicitly requested buffers.
Install `initial-buffer-choice' afterward for future no-file clients."
  (when (and (not noninteractive)
             (not (daemonp))
             (eq (current-buffer) (get-buffer "*scratch*")))
    (switch-to-buffer (my/denote-startup-buffer)))
  (setq initial-buffer-choice #'my/denote-startup-buffer))

(add-hook 'emacs-startup-hook #'my/denote-startup)

(use-package denote
  :ensure nil
  :demand t
  :hook ((dired-mode    . denote-dired-mode-in-directories)
         (markdown-mode . denote-fontify-links-mode-maybe))
  :bind (("C-c n T" . my/denote-task)
         ("C-c n n" . denote)
         ("C-c n t" . denote-template)
         ("C-c n r" . denote-rename-file)
         ("C-c n l" . denote-link)
         ("C-c n b" . denote-backlinks))
  :config
  (require 'my-denote-task)
  (setq denote-templates
        '((task-workflow . (lambda () (my/denote-template "task-workflow.org")))))
  (setq denote-directory (expand-file-name "~/work/docs/"))
  (setq denote-dired-directories (list denote-directory))
  (setq denote-dired-directories-include-subdirectories t)
  (setq denote-known-keywords nil)
  (setq denote-file-type 'org)
  (setq denote-rename-confirmations nil)
  (defun my/denote-task-auto-revert-enable-after-save ()
    "Enable task auto-revert after a newly created task file is first saved."
    (remove-hook 'after-save-hook #'my/denote-task-auto-revert-enable-after-save t)
    (my/denote-task-auto-revert-enable-maybe))
  (defun my/denote-task-auto-revert-enable-maybe ()
    "Enable auto-revert for existing task files.
New Denote notes visit their target path before the file exists, so defer
until the first save to avoid reverting a not-yet-created task file."
    (when (my/denote-task-file-p)
      (if (and buffer-file-name
               (file-exists-p buffer-file-name))
          (progn
            (auto-revert-mode 1)
            (setq-local auto-revert-verbose nil))
        (add-hook 'after-save-hook #'my/denote-task-auto-revert-enable-after-save nil t))))
  (defun my/denote-rename-new-buffer-after-save ()
    "Rename a newly-created Denote buffer after its backing file exists."
    (remove-hook 'after-save-hook #'my/denote-rename-new-buffer-after-save t)
    (denote-rename-buffer-rename-function-or-fallback))
  (defun my/denote-rename-new-buffer-maybe ()
    "Rename a Denote buffer, deferring until first save if needed."
    (when (and buffer-file-name
               (denote-file-has-identifier-p buffer-file-name))
      (if (file-exists-p buffer-file-name)
          (denote-rename-buffer-rename-function-or-fallback)
        (add-hook 'after-save-hook #'my/denote-rename-new-buffer-after-save nil t))))
  (defun my/denote-link-normalize-file-arg (orig-fn file file-type description &optional id-only)
    "Normalize FILE to an absolute path before `denote-link' validates it.
Resolves relative task links against the shared Denote document root."
    (let* ((file (if (stringp file) (substring-no-properties file) file))
           (file (if (and (stringp file) (not (file-name-absolute-p file)))
                     (or
                      (let ((candidate (expand-file-name file denote-directory)))
                        (and (file-exists-p candidate) candidate))
                      (when-let* ((id (denote-extract-id-from-string file)))
                        (denote-get-path-by-id id))
                      file)
                   file)))
      (funcall orig-fn file file-type description id-only)))
  (advice-add #'denote-link :around #'my/denote-link-normalize-file-arg)
  (add-to-list 'revert-without-query
               (concat "^" (regexp-quote (file-name-as-directory denote-directory))))
  (denote-rename-buffer-mode 1)
  (remove-hook 'denote-after-new-note-hook
               #'denote-rename-buffer-rename-function-or-fallback)
  (remove-hook 'find-file-hook #'denote-rename-buffer-rename-function-or-fallback)
  (add-hook 'denote-after-new-note-hook #'my/denote-rename-new-buffer-maybe)
  (add-hook 'find-file-hook #'my/denote-rename-new-buffer-maybe))

(use-package consult-denote
  :ensure nil
  :after denote
  :bind (("C-c n f" . consult-denote-find)
         ("C-c n g" . consult-denote-grep))
  :config
  (setq consult-denote-find-command #'consult-fd)
  (consult-denote-mode 1))

(add-hook 'find-file-hook #'my/denote-task-auto-revert-enable-maybe)

;; Task-specific integration belongs here, not in the general editing module's
;; autorevert declaration.  Support either load order without loading autorevert.
(with-eval-after-load 'autorevert
  (defun my/denote-task-auto-revert--cancel-debounce ()
    "Cancel pending debounce timer in current buffer."
    (when (timerp my/denote-task-auto-revert-debounce-timer)
      (cancel-timer my/denote-task-auto-revert-debounce-timer)
      (setq my/denote-task-auto-revert-debounce-timer nil)))

  (defun my/denote-task-auto-revert-suppress-redisplay (orig-fn &rest args)
    "Inhibit redisplay during auto-revert for task files.
Prevents flash of unstyled content by suppressing intermediate
redisplay, then pre-fontifies visible windows before resuming."
    (if (not (my/denote-task-file-p))
        (apply orig-fn args)
      (let ((inhibit-redisplay t))
        (apply orig-fn args)
        (dolist (win (get-buffer-window-list (current-buffer) nil t))
          (font-lock-ensure (window-start win) (window-end win t))))))

  (defun my/denote-task-auto-revert-debounce-notify (orig-fn event)
    "Debounce auto-revert notifications for task files.
Uses `my/denote-task-auto-revert-debounce-interval' instead of the default
2.5s lockout to coalesce rapid edits into a single revert.
Only debounces content-change actions (changed, attribute-changed,
created); delegates all others (stopped, renamed, deleted) to the
default handler."
    (let* ((descriptor (car event))
           (action (nth 1 event))
           (buffer (alist-get descriptor auto-revert--buffer-by-watch-descriptor
                              nil nil #'equal)))
      (if (or (not (memq action '(changed attribute-changed created)))
              (not (buffer-live-p buffer))
              (not (with-current-buffer buffer (my/denote-task-file-p))))
          ;; Non-debounce path: delegate to default handler.
          ;; Cancel any pending debounce on stopped to avoid stale timer.
          (progn
            (when (and (eq action 'stopped)
                       (buffer-live-p buffer))
              (with-current-buffer buffer
                (my/denote-task-auto-revert--cancel-debounce)))
            (funcall orig-fn event))
        ;; Task file content-change: debounce with short timer
        (with-current-buffer buffer
          (setq auto-revert-notify-modified-p t)
          (my/denote-task-auto-revert--cancel-debounce)
          (setq my/denote-task-auto-revert-debounce-timer
                (run-with-timer
                 my/denote-task-auto-revert-debounce-interval nil
                 (lambda (buf)
                   (when (buffer-live-p buf)
                     (with-current-buffer buf
                       (setq my/denote-task-auto-revert-debounce-timer nil)
                       (when (bound-and-true-p auto-revert-mode)
                         (auto-revert-handler)))))
                 buffer))
          ;; Clean up timer if buffer is killed before it fires
          (add-hook 'kill-buffer-hook #'my/denote-task-auto-revert--cancel-debounce nil t)))))

  (advice-add 'auto-revert-handler :around
              #'my/denote-task-auto-revert-suppress-redisplay)
  (advice-add 'auto-revert-notify-handler :around
              #'my/denote-task-auto-revert-debounce-notify))

(provide 'my-emacs-denote)
;;; my-emacs-denote.el ends here
