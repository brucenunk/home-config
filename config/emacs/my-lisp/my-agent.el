;;; my-agent.el --- Agent backend shim -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; Backend-neutral adapter for task agent sessions.
;;
;; Functions:
;;   - my/agent-normalize-backend — normalize backend string
;;   - my/agent-backend-prompt — prompt for backend selection
;;   - my/agent-bootstrap-prompt — render backend-specific task bootstrap text
;;   - my/agent-default-launch-config — return the default backend launch config
;;   - my/agent-backend-options-default — return backend default startup options
;;   - my/agent-backend-options-prompt — prompt for backend-specific startup options
;;   - my/agent-task-buffer-name — canonical task session buffer name
;;   - my/agent-session-live-p — check if an agent session buffer is live
;;   - my/agent-session-resize-to-window — resize a session PTY to its window
;;   - my/agent-run-in-ghostel — run a shell command in a task session Ghostel buffer
;;   - my/agent-session-start — dispatch task session launch to backend module
;;   - my/agent-session-resume-start — dispatch task session resume to backend module

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function ghostel "ghostel" (&optional arg))
(declare-function ghostel-exec "ghostel" (buffer program &optional args))

(defvar ghostel-buffer-name)
(defvar ghostel-kill-buffer-on-exit)
(defvar ghostel-kitty-graphics-storage-limit)
(defvar ghostel-set-title-function)

(defconst my/agent-known-backends '("pi")
  "Backend names supported by the shared agent session code.")

