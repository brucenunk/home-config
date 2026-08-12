;;; my-emacs-denote.el --- Denote task management configuration -*- lexical-binding: t -*-

;;; Commentary:

;; Denote configuration for task management (Mission Control Task Queue).

;;; Code:

(declare-function my/task-file-p "my-task" ())
(defvar my/tasks-map)

(defcustom my/task-auto-revert-debounce-interval 0.3
  "Seconds to wait before reverting a task file after a change notification.
Lower values make reverts more responsive; higher values coalesce more
edits into a single revert.  The default (0.3s) balances responsiveness
with avoiding redundant reverts during rapid agent edits."
  :type 'number
  :group 'my-task)

(defvar-local my/task-auto-revert-debounce-timer nil
  "Debounce timer for task file auto-revert notifications.")

(use-package denote
  :ensure nil
  :demand t
  :hook ((dired-mode    . denote-dired-mode-in-directories)
         (markdown-mode . denote-fontify-links-mode-maybe))
  :bind (("C-c n n" . denote)
         ("C-c n r" . denote-rename-file)
         ("C-c n l" . denote-link)
         ("C-c n b" . denote-backlinks))
  :config
  (require 'my-task)
  (let ((task-workflow-v3-template
         "## Dependencies\n\n-\n\n## Context\n\nInitial thoughts, background, and links for future pickup.\n\n## Goals\n\n- \n\n## Non-Goals\n\n- \n\n## Constraints\n\n- Durable constraints, locked details, or invariants that should survive session handoff.\n"))
    (setq denote-templates
          `((task-workflow-v3 . ,task-workflow-v3-template)
            (task . ,task-workflow-v3-template)
            (empty . ""))))
  (setq denote-directory (expand-file-name "~/work/tasks/"))
  (setq denote-dired-directories (list denote-directory))
  (setq denote-dired-directories-include-subdirectories t)
  (setq denote-known-keywords nil)
  (setq denote-file-type 'markdown-yaml)
  (setq denote-rename-confirmations nil)
  (defun my/task-auto-revert-enable-after-save ()
    "Enable task auto-revert after a newly created task file is first saved."
    (remove-hook 'after-save-hook #'my/task-auto-revert-enable-after-save t)
    (my/task-auto-revert-enable-maybe))
  (defun my/task-auto-revert-enable-maybe ()
    "Enable auto-revert for existing task files.
New Denote notes visit their target path before the file exists, so defer
until the first save to avoid reverting a not-yet-created task file."
    (when (my/task-file-p)
      (if (and buffer-file-name
               (file-exists-p buffer-file-name))
          (progn
            (auto-revert-mode 1)
            (setq-local auto-revert-verbose nil))
        (add-hook 'after-save-hook #'my/task-auto-revert-enable-after-save nil t))))
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
Resolves relative task links against the shared Denote task root."
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

;; Tasks keymap (C-c t)
(require 'my-task)
(keymap-global-set "C-c t" my/tasks-map)

(add-hook 'find-file-hook #'my/task-auto-revert-enable-maybe)

(with-eval-after-load 'autorevert
  (defun my/task-auto-revert--cancel-debounce ()
    "Cancel pending debounce timer in current buffer."
    (when (timerp my/task-auto-revert-debounce-timer)
      (cancel-timer my/task-auto-revert-debounce-timer)
      (setq my/task-auto-revert-debounce-timer nil)))

  (defun my/task-auto-revert-suppress-redisplay (orig-fn &rest args)
    "Inhibit redisplay during auto-revert for task files.
Prevents flash of unstyled content by suppressing intermediate
redisplay, then pre-fontifies visible windows before resuming."
    (if (not (my/task-file-p))
        (apply orig-fn args)
      (let ((inhibit-redisplay t))
        (apply orig-fn args)
        (dolist (win (get-buffer-window-list (current-buffer) nil t))
          (font-lock-ensure (window-start win) (window-end win t))))))

  (defun my/task-auto-revert-debounce-notify (orig-fn event)
    "Debounce auto-revert notifications for task files.
Uses `my/task-auto-revert-debounce-interval' instead of the default
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
              (not (with-current-buffer buffer (my/task-file-p))))
          ;; Non-debounce path: delegate to default handler.
          ;; Cancel any pending debounce on stopped to avoid stale timer.
          (progn
            (when (and (eq action 'stopped)
                       (buffer-live-p buffer))
              (with-current-buffer buffer
                (my/task-auto-revert--cancel-debounce)))
            (funcall orig-fn event))
        ;; Task file content-change: debounce with short timer
        (with-current-buffer buffer
          (setq auto-revert-notify-modified-p t)
          (my/task-auto-revert--cancel-debounce)
          (setq my/task-auto-revert-debounce-timer
                (run-with-timer
                 my/task-auto-revert-debounce-interval nil
                 (lambda (buf)
                   (when (buffer-live-p buf)
                     (with-current-buffer buf
                       (setq my/task-auto-revert-debounce-timer nil)
                       (when (bound-and-true-p auto-revert-mode)
                         (auto-revert-handler)))))
                 buffer))
          ;; Clean up timer if buffer is killed before it fires
          (add-hook 'kill-buffer-hook #'my/task-auto-revert--cancel-debounce nil t)))))

  (advice-add 'auto-revert-handler :around
              #'my/task-auto-revert-suppress-redisplay)
  (advice-add 'auto-revert-notify-handler :around
              #'my/task-auto-revert-debounce-notify))

(provide 'my-emacs-denote)
;;; my-emacs-denote.el ends here
