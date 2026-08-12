;;; my-task-note.el --- Task note and front-matter access -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (denote "3.0"))

;;; Commentary:

;; Explicit task-note IO helpers and note-derived accessors.
;;
;; Public functions:
;;   - my/task-note-todo-add — create a new todo task note
;;   - my/task-note-todo-list — list all todo task note paths
;;   - my/task-note-todo-summary — return total todo task count
;;   - my/task-note-file — resolve a task-id to the current task note path
;;   - my/task-note-owner-repo — read owner/repo from task note metadata
;;   - my/task-note-repo — read repo from task note metadata
;;   - my/task-note-owner — read owner from task note metadata
;;   - my/task-note-status — read task status from the note filename
;;   - my/task-note-skill — read configured task skill from front matter
;;   - my/task-note-session-get — read persisted backend-tagged session metadata
;;   - my/task-note-session-format — encode backend-tagged session metadata
;;   - my/task-note-session-parse — parse backend-tagged session metadata
;;   - my/task-note-session-set — persist backend-tagged session metadata
;;   - my/task-note-worktree-get — read persisted task worktree suffix
;;   - my/task-note-worktree-set — persist task worktree suffix
;;   - my/task-note-session-persist-state — persist session metadata plus worktree
;;   - my/task-note-session-register-backend-session — persist backend session metadata
;;   - my/task-note-session-clear — clear persisted session metadata
;;   - my/task-note-content — read note body without YAML front matter
;;   - my/task-note-title — read note title
;;   - my/task-note-mark-done — rename a task note to done
;;   - my/task-note-mark-todo — rename a task note to todo
;;   - my/task-note-mark-discarded — rename a task note to discarded
;;
;; Internal helpers intentionally keep note-specific names and behavior local
;; to this module so call sites can choose note IO explicitly instead of
;; depending on `my-task.el` as a broad mixed facade.

;;; Code:

(require 'cl-lib)
(require 'denote)
(require 'my-agent)
(require 'my-agent-pi)
(require 'my-repo)
(require 'subr-x)

(declare-function my/task-file "my-task" (task-id))
(declare-function my/task--get-file "my-task" (task-id))
(declare-function my/task-owner-repo "my-task" (task))
(declare-function my/task-session-clear "my-task" (task))
(declare-function my/task-session-get "my-task" (task))
(declare-function my/task-session-set "my-task" (task value))
(declare-function my/task-skill "my-task" (task))
(declare-function my/task-status "my-task" (task))
(declare-function my/task-title "my-task" (task))
(declare-function my/task-todo-list "my-task" ())
(declare-function my/task-state-notify "my-task" (task-id source &rest props))

(defvar my/task-statuses '("todo" "done" "discarded")
  "Valid task note statuses.")

(defvar my/task-workflows '("task" "bump-nix" "none")
  "Workflow choices for task creation.
`task' is the structured default, named workflows map to autonomous
agent workflows, and `none' creates an unscripted task.")

(defvar my/task--file-cache (make-hash-table :test 'equal)
  "Cache of resolved task note paths keyed by task id.")

(defvar my/task--todo-summary-count nil
  "Cached total todo note count for the current Denote root.")

(defvar my/task--todo-summary-directory nil
  "Expanded Denote root used for `my/task--todo-summary-count'.")

(defvar my/task--todo-summary-dirty t
  "Non-nil when `my/task--todo-summary-count' should be rescanned.")

(defun my/task--todo-summary-root ()
  "Return expanded Denote root for todo summary caching, or nil."
  (when denote-directory
    (expand-file-name denote-directory)))

(defun my/task--todo-summary-invalidate ()
  "Mark the cached todo summary dirty."
  (setq my/task--todo-summary-dirty t))

(defun my/task--todo-summary-snapshot ()
  "Return cached total todo note count for the current Denote root."
  (let ((root (my/task--todo-summary-root)))
    (when (or my/task--todo-summary-dirty
              (null my/task--todo-summary-count)
              (not (equal my/task--todo-summary-directory root)))
      (setq my/task--todo-summary-count (length (my/task-todo-list))
            my/task--todo-summary-directory root
            my/task--todo-summary-dirty nil))
    my/task--todo-summary-count))

(defun my/task--notify-note-status-change (file status)
  "Broadcast note STATUS change for Denote task FILE."
  (when-let ((task-id (denote-retrieve-filename-identifier file)))
    (puthash task-id file my/task--file-cache)
    (my/task--todo-summary-invalidate)
    (my/task-state-notify task-id 'task-note
                          :changes '(:status)
                          :status status
                          :revert-buffers t
                          :file file)))

(defun my/task-autonomous-workflows ()
  "Return workflows other than the default structured task."
  (cl-remove-if (lambda (workflow)
                  (member workflow '("task" "none")))
                my/task-workflows))

(defun my/task--normalize-workflow (workflow)
  "Return canonical workflow label for WORKFLOW."
  (pcase workflow
    ((or `nil "none") "none")
    ("task-workflow-v3" "task")
    (_ workflow)))

(defun my/task--workflow-front-matter-skill (workflow)
  "Return front-matter `skill' value for WORKFLOW."
  (pcase (my/task--normalize-workflow workflow)
    ("task" "task-workflow-v3")
    ("none" nil)
    (_ workflow)))

(defun my/task--workflow-template (workflow)
  "Return Denote template symbol for WORKFLOW."
  (if (equal (my/task--normalize-workflow workflow) "task")
      'task-workflow-v3
    'empty))

(defun my/task--read-workflow (&optional extended-p)
  "Return the interactive workflow choice.
Without EXTENDED-P, default to the standard structured `task'
workflow. With EXTENDED-P, prompt for the full workflow list."
  (if extended-p
      (let ((choice (completing-read "Workflow: "
                                     (append '("task")
                                             (my/task-autonomous-workflows)
                                             '("none"))
                                     nil t nil nil "task")))
        (my/task--normalize-workflow choice))
    "task"))

(defun my/task--front-matter-bounds ()
  "Return (START . END) of YAML front matter in current buffer, or nil."
  (save-excursion
    (goto-char (point-min))
    (when (looking-at "^---\n")
      (forward-line)
      (let ((start (point)))
        (when (re-search-forward "^---\n" nil t)
          (cons start (match-beginning 0)))))))

(defun my/task--front-matter-get (field)
  "Return value of FIELD from YAML front matter in current buffer, or nil."
  (when-let* ((bounds (my/task--front-matter-bounds))
              (start (car bounds))
              (end (cdr bounds)))
    (save-excursion
      (goto-char start)
      (when (re-search-forward
             (format "^%s:\\s-*\\(.*\\)$" (regexp-quote field))
             end t)
        (let ((value (string-trim (match-string 1))))
          (when (and (>= (length value) 2)
                     (or (and (eq (aref value 0) ?\")
                              (eq (aref value (1- (length value))) ?\"))
                         (and (eq (aref value 0) ?')
                              (eq (aref value (1- (length value))) ?'))))
            (setq value (substring value 1 -1)))
          (unless (string-empty-p value)
            value))))))

(defun my/task--front-matter-set (field value)
  "Set FIELD to VALUE in YAML front matter in current buffer."
  (when-let* ((bounds (my/task--front-matter-bounds))
              (start (car bounds))
              (end (cdr bounds)))
    (save-excursion
      (goto-char start)
      (let* ((re (format "^%s:.*$" (regexp-quote field)))
             (text (and value (string-trim (format "%s" value))))
             (remove-p (or (null value)
                           (null text)
                           (string-empty-p text))))
        (if (re-search-forward re end t)
            (if remove-p
                (progn
                  (beginning-of-line)
                  (let ((line-start (point)))
                    (forward-line 1)
                    (delete-region line-start (point))))
              (replace-match (format "%s:        %s" field text) t t))
          (unless remove-p
            (goto-char end)
            (insert (format "%s:        %s\n" field text))))))))

(defun my/task--front-matter-get-from-file (file field)
  "Return value of FIELD from FILE's YAML front matter, or nil."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (my/task--front-matter-get field))))

(defun my/task--front-matter-update-file (file updater)
  "Open FILE, run UPDATER in its buffer, save, and return FILE."
  (let* ((existing-buffer (find-buffer-visiting file))
         (buffer (or existing-buffer
                     (find-file-noselect file))))
    (unwind-protect
        (with-current-buffer buffer
          (funcall updater)
          (save-buffer)
          file)
      (when (and (null existing-buffer)
                 (buffer-live-p buffer))
        (kill-buffer buffer)))))

(defun my/task--repo-slug (owner repo)
  "Return normalized OWNER/REPO slug, or nil when incomplete."
  (when (and (stringp owner)
             (stringp repo)
             (not (string-empty-p owner))
             (not (string-empty-p repo)))
    (format "%s/%s" owner repo)))

(defun my/task--split-repo-slug (repo-slug)
  "Return (OWNER . REPO) parsed from REPO-SLUG, or nil."
  (when (and (stringp repo-slug)
             (string-match "\\`\\([^/]+\\)/\\([^/]+\\)\\'" repo-slug))
    (cons (match-string 1 repo-slug)
          (match-string 2 repo-slug))))

(defun my/task--task-directories ()
  "Return the shared task root when it exists."
  (let ((tasks-dir (expand-file-name "~/work/tasks/")))
    (when (file-directory-p tasks-dir)
      (list tasks-dir))))

(defun my/task--find-file-in-task-directories (task-id)
  "Return task file for TASK-ID by scanning the shared task root.
This bounded fallback only runs when scope-local Denote lookup misses."
  (catch 'match
    (dolist (tasks-dir (my/task--task-directories))
      (when-let ((match (car (directory-files-recursively
                              tasks-dir
                              (format "\\`%s==.*" (regexp-quote task-id))
                              nil nil))))
        (throw 'match match)))))

(defun my/task--cache-file-get (task-id)
  "Return cached task note path for TASK-ID when it still exists."
  (when-let ((cached (gethash task-id my/task--file-cache)))
    (if (file-exists-p cached)
        cached
      (remhash task-id my/task--file-cache)
      nil)))

(defun my/task--cache-file-put (task-id file)
  "Cache FILE for TASK-ID and return FILE."
  (when (and task-id file)
    (puthash task-id file my/task--file-cache))
  file)

(defun my/task-note--resolve-id (task)
  "Resolve TASK to a task id string when possible."
  (cond
   ((null task) nil)
   ((and (stringp task)
         (string-match-p "\\`[0-9]\\{8\\}T[0-9]\\{6\\}\\'" task))
    task)
   ((stringp task)
    (denote-retrieve-filename-identifier task))))

(defun my/task-note--compat-override-p (legacy explicit)
  "Return non-nil when LEGACY is overridden independently of EXPLICIT."
  (and (fboundp legacy)
       (not (eq (indirect-function legacy)
                (indirect-function explicit)))))

(defun my/task-note--resolve-to-file (task)
  "Resolve TASK to a task note file path."
  (cond
   ((null task) nil)
   ((and (stringp task)
         (string-match-p "\\`[0-9]\\{8\\}T[0-9]\\{6\\}\\'" task))
    (if (fboundp 'my/task-file)
        (my/task-file task)
      (my/task-note-file task)))
   ((stringp task)
    task)))

(defun my/task-note--owner-repo-from-file (file)
  "Return (OWNER . REPO) parsed from FILE's front matter, or nil."
  (when-let ((repo-slug (my/task--front-matter-get-from-file file "repo")))
    (my/task--split-repo-slug repo-slug)))

(defun my/task--rename-in-task-repo (file &rest denote-rename-args)
  "Call `denote-rename-file' on FILE with correct git repo context."
  (let* ((abs-file (expand-file-name file))
         (default-directory (file-name-directory abs-file)))
    (apply #'denote-rename-file abs-file denote-rename-args)))

;;;###autoload
(defun my/task-note-todo-add (&optional owner repo title workflow extended-workflow-p)
  "Quick capture a todo task note.
See `my/task-todo-add' for the stable facade."
  (interactive (list nil nil nil nil current-prefix-arg))
  (let* ((interactive-p (called-interactively-p 'any))
         (repo-selection
          (if repo
              (cons (or owner
                        (condition-case nil
                            (my/repo-owner-for-repo repo)
                          (user-error nil)))
                    repo)
            (when interactive-p
              (let* ((repos (my/repo-list))
                     (_ (unless repos
                          (user-error
                           "No repos found under ~/work/")))
                     (candidates (mapcar (lambda (cell)
                                           (format "%s/%s" (car cell) (cdr cell)))
                                         repos))
                     (choice (completing-read "Repo: " candidates nil nil))
                     (parts (split-string choice "/")))
                (cons (car parts) (cadr parts))))))
         (owner (car repo-selection))
         (repo (cdr repo-selection))
         (denote-directory (expand-file-name "~/work/tasks/"))
         (subdir (when interactive-p
                   (denote-subdirectory-prompt)))
         (target-dir (if subdir
                         (expand-file-name subdir denote-directory)
                       denote-directory))
         (title (or title (read-string "Title: ")))
         (workflow (my/task--normalize-workflow
                    (or workflow
                        (if interactive-p
                            (my/task--read-workflow extended-workflow-p)
                          "task"))))
         (skill (my/task--workflow-front-matter-skill workflow))
         (template (my/task--workflow-template workflow)))
    (make-directory target-dir t)
    (let ((denote-directory target-dir))
      (denote title nil 'markdown-yaml nil nil template "todo")
      (when-let ((repo-slug (my/task--repo-slug owner repo)))
        (my/task--front-matter-set "repo" repo-slug))
      (when skill
        (my/task--front-matter-set "skill" skill))
      (save-buffer)
      (let ((file buffer-file-name))
        (my/task--notify-note-status-change file "todo")
        (unless interactive-p
          (kill-buffer))
        file))))

;;;###autoload
(defun my/task-note-todo-list ()
  "Return list of todo task note file paths, sorted by age."
  (let ((files (denote-directory-files "==todo--" nil nil nil t)))
    (sort files
          (lambda (a b)
            (string< (denote-retrieve-filename-identifier a)
                     (denote-retrieve-filename-identifier b))))))

;;;###autoload
(defun my/task-note-todo-summary ()
  "Return total todo task note count."
  (my/task--todo-summary-snapshot))

;;;###autoload
(defun my/task-note-file (task-id)
  "Return current task note path for TASK-ID."
  (cond
   ((my/task-note--compat-override-p 'my/task-file 'my/task-note-file)
    (my/task-file task-id))
   ((my/task-note--compat-override-p 'my/task--get-file 'my/task-note-file)
    (my/task--get-file task-id))
   (t
    (or (my/task--cache-file-get task-id)
        (when-let ((path (denote-get-path-by-id task-id)))
          (my/task--cache-file-put task-id path))
        (when-let ((path (my/task--find-file-in-task-directories task-id)))
          (my/task--cache-file-put task-id path))))))

;;;###autoload
(defun my/task-note-content (task)
  "Return task note body for TASK without YAML front matter."
  (when-let ((file (my/task-note--resolve-to-file task)))
    (with-temp-buffer
      (insert-file-contents file)
      (when-let ((bounds (my/task--front-matter-bounds)))
        (goto-char (cdr bounds))
        (forward-line 1)
        (delete-region (point-min) (point)))
      (string-trim-left
       (buffer-substring-no-properties (point-min) (point-max))))))

;;;###autoload
(defun my/task-note-owner-repo (task)
  "Return (OWNER . REPO) for TASK from task note metadata."
  (when-let ((file (my/task-note--resolve-to-file task)))
    (my/task-note--owner-repo-from-file file)))

;;;###autoload
(defun my/task-note-repo (task)
  "Return repo for TASK from task note metadata."
  (cdr (my/task-note-owner-repo task)))

;;;###autoload
(defun my/task-note-owner (task)
  "Return owner for TASK from task note metadata."
  (car (my/task-note-owner-repo task)))

;;;###autoload
(defun my/task-note-status (task)
  "Return the task note status for TASK."
  (if (my/task-note--compat-override-p 'my/task-status 'my/task-note-status)
      (my/task-status task)
    (when-let ((file (my/task-note--resolve-to-file task)))
      (let ((sig (denote-retrieve-filename-signature file)))
        (when (member sig my/task-statuses)
          sig)))))

;;;###autoload
(defun my/task-note-skill (task)
  "Return skill for TASK from front matter, or nil if absent."
  (if (my/task-note--compat-override-p 'my/task-skill 'my/task-note-skill)
      (my/task-skill task)
    (when-let ((file (my/task-note--resolve-to-file task)))
      (my/task--front-matter-get-from-file file "skill"))))

;;;###autoload
(defun my/task-note-session-get (task)
  "Return persisted backend-tagged session metadata for TASK, or nil."
  (if (my/task-note--compat-override-p 'my/task-session-get 'my/task-note-session-get)
      (my/task-session-get task)
    (when-let ((file (my/task-note--resolve-to-file task)))
      (my/task--front-matter-get-from-file file "session"))))

;;;###autoload
(defun my/task-note-session-format (backend session-id)
  "Return canonical `session' front-matter value for BACKEND and SESSION-ID."
  (let* ((normalized-backend (my/agent-normalize-backend backend))
         (normalized-id (and session-id
                             (string-trim (format "%s" session-id)))))
    (unless normalized-backend
      (user-error "Session metadata requires a supported backend"))
    (unless (and normalized-id (not (string-empty-p normalized-id)))
      (user-error "Session metadata requires a non-empty session id"))
    (when (equal normalized-backend "pi")
      (setq normalized-id (my/agent-pi-session-timestamp-normalize normalized-id))
      (unless normalized-id
        (user-error "Pi session metadata requires a compact exact token, not %S"
                    session-id)))
    (format "%s:%s" normalized-backend normalized-id)))

;;;###autoload
(defun my/task-note-session-parse (value)
  "Parse backend-tagged session metadata VALUE into a plist."
  (let ((text (and value (string-trim (format "%s" value)))))
    (unless (or (null text) (string-empty-p text))
      (unless (string-match "\\`\\([^:]+\\):\\(.*\\)\\'" text)
        (user-error "Invalid session metadata %S; expected BACKEND:ID" text))
      (let* ((backend (my/agent-normalize-backend (match-string 1 text)))
             (session-id (string-trim (match-string 2 text))))
        (unless backend
          (user-error "Invalid session backend in %S" text))
        (unless (not (string-empty-p session-id))
          (user-error "Invalid session id in %S" text))
        (when (equal backend "pi")
          (setq session-id (my/agent-pi-session-timestamp-normalize session-id))
          (unless session-id
            (user-error "Invalid Pi session timestamp in %S" text)))
        (list :backend backend :id session-id)))))

;;;###autoload
(defun my/task-note-session-set (task value)
  "Persist backend-tagged session metadata VALUE for TASK."
  (if (my/task-note--compat-override-p 'my/task-session-set 'my/task-note-session-set)
      (my/task-session-set task value)
    (when-let ((file (my/task-note--resolve-to-file task)))
      (my/task--front-matter-update-file
       file
       (lambda ()
         (my/task--front-matter-set "session" value))))))

;;;###autoload
(defun my/task-note-worktree-get (task)
  "Return persisted worktree suffix for TASK, or nil."
  (when-let ((file (my/task-note--resolve-to-file task)))
    (my/task--front-matter-get-from-file file "worktree")))

;;;###autoload
(defun my/task-note-worktree-set (task value)
  "Persist worktree suffix VALUE for TASK."
  (when-let ((file (my/task-note--resolve-to-file task)))
    (my/task--front-matter-update-file
     file
     (lambda ()
       (my/task--front-matter-set "worktree" value)))))

;;;###autoload
(defun my/task-note-session-persist-state (task backend session-id &optional worktree)
  "Persist BACKEND SESSION-ID and optional WORKTREE metadata for TASK.
Pi session metadata always requires explicit WORKTREE because compact
`session: pi:TIMESTAMP' values do not encode the session cwd. Non-Pi backends
clear any existing durable `worktree' field so task notes do not retain stale
Pi-only exact-slot metadata."
  (let* ((task-id (my/task-note--resolve-id task))
         (file (my/task-note--resolve-to-file task))
         (normalized-backend (my/agent-normalize-backend backend))
         (value (my/task-note-session-format backend session-id)))
    (unless task-id
      (user-error "Could not resolve task for session persistence: %s" task))
    (unless file
      (user-error "Task file not found for session persistence: %s" task-id))
    (when (and (equal normalized-backend "pi")
               (not (and worktree
                         (not (string-empty-p (string-trim (format "%s" worktree)))))))
      (user-error "Pi session persistence requires explicit worktree metadata"))
    (my/task--front-matter-update-file
     file
     (lambda ()
       (my/task--front-matter-set "session" value)
       (my/task--front-matter-set
        "worktree"
        (when (equal normalized-backend "pi")
          (string-trim (format "%s" worktree))))))
    value))
;;;###autoload
(defun my/task-note-session-register-backend-session (task backend session-id &optional worktree)
  "Persist hook-reported BACKEND SESSION-ID metadata for TASK.
When WORKTREE is non-nil, persist it alongside the session metadata."
  (my/task-note-session-persist-state task backend session-id worktree))

;;;###autoload
(defun my/task-note-session-clear (task)
  "Clear persisted backend-tagged session metadata for TASK.
Also remove any persisted Pi `worktree' slot metadata so fresh launches do not
inherit stale strict-resume state."
  (if (my/task-note--compat-override-p 'my/task-session-clear 'my/task-note-session-clear)
      (my/task-session-clear task)
    (when-let ((file (my/task-note--resolve-to-file task)))
      (my/task--front-matter-update-file
       file
       (lambda ()
         (my/task--front-matter-set "session" nil)
         (my/task--front-matter-set "worktree" nil))))))

;;;###autoload
(defun my/task-note-title (task)
  "Return the denote title for TASK, or nil if unavailable."
  (if (my/task-note--compat-override-p 'my/task-title 'my/task-note-title)
      (my/task-title task)
    (when-let ((file (my/task-note--resolve-to-file task)))
      (or (and (fboundp 'denote-retrieve-title-value)
               (fboundp 'denote-filetype-heuristics)
               (denote-retrieve-title-value file
                                            (denote-filetype-heuristics file)))
          (and (fboundp 'denote-retrieve-front-matter-title-value)
               (fboundp 'denote-filetype-heuristics)
               (denote-retrieve-front-matter-title-value
                file
                (denote-filetype-heuristics file)))
          (and (fboundp 'denote-retrieve-filename-title)
               (denote-retrieve-filename-title file))
          (file-name-base file)))))

;;;###autoload
(defun my/task-note-mark-done (file)
  "Transition FILE to done status."
  (let ((denote-rename-confirmations nil)
        (denote-save-buffers t))
    (let ((renamed-file
           (my/task--rename-in-task-repo file 'keep-current 'keep-current "done" 'keep-current 'keep-current)))
      (my/task--notify-note-status-change renamed-file "done")
      renamed-file)))

;;;###autoload
(defun my/task-note-mark-todo (file)
  "Transition FILE to todo status."
  (let ((denote-rename-confirmations nil)
        (denote-save-buffers t))
    (let ((renamed-file
           (my/task--rename-in-task-repo file 'keep-current 'keep-current "todo" 'keep-current 'keep-current)))
      (my/task--notify-note-status-change renamed-file "todo")
      renamed-file)))

;;;###autoload
(defun my/task-note-mark-discarded (file)
  "Transition FILE to discarded status."
  (let ((denote-rename-confirmations nil)
        (denote-save-buffers t))
    (let ((renamed-file
           (my/task--rename-in-task-repo file 'keep-current 'keep-current "discarded" 'keep-current 'keep-current)))
      (my/task--notify-note-status-change renamed-file "discarded")
      renamed-file)))

(provide 'my-task-note)
;;; my-task-note.el ends here