(defcustom my/agent-valid-backends '("pi")
  "Allowed task agent backend names."
  :type '(repeat string)
  :group 'my)

(defcustom my/agent-default-backend "pi"
  "Preferred backend for low-friction task pickup."
  :type 'string
  :group 'my)

(defun my/agent--normalize-string (value)
  "Return normalized lowercase VALUE string, or nil when blank."
  (let* ((raw (and value (format "%s" value)))
         (trimmed (and raw (string-trim raw))))
    (unless (or (null trimmed) (string-empty-p trimmed))
      (downcase trimmed))))

;;;###autoload
(defun my/agent-normalize-backend (backend)
  "Return normalized BACKEND string, or nil when invalid/missing."
  (let ((normalized (my/agent--normalize-string backend)))
    (when (member normalized my/agent-known-backends)
      normalized)))

(defun my/agent--require-backend (backend)
  "Return normalized BACKEND or signal `user-error'."
  (or (my/agent-normalize-backend backend)
      (user-error "Explicit agent backend is required")))

;;;###autoload
(defun my/agent-available-backends ()
  "Return normalized available backend names in configured display order.
When saved customization retains only removed/invalid backends, fall back to the
currently supported backend set instead of hard-failing task pickup."
  (let ((normalized
         (delq nil
               (mapcar #'my/agent-normalize-backend my/agent-valid-backends))))
    (or normalized
        my/agent-known-backends
        (user-error "No valid agent backends are configured"))))

;;;###autoload
(defun my/agent-single-backend ()
  "Return the only configured backend when exactly one is available."
  (let ((backends (my/agent-available-backends)))
    (when (= (length backends) 1)
      (car backends))))

;;;###autoload
(defun my/agent-default-backend-resolve ()
  "Return the configured default backend, falling back to the first available one."
  (let* ((available-backends (my/agent-available-backends))
         (default-backend (my/agent-normalize-backend my/agent-default-backend)))
    (if (member default-backend available-backends)
        default-backend
      (car available-backends))))

;;;###autoload
(defun my/agent-backend-prompt (&optional initial-backend)
  "Prompt for task backend and return normalized backend string.
INITIAL-BACKEND seeds minibuffer default."
  (let ((choice (completing-read "Agent backend: "
                                 (my/agent-available-backends)
                                 nil
                                 t
                                 nil
                                 nil
                                 (my/agent-normalize-backend initial-backend))))
    (my/agent--require-backend choice)))

(declare-function my/agent-pi-bootstrap-prompt "my-agent-pi" (context))
(declare-function my/agent-pi-default-options "my-agent-pi" ())
(declare-function my/agent-pi-prompt-options "my-agent-pi" (&optional initial-options advanced-p))
(declare-function my/agent-pi-session-file "my-agent-pi" (task-id dir))

(defun my/agent--bootstrap-agents-instructions (agents-files)
  "Return AGENTS.md instruction sentence for AGENTS-FILES, or nil."
  (when agents-files
    (format "Read these AGENTS.md files: %s."
            (mapconcat (lambda (path) (format "`%s`" path))
                       agents-files
                       ", "))))

(defun my/agent-format-bootstrap-prompt (context &optional options)
  "Return shared task bootstrap prompt text for CONTEXT plist.
OPTIONS is a plist. Supported keys:
- `:include-explicit-agentsmd-files' — when non-nil or omitted, include
  explicit AGENTS.md file-reading instructions when available."
  (let* ((title (plist-get context :title))
         (task-id (plist-get context :task-id))
         (skill (plist-get context :skill))
         (task-note-content (plist-get context :task-note-content))
         (include-explicit-agentsmd-files
          (if (plist-member options :include-explicit-agentsmd-files)
              (plist-get options :include-explicit-agentsmd-files)
            t))
         (agents-instructions
          (when include-explicit-agentsmd-files
            (my/agent--bootstrap-agents-instructions
             (plist-get context :agents-files))))
         (task-instructions
          (cond
           (skill
            (format "Load the `%s` skill and follow its instructions." skill))
           ((or (null task-note-content)
                (string-empty-p task-note-content))
            "Follow the task note instructions.")))
         (task-note-section
          (when (and task-note-content
                     (not (string-empty-p task-note-content)))
            task-note-content)))
    (string-join
     (delq nil
           (list (format "**Task:** %s" title)
                 agents-instructions
                 (when task-id
                   (format "Task identifier: `%s`." task-id))
                 task-note-section
                 task-instructions))
     "\n\n")))

;;;###autoload
(defun my/agent-bootstrap-prompt (backend context)
  "Return backend-specific task bootstrap prompt for BACKEND and CONTEXT.
CONTEXT is a plist that may include `:title', `:task-id', `:skill',
`:task-note-content', and `:agents-files'."
  (when context
    (let ((normalized (my/agent--require-backend backend)))
      (pcase normalized
        ("pi"
         (require 'my-agent-pi)
         (my/agent-pi-bootstrap-prompt context))
        (_ nil)))))

;;;###autoload
(defun my/agent-default-launch-config ()
  "Return default launch config plist for low-friction task pickup."
  (let ((backend (my/agent-default-backend-resolve)))
    (list :backend backend
          :options (my/agent-backend-options-default backend))))

;;;###autoload
(defun my/agent-backend-options-default (backend)
  "Return normalized default option plist for BACKEND startup."
  (let ((normalized (my/agent--require-backend backend)))
    (pcase normalized
      ("pi"
       (require 'my-agent-pi)
       (my/agent-pi-default-options))
      (_ nil))))

;;;###autoload
(defun my/agent-backend-options-prompt (backend &optional initial-options advanced-p)
  "Prompt for backend-specific startup options for BACKEND.
INITIAL-OPTIONS seeds defaults for prompt fields.
When ADVANCED-P is non-nil, include backend advanced startup controls."
  (let ((normalized (my/agent--require-backend backend)))
    (pcase normalized
      ("pi"
       (require 'my-agent-pi)
       (my/agent-pi-prompt-options initial-options advanced-p))
      (_ nil))))

;;;###autoload
(defun my/agent-task-buffer-name (task-id)
  "Return canonical task session buffer name for TASK-ID."
  (format "agent-task-%s" task-id))

;;;###autoload
(defun my/agent-session-live-p (buffer)
  "Return non-nil when BUFFER is a live agent session.
Buffers without an associated process are treated as non-live sessions."
  (and (buffer-live-p buffer)
       (when-let ((proc (get-buffer-process buffer)))
         (process-live-p proc))))

(defun my/agent--ghostel-title-freeze ()
  "Keep the current Ghostel buffer under its agent-owned buffer name."
  (setq-local ghostel-set-title-function nil)
  (when (boundp 'ghostel--managed-buffer-name)
    (set (make-local-variable 'ghostel--managed-buffer-name)
         (format "my-agent-fixed:%s" (buffer-name)))))

(defun my/agent--ghostel-disable-kitty-graphics ()
  "Disable Kitty graphics in the current Ghostel agent buffer."
  (setq-local ghostel-kitty-graphics-storage-limit 0))

(defun my/agent--ghostel-exec-with-window (buffer program args)
  "Run `ghostel-exec' for BUFFER, giving hidden launches a real window size."
  (if (get-buffer-window buffer t)
      (ghostel-exec buffer program args)
    (save-window-excursion
      (set-window-buffer (selected-window) buffer)
      (ghostel-exec buffer program args))))

;;;###autoload
(defun my/agent-session-resize-to-window (buffer &optional window)
  "Resize BUFFER's session process to WINDOW when possible."
  (when-let* (((buffer-live-p buffer))
              (target-window (or window (get-buffer-window buffer t)))
              ((window-live-p target-window))
              (proc (get-buffer-process buffer))
              ((process-live-p proc)))
    (with-current-buffer buffer
      (let ((width (window-max-chars-per-line target-window))
            (height (with-selected-window target-window
                      (floor (window-screen-lines))))
            (adjust-fn (process-get proc 'adjust-window-size-function)))
        (if (functionp adjust-fn)
            (when-let ((size (funcall adjust-fn proc (list target-window))))
              (set-process-window-size proc (cdr size) (car size)))
          (set-process-window-size proc (max 1 height) (max 1 width)))))))

;;;###autoload
(cl-defun my/agent-run-in-ghostel (buffer-name dir command &key display-fn)
  "Run shell COMMAND in Ghostel BUFFER-NAME rooted at DIR."
  (require 'ghostel)
  (let* ((default-directory (file-name-as-directory dir))
         (effective-display-fn (or display-fn #'pop-to-buffer-same-window))
         (existing-buffer (get-buffer buffer-name)))
    (when-let ((proc (and existing-buffer (get-buffer-process existing-buffer))))
      (when (process-live-p proc)
        (user-error "Buffer %s already has a running process" buffer-name)))
    (if (fboundp 'ghostel-exec)
        (with-current-buffer (get-buffer-create buffer-name)
          (rename-buffer buffer-name t)
          (setq-local default-directory (file-name-as-directory dir))
          (my/agent--ghostel-disable-kitty-graphics)
          (funcall effective-display-fn (current-buffer))
          (let ((ghostel-kill-buffer-on-exit nil)
                (ghostel-kitty-graphics-storage-limit 0))
            (my/agent--ghostel-exec-with-window
             (current-buffer) "/bin/sh" (list "-lc" command)))
          (setq-local ghostel-kill-buffer-on-exit nil)
          (my/agent--ghostel-title-freeze)
          (current-buffer))
      ;; Older Ghostel builds do not expose `ghostel-exec'.  Fall back to
      ;; starting an interactive Ghostel shell and sending the command,
      ;; matching the older terminal-buffer flow closely enough to keep task
      ;; pickup usable.
      (when (and existing-buffer
                 (buffer-live-p existing-buffer))
        (kill-buffer existing-buffer))
      (let (buffer)
        (let ((ghostel-buffer-name buffer-name)
              (ghostel-kill-buffer-on-exit nil)
              (ghostel-kitty-graphics-storage-limit 0)
              (pop-to-buffer-orig (symbol-function 'pop-to-buffer)))
          (cl-letf (((symbol-function 'pop-to-buffer)
                     (lambda (buffer-or-name &optional _action _norecord)
                       (let ((display-buffer (get-buffer-create buffer-or-name)))
                         (cl-letf (((symbol-function 'pop-to-buffer)
                                    pop-to-buffer-orig))
                           (funcall effective-display-fn display-buffer))
                         (set-buffer display-buffer)
                         display-buffer))))
            (ghostel nil)
            (setq buffer (current-buffer))))
        (with-current-buffer buffer
          (rename-buffer buffer-name t)
          (setq-local default-directory (file-name-as-directory dir)
                      ghostel-kill-buffer-on-exit nil)
          (my/agent--ghostel-disable-kitty-graphics)
          (my/agent--ghostel-title-freeze)
          (when-let ((proc (get-buffer-process (current-buffer))))
            (process-send-string proc command)
            (process-send-string proc "\n"))
          buffer)))))

(declare-function my/agent-pi-session-start "my-agent-pi"
                  (buffer-name dir task-id &rest args))
(declare-function my/agent-pi-session-resume-start "my-agent-pi"
                  (buffer-name dir session-id &rest args))

;;;###autoload
(cl-defun my/agent-session-start (backend buffer-name dir &key display-fn options bootstrap-prompt task-id session-id session-name)
  "Start BACKEND task session in DIR and return session buffer.
BUFFER-NAME is used for the task session buffer.
DISPLAY-FN controls window display behavior.
OPTIONS is backend option plist.
BOOTSTRAP-PROMPT is sent/queued as initial task prompt.
TASK-ID identifies the task when the backend needs task-associated startup state.
SESSION-ID is an explicit fresh-session identifier when the backend needs one.
SESSION-NAME is backend startup metadata when supported."
  (let ((normalized (my/agent--require-backend backend)))
    (message "Starting %s session" normalized)
    (pcase normalized
      ("pi"
       (require 'my-agent-pi)
       (my/agent-pi-session-start buffer-name
                                  dir
                                  task-id
                                  :display-fn display-fn
                                  :options options
                                  :bootstrap-prompt bootstrap-prompt
                                  :session-id session-id
                                  :session-name session-name))
      (_
       (user-error "Unsupported agent backend: %s" backend)))))

;;;###autoload
(cl-defun my/agent-session-resume-start (backend session-id buffer-name dir
                                                 &key display-fn options bootstrap-prompt session-name)
  "Resume BACKEND task session SESSION-ID in DIR and return session buffer.
BUFFER-NAME is used for the task session buffer.
DISPLAY-FN controls window display behavior.
OPTIONS is backend option plist.
BOOTSTRAP-PROMPT is sent/queued as the resumed session prompt.
SESSION-NAME is backend startup metadata when supported."
  (let ((normalized (my/agent--require-backend backend)))
    (message "Resuming %s session" normalized)
    (pcase normalized
      ("pi"
       (require 'my-agent-pi)
       (my/agent-pi-session-resume-start buffer-name
                                         dir
                                         session-id
                                         :display-fn display-fn
                                         :options options
                                         :bootstrap-prompt bootstrap-prompt
                                         :session-name session-name))
      (_
       (user-error "Unsupported agent backend: %s" backend)))))

(provide 'my-agent)
;;; my-agent.el ends here
