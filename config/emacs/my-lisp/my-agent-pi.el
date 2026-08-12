;;; my-agent-pi.el --- Pi backend adapter -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; Pi-specific backend implementation for task sessions.
;;
;; Functions:
;;   - my/agent-pi-bootstrap-prompt — render Pi task bootstrap prompt
;;   - my/agent-pi-default-options — return default startup options for Pi
;;   - my/agent-pi-prompt-options — prompt for Pi startup options
;;   - my/agent-pi-session-file — choose a fresh explicit Pi session path for launch
;;   - my/agent-pi-session-file-for-timestamp — reconstruct Pi session path from task/worktree/compact token
;;   - my/agent-pi-session-subdirectory — return Pi's task session storage subdirectory for a worktree
;;   - my/agent-pi-session-timestamp — extract persisted compact Pi session token from a session file path
;;   - my/agent-pi-session-timestamp-p — validate persisted compact Pi session tokens
;;   - my/agent-pi-session-timestamp-normalize — canonicalize persisted Pi session tokens
;;   - my/agent-pi-session-resolve — resolve persisted compact Pi session metadata to an explicit session path
;;   - my/agent-pi-session-start — launch Pi task session
;;   - my/agent-pi-session-resume-start — resume Pi task session

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'my-agent)
(require 'subr-x)

(defcustom my/agent-pi-valid-models nil
  "Allowed Pi model values exposed by the Emacs prompt flow."
  :type '(repeat string)
  :group 'my)

(defcustom my/agent-pi-valid-thinking-levels
  '("off" "minimal" "low" "medium" "high" "xhigh")
  "Allowed Pi thinking levels."
  :type '(repeat string)
  :group 'my)

(defcustom my/agent-pi-default-model nil
  "Default Pi model used for task pickup."
  :type '(choice (const :tag "Use Pi default" nil) string)
  :group 'my)

(defcustom my/agent-pi-default-thinking "medium"
  "Default Pi thinking level used for task pickup."
  :type 'string
  :group 'my)

(defcustom my/agent-pi-session-directory
  (expand-file-name "~/.pi/agent/sessions/")
  "Base directory used for Pi's default session storage."
  :type 'directory
  :group 'my)

(defcustom my/agent-pi-model-routes nil
  "Alist mapping prompt model names to provider-qualified Pi model references."
  :type '(alist :key-type string :value-type string)
  :group 'my)

(defcustom my/agent-pi-minimal-thinking-unsupported-models nil
  "Models for which Pi should map the `minimal' thinking level to `low'."
  :type '(repeat string)
  :group 'my)

(defun my/agent-pi--cli-model (model)
  "Return the Pi CLI model reference for MODEL."
  (or (and (stringp model)
           (alist-get model my/agent-pi-model-routes nil nil #'string=))
      model))

(defun my/agent-pi--cli-thinking (model thinking)
  "Return CLI THINKING for MODEL.
Models listed in `my/agent-pi-minimal-thinking-unsupported-models' map the
`minimal' level to `low'."
  (if (and (member model my/agent-pi-minimal-thinking-unsupported-models)
           (equal thinking "minimal"))
      "low"
    thinking))

;;;###autoload
(defun my/agent-pi-bootstrap-prompt (context)
  "Return Pi task bootstrap prompt for CONTEXT plist."
  (my/agent-format-bootstrap-prompt
   context
   '(:include-explicit-agentsmd-files nil)))

(defun my/agent-pi--ordered-completion-table (candidates)
  "Return completion table for CANDIDATES that preserves display order."
  (lambda (string pred action)
    (if (eq action 'metadata)
        '(metadata (display-sort-function . identity)
                   (cycle-sort-function . identity))
      (complete-with-action action candidates string pred))))

(defun my/agent-pi--normalize-option (value)
  "Return VALUE as trimmed string, or nil when blank."
  (let* ((raw (and value (format "%s" value)))
         (trimmed (and raw (string-trim raw))))
    (unless (or (null trimmed) (string-empty-p trimmed))
      trimmed)))

(defun my/agent-pi--normalize-model (model)
  "Return normalized MODEL string for Pi, or nil when invalid."
  (let ((normalized (my/agent-pi--normalize-option model)))
    (if (member normalized my/agent-pi-valid-models)
        normalized
      (when normalized
        (message "Ignoring invalid Pi model \"%s\"" model))
      nil)))

(defun my/agent-pi--normalize-thinking (thinking)
  "Return normalized THINKING string for Pi, or nil when invalid."
  (let ((normalized (and thinking (downcase (string-trim thinking)))))
    (if (member normalized my/agent-pi-valid-thinking-levels)
        normalized
      (when normalized
        (message "Ignoring invalid Pi thinking level \"%s\"" thinking))
      nil)))

(defun my/agent-pi--resolve-options (options)
  "Return normalized Pi OPTIONS plist."
  (let* ((model (my/agent-pi--normalize-model
                 (or (plist-get options :model)
                     my/agent-pi-default-model)))
         (thinking (my/agent-pi--normalize-thinking
                    (my/agent-pi--normalize-option
                     (or (plist-get options :thinking)
                         my/agent-pi-default-thinking)))))
    (list :model model :thinking thinking)))

;;;###autoload
(defun my/agent-pi-default-options ()
  "Return default startup options plist for Pi sessions."
  (my/agent-pi--resolve-options nil))

;;;###autoload
(defun my/agent-pi-prompt-options (&optional initial-options advanced-p)
  "Prompt for Pi startup options and return option plist.
INITIAL-OPTIONS may include :model and :thinking defaults. When
ADVANCED-P is non-nil, prompt for explicit model/thinking overrides;
otherwise return normalized defaults."
  (let* ((resolved-options (my/agent-pi--resolve-options initial-options))
         (initial-model (plist-get resolved-options :model))
         (initial-thinking (plist-get resolved-options :thinking)))
    (if advanced-p
        (let* ((model-choice (completing-read "Pi model (advanced): "
                                              (my/agent-pi--ordered-completion-table
                                               (append my/agent-pi-valid-models '("none")))
                                              nil
                                              t
                                              nil
                                              nil
                                              (or initial-model "none")))
               (model (if (string= model-choice "none")
                          nil
                        (my/agent-pi--normalize-model model-choice)))
               (thinking-choice
                (completing-read "Pi thinking (advanced): "
                                 (my/agent-pi--ordered-completion-table
                                  (append my/agent-pi-valid-thinking-levels '("none")))
                                 nil
                                 t
                                 nil
                                 nil
                                 (or initial-thinking "none")))
               (thinking (if (string= thinking-choice "none")
                             nil
                           (my/agent-pi--normalize-thinking thinking-choice))))
          (list :model model :thinking thinking))
      resolved-options)))

(defconst my/agent-pi-session-filename-timestamp-regexp
  "[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T[0-9]\\{2\\}-[0-9]\\{2\\}-[0-9]\\{2\\}-[0-9]\\{3\\}Z"
  "Regexp matching Pi's on-disk dashed session filename timestamps.")

(defconst my/agent-pi-session-timestamp-regexp
  "[0-9]\\{8\\}T[0-9]\\{9\\}Z"
  "Regexp matching persisted compact exact Pi session tokens.")

(defun my/agent-pi--session-filename-timestamp-to-token (timestamp)
  "Return compact exact persisted token for dashed Pi file TIMESTAMP."
  (when (and (stringp timestamp)
             (string-match
              "\\`\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)T\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{3\\}\\)Z\\'"
              timestamp))
    (concat (match-string 1 timestamp)
            (match-string 2 timestamp)
            (match-string 3 timestamp)
            "T"
            (match-string 4 timestamp)
            (match-string 5 timestamp)
            (match-string 6 timestamp)
            (match-string 7 timestamp)
            "Z")))

(defun my/agent-pi--session-token-to-filename-timestamp (timestamp)
  "Return dashed Pi filename timestamp for compact exact persisted TIMESTAMP."
  (when (and (stringp timestamp)
             (string-match
              "\\`\\([0-9]\\{4\\}\\)\\([0-9]\\{2\\}\\)\\([0-9]\\{2\\}\\)T\\([0-9]\\{2\\}\\)\\([0-9]\\{2\\}\\)\\([0-9]\\{2\\}\\)\\([0-9]\\{3\\}\\)Z\\'"
              timestamp))
    (format "%s-%s-%sT%s-%s-%s-%sZ"
            (match-string 1 timestamp)
            (match-string 2 timestamp)
            (match-string 3 timestamp)
            (match-string 4 timestamp)
            (match-string 5 timestamp)
            (match-string 6 timestamp)
            (match-string 7 timestamp))))

(defun my/agent-pi--session-grouping-directory (dir)
  "Return the Pi task session grouping directory for DIR.
Managed worktree roots under `~/work/{owner}/{repo}/{worktree}' are grouped
by their repo directory `~/work/{owner}/{repo}' so `pi -r' from the repo can
browse task sessions across reusable worktree slots. Other paths keep Pi's
normal per-working-directory grouping."
  (let* ((work-root (file-name-as-directory (expand-file-name "~/work/")))
         (expanded (directory-file-name (expand-file-name dir))))
    (if (string-prefix-p work-root expanded)
        (let* ((relative (string-remove-prefix work-root expanded))
               (parts (split-string relative "/" t)))
          (if (= (length parts) 3)
              (expand-file-name (format "%s/%s" (nth 0 parts) (nth 1 parts))
                                work-root)
            expanded))
      expanded)))

(defun my/agent-pi--default-session-subdirectory (dir)
  "Return Pi's task session storage subdirectory for DIR."
  (let* ((grouping-dir (my/agent-pi--session-grouping-directory dir))
         (trimmed (string-remove-prefix "/" grouping-dir))
         (encoded (string-replace "/" "-" trimmed)))
    (expand-file-name (format "--%s--/" encoded)
                      my/agent-pi-session-directory)))

;;;###autoload
(defun my/agent-pi-session-subdirectory (dir)
  "Return Pi's task session storage subdirectory for worktree DIR."
  (my/agent-pi--default-session-subdirectory dir))

(defun my/agent-pi--fresh-session-filename (task-id)
  "Return unique fresh-session filename for TASK-ID."
  (let ((timestamp (format-time-string "%Y%m%dT%H%M%S%3NZ" (current-time) t)))
    (format "%s_%s.jsonl"
            (my/agent-pi--session-token-to-filename-timestamp timestamp)
            task-id)))

;;;###autoload
(defun my/agent-pi-session-timestamp-p (timestamp)
  "Return non-nil when TIMESTAMP is a valid compact exact Pi session token."
  (and (stringp timestamp)
       (string-match-p (format "\\`%s\\'" my/agent-pi-session-timestamp-regexp)
                       timestamp)))

;;;###autoload
(defun my/agent-pi-session-timestamp-normalize (timestamp)
  "Return canonical compact exact Pi session token for TIMESTAMP, or nil.
Accept both the new compact persisted form and Pi's dashed on-disk filename
format so callers can normalize legacy timestamp-only metadata during
migration."
  (let ((normalized (my/agent-pi--normalize-option timestamp)))
    (cond
     ((my/agent-pi-session-timestamp-p normalized)
      normalized)
     ((and normalized
           (string-match-p
            (format "\\`%s\\'" my/agent-pi-session-filename-timestamp-regexp)
            normalized))
      (my/agent-pi--session-filename-timestamp-to-token normalized)))))

;;;###autoload
(defun my/agent-pi-session-file-for-timestamp (task-id dir timestamp)
  "Return deterministic Pi session file path for TASK-ID in DIR at TIMESTAMP.
TIMESTAMP is the persisted compact exact token stored in task-note metadata.
Managed worktree DIR values are stored under their repo-level Pi session
bucket, while the running Pi process and session header still use DIR as cwd."
  (let ((normalized (my/agent-pi-session-timestamp-normalize timestamp)))
    (unless normalized
      (user-error "Invalid Pi session timestamp %S" timestamp))
    (expand-file-name
     (format "%s_%s.jsonl"
             (my/agent-pi--session-token-to-filename-timestamp normalized)
             task-id)
     (my/agent-pi--default-session-subdirectory dir))))

;;;###autoload
(defun my/agent-pi-session-timestamp (session-file)
  "Return persisted compact exact Pi session token extracted from SESSION-FILE, or nil."
  (when-let* ((session-file (and session-file
                                 (string-trim (format "%s" session-file))))
              ((string-match (format "/\\(%s\\)_[0-9]\\{8\\}T[0-9]\\{6\\}\\.jsonl\\'"
                                     my/agent-pi-session-filename-timestamp-regexp)
                             session-file)))
    (my/agent-pi--session-filename-timestamp-to-token (match-string 1 session-file))))

;;;###autoload
(defun my/agent-pi-session-file (task-id dir)
  "Return a fresh explicit Pi session file path for TASK-ID in DIR.
For managed worktree DIR values, the file lives under the repo-level Pi session
bucket so Pi's own resume UI can browse task sessions across reusable worktree
slots. Callers should compute this once per fresh launch and thread the result
through both process startup and compact exact task-note token persistence."
  (my/agent-pi-session-file-for-timestamp
   task-id
   dir
   (format-time-string "%Y%m%dT%H%M%S%3NZ" (current-time) t)))

;;;###autoload
(defun my/agent-pi-session-resolve (task-id dir &optional session-id)
  "Return explicit Pi resume metadata plist for TASK-ID in DIR.
SESSION-ID is the compact exact token stored as `session: pi:TIMESTAMP'.
Return nil when SESSION-ID is nil. Signal `user-error' when a non-empty token
cannot be normalized exactly."
  (let ((raw-session-id (my/agent-pi--normalize-option session-id)))
    (when raw-session-id
      (let ((timestamp (my/agent-pi-session-timestamp-normalize raw-session-id)))
        (unless timestamp
          (user-error "Invalid Pi session timestamp %S" session-id))
        (list :id (my/agent-pi-session-file-for-timestamp task-id dir timestamp))))))

(defun my/agent-pi--base-argv (dir options &optional session-file session-name)
  "Build the base Pi argv list from DIR, OPTIONS, SESSION-FILE, and SESSION-NAME.
SESSION-NAME is passed via Pi's native `--name' startup option when non-empty."
  (let* ((resolved-options (my/agent-pi--resolve-options options))
         (model (plist-get resolved-options :model))
         (thinking (my/agent-pi--cli-thinking model
                                              (plist-get resolved-options :thinking)))
         (normalized-session-name (my/agent-pi--normalize-option session-name))
         (args '("pi")))
    (when model
      (setq args (append args (list "--model" (my/agent-pi--cli-model model)))))
    (when thinking
      (setq args (append args (list "--thinking" thinking))))
    (when session-file
      (make-directory (file-name-directory session-file) t)
      (setq args (append args (list "--session" session-file))))
    (when normalized-session-name
      (setq args (append args (list "--name" normalized-session-name))))
    args))

(defun my/agent-pi--command-argv (dir options session-file &optional prompt session-name)
  "Build Pi argv list from DIR, OPTIONS, SESSION-FILE, PROMPT, and SESSION-NAME."
  (let ((args (my/agent-pi--base-argv dir
                                      options
                                      session-file
                                      session-name)))
    (when (and prompt (not (string-empty-p prompt)))
      (setq args (append args (list prompt))))
    args))

(defun my/agent-pi--session-file-named-p (session-file)
  "Return non-nil when SESSION-FILE already has a non-empty session name."
  (when (and session-file (file-readable-p session-file))
    (with-temp-buffer
      (insert-file-contents session-file)
      (let (named)
        (while (and (not named) (not (eobp)))
          (let ((line (string-trim (buffer-substring-no-properties
                                    (line-beginning-position)
                                    (line-end-position)))))
            (when (not (string-empty-p line))
              (ignore-errors
                (let ((entry (json-parse-string line
                                                :object-type 'alist
                                                :array-type 'list)))
                  (when (and (equal (alist-get 'type entry) "session_info")
                             (my/agent-pi--normalize-option
                              (alist-get 'name entry)))
                    (setq named t))))))
          (forward-line 1))
        named))))

(defun my/agent-pi--resume-argv (dir session-id options &optional prompt session-name)
  "Build Pi resume argv list for DIR, SESSION-ID, OPTIONS, PROMPT, and SESSION-NAME.
SESSION-NAME is only forwarded for unnamed or missing session files, preserving
user-renamed sessions on resume."
  (let* ((resume-session-name (unless (my/agent-pi--session-file-named-p session-id)
                                session-name))
         (args (my/agent-pi--base-argv dir options session-id resume-session-name)))
    (when (and prompt (not (string-empty-p prompt)))
      (setq args (append args (list prompt))))
    args))

(defun my/agent-pi--shell-command (argv)
  "Return shell command string that execs ARGV."
  (string-join (cons "exec" (mapcar #'shell-quote-argument argv)) " "))

(cl-defun my/agent-pi--run (buffer-name dir argv &key display-fn)
  "Start ARGV in BUFFER-NAME at DIR and return the session buffer."
  (my/agent-run-in-ghostel buffer-name
                           dir
                           (my/agent-pi--shell-command argv)
                           :display-fn display-fn))

;;;###autoload
(cl-defun my/agent-pi-session-start (buffer-name dir task-id
                                                 &key display-fn options bootstrap-prompt session-id session-name)
  "Start Pi task session BUFFER-NAME in DIR for TASK-ID.
DISPLAY-FN controls buffer display behavior.
OPTIONS may include pickup-selected :model and :thinking.
BOOTSTRAP-PROMPT is passed as Pi's initial prompt.
SESSION-ID is the explicit session file chosen for this fresh launch.
SESSION-NAME is forwarded to Pi's native startup name option."
  (my/agent-pi--run buffer-name
                    dir
                    (my/agent-pi--command-argv dir
                                               options
                                               (or session-id
                                                   (my/agent-pi-session-file task-id dir))
                                               bootstrap-prompt
                                               session-name)
                    :display-fn display-fn))

;;;###autoload
(cl-defun my/agent-pi-session-resume-start (buffer-name dir session-id
                                                        &key display-fn options bootstrap-prompt session-name)
  "Resume Pi task session SESSION-ID in DIR and return the session buffer.
DISPLAY-FN controls buffer display behavior.
OPTIONS may include pickup-selected :model and :thinking.
BOOTSTRAP-PROMPT is passed as the first resumed-session prompt.
SESSION-NAME is forwarded to Pi's native startup name option."
  (my/agent-pi--run buffer-name
                    dir
                    (my/agent-pi--resume-argv dir session-id options bootstrap-prompt session-name)
                    :display-fn display-fn))

(provide 'my-agent-pi)
;;; my-agent-pi.el ends here
