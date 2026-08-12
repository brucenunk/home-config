;;; my-task-session.el --- Task session and worktree lifecycle -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (denote "3.0") (seq "2.24"))

;;; Commentary:

;; Session/worktree implementation extracted from `my-task.el`.
;;
;; This module owns:
;;   - task worktree setup/resume flows
;;   - live agent session lifecycle
;;   - selected-window session restore UI
;;   - pickup/exit command implementations
;;
;; Lifecycle contract:
;;   - `pickup` re-enters a task from durable task-note/branch state first
;;   - backend session resume is optional continuation help layered on top
;;   - `exit` means pause: preserve task continuity, clear live session, and
;;     release the worktree without treating the task as finished
;;
;; `my-task.el` remains the stable public entry point and lazy-loads this
;; module for session-heavy behavior. Indexed state lives in
;; `my-task-index.el`; repair and reconciliation live in `my-worktree-repair.el`.

;;; Code:

(require 'cl-lib)
(require 'denote)
(require 'my-agent)
(require 'my-git)
(require 'my-hephaestus)
(require 'my-task)
(require 'my-task-index)
(require 'my-task-note)
(require 'my-worktree)
(require 'seq)
(require 'subr-x)

(defvar my/task-index)

(declare-function my/task-branch "my-task" (task-id))
(declare-function my/task-file-p "my-task" ())
(declare-function my/task-find-by-worktree "my-task" (worktree-path))
(declare-function my/task-list "my-task" ())
(declare-function my/task-resolve-id "my-task" (task))
(declare-function my/task-select "my-task" ())
(declare-function my/task-session-buffer-name "my-task" (task-id))
(declare-function my/task-state-notify "my-task" (task-id source &rest props))
(declare-function my/task-status "my-task" (task))
(declare-function my/task-owner-repo "my-task" (task))
(declare-function my/task-worktree "my-task" (task))
(declare-function my/task-worktree-repairing "my-task" (task))
(declare-function my/task--feature-worktree-p "my-task" (worktree-path))
(declare-function my/worktree-repair-branch-task-id "my-worktree-repair" (branch))
(declare-function my/task-note-content "my-task-note" (task))
(declare-function my/task-note-file "my-task-note" (task-id))
(declare-function my/task-note-owner-repo "my-task-note" (task))
(declare-function my/task-note-session-clear "my-task-note" (task))
(declare-function my/task-note-session-format "my-task-note" (backend session-id))
(declare-function my/task-note-session-get "my-task-note" (task))
(declare-function my/task-note-session-parse "my-task-note" (value))
(declare-function my/task-note-session-persist-state "my-task-note" (task backend session-id &optional worktree))
(declare-function my/task-note-session-set "my-task-note" (task value))
(declare-function my/task-note-worktree-get "my-task-note" (task))
(declare-function my/task-note-skill "my-task-note" (task))
(declare-function my/task-note-status "my-task-note" (task))
(declare-function my/task-note-title "my-task-note" (task))
(declare-function my/worktree-repair-claimed-worktrees-for-pickup "my-worktree-repair" ())
(declare-function my/task-index-claimed-worktrees "my-task-index")
(declare-function my/task-index-entry "my-task-index" (task-id))
(declare-function my/task-index-entries "my-task-index")
(declare-function my/task-index-entries-where "my-task-index" (prop value))
(declare-function my/task-index-find-by-worktree "my-task-index" (path))
(declare-function my/task-index-get "my-task-index" (task-id))
(declare-function my/task-index-put "my-task-index" (task-id props &optional persist))
(declare-function my/task-index-remove "my-task-index" (task-id))
(declare-function my/task-index-worktree "my-task-index" (task-id))
(declare-function my/task-index-worktree-clear "my-task-index" (task-id &optional persist))
(declare-function my/task-index-worktree-set "my-task-index" (task-id worktree &optional persist))

(declare-function my/worktree-list-for-repo "my-worktree" (owner repo))
(declare-function my/agent-pi-session-file "my-agent-pi" (task-id dir))
(declare-function my/agent-pi-session-resolve "my-agent-pi" (task-id dir &optional session-id))
(declare-function my/agent-pi-session-timestamp "my-agent-pi" (session-file))

(defconst my/task-session-ignored-stored-backends '("codex")
  "Legacy stored session backends to ignore during pickup.")

(defvar-local my/task-session-task-id nil
  "Buffer-local variable tracking which task this session buffer belongs to.
Stores the denote identifier (e.g., \"20260204T111217\").")

(defvar-local my/task-session-backend nil
  "Buffer-local backend name for this task session buffer.")

(defvar-local my/task-session-options nil
  "Buffer-local backend option plist for this task session buffer.")

(defvar my/task-session--title-backfill-pending (make-hash-table :test 'equal)
  "Worktree paths with an in-flight async title backfill.")

(defconst my/task-session--wip-subject-prefix "WIP ["
  "Commit subject prefix used for synthetic exit checkpoint commits.")

(defun my/task-session--wip-subject (task-id)
  "Return synthetic WIP checkpoint subject for TASK-ID."
  (format "%s%s] checkpoint before exit"
          my/task-session--wip-subject-prefix
          task-id))

(defun my/task-session--notify (task-id &rest props)
  "Broadcast a session-originated task-state change for TASK-ID."
  (apply #'my/task-state-notify task-id 'session props))

(defun my/task-session--worktree-front-matter (worktree)
  "Return persisted worktree name for WORKTREE, or nil."
  (when worktree
    (file-name-nondirectory
     (directory-file-name (expand-file-name worktree)))))

(defun my/task-session--call-repair (fn &rest args)
  "Load `my-worktree-repair' and call FN with ARGS."
  (require 'my-worktree-repair)
  (apply fn args))

(defun my/task-session--validate-pinned-pi-worktree (task-id branch claimed existing-worktree entry label)
  "Return validated strict Pi worktree selection for TASK-ID from ENTRY.
LABEL is used in user-facing error messages."
  (let* ((path (plist-get entry :path))
         (claim-owner (my/task-index-find-by-worktree path)))
    (cond
     ((and (member path claimed)
           claim-owner
           (not (equal claim-owner task-id)))
      (list :error (format "%s is claimed by task %s" label claim-owner)))
     ((and (not (my/worktree-clean-p path))
           (not (equal path existing-worktree)))
      (list :error (format "%s is dirty: %s" label path)))
     ((and (not (plist-get entry :detached))
           (not (equal (plist-get entry :branch) branch)))
      (list :error (format "%s is attached to %s, not %s"
                           label
                           (or (plist-get entry :branch) "<unknown>")
                           branch)))
     (t
      (list :path path)))))

(defun my/task-session--pinned-pi-worktree (task-id owner repo branch claimed existing-worktree &optional resume-state)
  "Return strict Pi worktree selection for TASK-ID, or nil.
Pi resume state requires persisted `worktree' front matter so exact resume can
reconstruct the session path and match the cwd stored in Pi's session header.
Only Pi resume-state uses this strict exact-worktree logic. On mismatch or
unavailability, return plist `(:error MESSAGE)'."
  (when (equal (plist-get resume-state :backend) "pi")
    (let* ((worktree-entries (seq-filter (lambda (entry)
                                           (my/task--feature-worktree-p
                                            (plist-get entry :path)))
                                         (my/worktree-list-for-repo owner repo)))
           (stored-worktree (my/task-note-worktree-get task-id)))
      (cond
       ((not stored-worktree)
        (list :error (format "Recorded Pi worktree is missing for task %s"
                             task-id)))
       ((if-let ((entry (seq-find (lambda (candidate)
                                    (equal (my/task-session--worktree-front-matter
                                            (plist-get candidate :path))
                                           stored-worktree))
                                  worktree-entries)))
            (my/task-session--validate-pinned-pi-worktree
             task-id branch claimed existing-worktree entry
             (format "Recorded Pi worktree %s" stored-worktree))
          (list :error (format "Recorded Pi worktree %s is unavailable for task %s"
                               stored-worktree task-id))))))))

(defun my/task-session-applicable-agents-files (worktree)
  "Return applicable `AGENTS.md' files for WORKTREE.
Walk ancestors from WORKTREE up to `~/work', keeping only existing files."
  (when-let* ((worktree-root (and worktree
                                  (file-name-as-directory
                                   (expand-file-name worktree))))
              (work-root (file-name-as-directory
                          (expand-file-name "~/work"))))
    (let ((current worktree-root)
          (agents-files nil))
      (while (and current
                  (file-in-directory-p current work-root))
        (let ((agents-file (expand-file-name "AGENTS.md" current)))
          (when (file-exists-p agents-file)
            (push agents-file agents-files)))
        (if (equal current work-root)
            (setq current nil)
          (let* ((parent (file-name-directory
                          (directory-file-name current)))
                 (normalized-parent
                  (and parent (file-name-as-directory parent))))
            (setq current
                  (unless (or (null normalized-parent)
                              (equal normalized-parent current))
                    normalized-parent)))))
      agents-files)))

(cl-defun my/task-session-setup-worktree-async (worktree-path task-id &key on-success on-error)
  "Set up WORKTREE-PATH with a fresh task branch for TASK-ID asynchronously.
ON-SUCCESS is called with (BRANCH-NAME) on success.
ON-ERROR is called with (ERROR-MESSAGE) on failure."
  (let* ((new-branch (format "jamesl-%s" task-id))
         (default-wt (my/worktree-default-for-path worktree-path))
         (base-ref (format "origin/%s" (my/git-branch default-wt))))
    (message "Preparing task... (fetching)")
    (my/git-run-async
     worktree-path '("fetch" "origin")
     :name "setup-fetch"
     :on-success
     (lambda (_output _code)
       (message "Preparing task... (creating branch)")
       (pcase-let ((`(,code . ,output)
                    (my/git-run-in-dir worktree-path "checkout" "--detach" "HEAD")))
         (if (not (zerop code))
             (when on-error
               (funcall on-error
                        (format "Failed to detach HEAD in %s: %s"
                                worktree-path (string-trim output))))
           (pcase-let ((`(,code2 . ,output2)
                        (my/git-run-in-dir worktree-path "switch" "-c" new-branch base-ref)))
             (if (not (zerop code2))
                 (when on-error
                   (funcall on-error
                            (format "Failed to create branch %s in %s: %s"
                                    new-branch worktree-path (string-trim output2))))
               (message "Task ready")
               (when on-success
                 (funcall on-success new-branch)))))))
     :on-error
     (lambda (_code output)
       (when on-error
         (funcall on-error
                  (format "Failed to fetch origin in %s: %s"
                          worktree-path (string-trim output))))))))

(defun my/task-session-wip-commit-p (task-id worktree-path)
  "Return non-nil if HEAD in WORKTREE-PATH is TASK-ID's WIP checkpoint commit."
  (pcase-let ((`(,code . ,output)
               (my/git-run-in-dir worktree-path "log" "-1" "--format=%s" "HEAD")))
    (and (zerop code)
         (equal (string-trim output)
                (my/task-session--wip-subject task-id)))))

(defun my/task-session--checkpoint-wip (task-id worktree-path)
  "Checkpoint dirty WORKTREE-PATH state for TASK-ID onto the task branch.
Return the synthetic commit subject when a checkpoint commit is created, or
nil when the worktree is already clean."
  (unless (my/worktree-clean-p worktree-path)
    (when (my/git-in-merge-or-rebase-p worktree-path)
      (user-error "Cannot exit: %s has an in-progress merge, rebase, or cherry-pick"
                  worktree-path))
    (pcase-let ((`(,add-code . ,add-output)
                 (my/git-run-in-dir worktree-path "add" "-A")))
      (unless (zerop add-code)
        (error "Failed to stage worktree %s for exit checkpoint: %s"
               worktree-path
               (string-trim add-output))))
    (let ((subject (my/task-session--wip-subject task-id)))
      (pcase-let ((`(,commit-code . ,commit-output)
                   (my/git-run-in-dir worktree-path "commit" "-m" subject)))
        (unless (zerop commit-code)
          (error "Failed to checkpoint task %s in %s: %s"
                 task-id
                 worktree-path
                 (string-trim commit-output)))
        subject))))

(defun my/task-session-reset-wip (task-id worktree-path)
  "Mixed reset HEAD in WORKTREE-PATH if it is TASK-ID's WIP checkpoint commit."
  (if (not (my/task-session-wip-commit-p task-id worktree-path))
      t
    (pcase-let ((`(,code . ,_output)
                 (my/git-run-in-dir worktree-path "rev-parse" "--verify" "HEAD^")))
      (if (not (zerop code))
          t
        (pcase-let ((`(,reset-code . ,_reset-output)
                     (my/git-run-in-dir worktree-path "reset" "--mixed" "HEAD^")))
          (zerop reset-code))))))

(cl-defun my/task-session-resume-on-branch-async (worktree-path branch &key on-success on-error)
  "Resume work in WORKTREE-PATH by checking out existing BRANCH asynchronously."
  (when (my/git-in-merge-or-rebase-p worktree-path)
    (when on-error
      (funcall on-error
               (format "Cannot resume: %s has an in-progress merge, rebase, or cherry-pick"
                       worktree-path)))
    (cl-return-from my/task-session-resume-on-branch-async))
  (message "Preparing task... (resuming worktree)")
  (my/hephaestus-resume-async
   worktree-path branch
   :on-success
   (lambda (resumed-worktree)
     (if (my/task-session-reset-wip
          (or (my/worktree-repair-branch-task-id branch)
              branch)
          resumed-worktree)
         (progn
           (message "Task ready: %s" branch)
           (when on-success
             (funcall on-success)))
       (when on-error
         (funcall on-error
                  (format "Failed to reset WIP commit in %s"
                          resumed-worktree)))))
   :on-error on-error))

(defun my/task-session-live-buffer (task-id)
  "Return live session buffer for TASK-ID without consulting the task index."
  (let ((session-buffer (get-buffer (my/task-session-buffer-name task-id))))
    (when (and session-buffer
               (buffer-live-p session-buffer)
               (string= task-id
                        (buffer-local-value 'my/task-session-task-id session-buffer))
               (my/agent-session-live-p session-buffer))
      session-buffer)))

(defun my/task-session-ensure-live (task-id)
  "Return live task session buffer for TASK-ID, or nil."
  (when-let ((session-buffer (my/task-session-live-buffer task-id)))
    (unless (my/task-session-state-active-p task-id)
      (my/task-session-state-add task-id))
    session-buffer))

(defun my/task-session-sync-entry (task-id session-buffer)
  "Repair TASK-ID index metadata from live SESSION-BUFFER when possible."
  (when (and (buffer-live-p session-buffer)
             (stringp task-id))
    (let* ((entry (my/task-index-get task-id))
           (worktree (with-current-buffer session-buffer
                       (and default-directory
                            (file-name-as-directory
                             (expand-file-name default-directory)))))
           (updates nil))
      (when (and worktree
                 (or (null entry)
                     (not (equal (plist-get entry :worktree) worktree))))
        (setq updates (plist-put updates :worktree worktree)))
      (when updates
        (my/task-index-worktree-set task-id worktree)
        (my/task-session--notify task-id
                                 :changes '(:worktree)
                                 :worktree worktree)))))

(defun my/task-session-clear-worktree-state (task-id)
  "Clear transient worktree ownership for TASK-ID."
  (when-let ((entry (my/task-index-entry task-id)))
    (when (plist-get entry :worktree)
      (my/task-index-worktree-clear task-id)
      (my/task-session--notify task-id :changes '(:worktree)
                               :worktree nil))))

(defun my/task-session-note-buffer (file)
  "Return FILE's visiting buffer, normalizing stale Dired-style names."
  (let ((buffer (or (get-file-buffer file)
                    (find-file-noselect file))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (and buffer-file-name
                   (string-prefix-p "[D] " (buffer-name buffer)))
          (rename-buffer (generate-new-buffer-name
                          (file-name-nondirectory buffer-file-name))
                         t))))
    buffer))

(defun my/task-session-launch-config-normalize (launch-config)
  "Normalize explicit LAUNCH-CONFIG for session startup."
  (let* ((backend (or (my/agent-normalize-backend (plist-get launch-config :backend))
                      (user-error "Session startup requires explicit :backend in launch-config")))
         (options (or (plist-get launch-config :options)
                      (my/agent-backend-options-default backend))))
    (list :backend backend :options options)))

(defun my/task-session-pickup-launch-config (&optional advanced-options)
  "Return pickup launch config plist with :backend and :options."
  (if advanced-options
      (let* ((backend (or (my/agent-single-backend)
                          (my/agent-backend-prompt (my/agent-default-backend-resolve))))
             (options (my/agent-backend-options-prompt
                       backend
                       (my/agent-backend-options-default backend)
                       advanced-options)))
        (list :backend backend :options options))
    (my/agent-default-launch-config)))

(defun my/task-session--stored-resume-state (task-id)
  "Return parsed stored resume state plist for TASK-ID, or nil.
Unsupported legacy backend metadata is ignored so old task notes do not block
pickup after backend removals."
  (when-let ((stored (my/task-note-session-get task-id)))
    (condition-case err
        (let ((resume-state (my/task-note-session-parse stored)))
          (unless (plist-get resume-state :id)
            (user-error "Stored session metadata for task %s is missing a session id"
                        task-id))
          resume-state)
      (user-error
       (let* ((text (string-trim (format "%s" stored)))
              (backend-text (and (string-match "\\`\\([^:]+\\):" text)
                                 (downcase (match-string 1 text)))))
         (if (member backend-text my/task-session-ignored-stored-backends)
             nil
           (user-error "Stored session metadata for task %s is invalid: %s"
                       task-id
                       (error-message-string err))))))))

(defun my/task-session--resume-launch-config (resume-state interactive-p launch-config
                                                           advanced-options)
  "Resolve launch config for RESUME-STATE.
If LAUNCH-CONFIG specifies a different backend than RESUME-STATE, signal
`user-error'. INTERACTIVE-P and ADVANCED-OPTIONS control whether backend
options are reprompted."
  (let* ((backend (plist-get resume-state :backend))
         (explicit-backend (my/agent-normalize-backend
                            (plist-get launch-config :backend)))
         (seed-options (or (plist-get launch-config :options)
                           (my/agent-backend-options-default backend)))
         (options (if (and interactive-p advanced-options)
                      (my/agent-backend-options-prompt backend
                                                       seed-options
                                                       advanced-options)
                    seed-options)))
    (when (and explicit-backend
               (not (equal explicit-backend backend)))
      (user-error "Stored session metadata requires backend %s, not %s"
                  backend explicit-backend))
    (list :backend backend :options options)))

(defun my/task-session--pickup-preflight-check (task-id)
  "Validate TASK-ID for pickup without claiming worktree state."
  (let ((file (my/task-note-file task-id)))
    (unless file
      (user-error "Task not found: %s" task-id))
    (let ((status (my/task-note-status file)))
      (cond
       ((equal status "done")
        (user-error "Task is already done"))
       ((equal status "discarded")
        (user-error "Task is discarded"))
       ((not (equal status "todo"))
        (user-error "Unknown task status: %s" status))))))

(defun my/task-session--pickup-resolve-launch-config (interactive-p launch-config
                                                                    advanced-options
                                                                    resume-state)
  "Resolve pickup launch config before worktree side effects.
When RESUME-STATE is non-nil, reuse its backend and only reprompt backend
options when INTERACTIVE-P and ADVANCED-OPTIONS are both non-nil.
Otherwise, when INTERACTIVE-P is non-nil, prompt using ADVANCED-OPTIONS.
When no RESUME-STATE is present, non-interactive callers must provide
explicit LAUNCH-CONFIG."
  (if resume-state
      (my/task-session--resume-launch-config resume-state
                                             interactive-p
                                             launch-config
                                             advanced-options)
    (if interactive-p
        (my/task-session-pickup-launch-config advanced-options)
    (if launch-config
        (my/task-session-launch-config-normalize launch-config)
      (user-error "Non-interactive task pickup requires :launch-config with explicit :backend")))))

(defun my/task-session--no-usable-worktree-error (repo unusable)
  "Return pickup error string for REPO when only UNUSABLE worktrees remain."
  (if unusable
      (format "No usable worktrees for repo %s (dirty: %s)"
              repo
              (mapconcat (lambda (entry)
                           (plist-get entry :path))
                         unusable
                         ", "))
    (format "No available worktrees for repo %s" repo)))

(defun my/task-session--pickup-unusable-message (unusable)
  "Return success-path pickup message suffix for UNUSABLE worktrees."
  (when unusable
    (format "Skipped unusable worktrees: %s"
            (mapconcat (lambda (entry)
                         (plist-get entry :path))
                       unusable
                       ", "))))

(defun my/task-session--pickup-error (message &optional unusable)
  "Return pickup error payload for MESSAGE and optional UNUSABLE worktrees."
  (if unusable
      (list :message message
            :unusable-worktrees unusable)
    message))

(defun my/task-session--pickup-error-message (err)
  "Return user-facing pickup error message string from ERR."
  (if (stringp err)
      err
    (or (plist-get err :message)
        (format "%s" err))))
(cl-defun my/task-session-pickup-start-async (task-id &key launch-config advanced-options
                                                      restore-session interactive-p
                                                      on-success on-error)
  "Prepare TASK-ID for work and optionally restore its workspace."
  (condition-case err
      (progn
        (my/task-session--pickup-preflight-check task-id)
        (if-let ((live-session (my/task-session-ensure-live task-id)))
          (progn
            (my/task-session-sync-entry task-id live-session)
            (when restore-session
              (my/task-session-restore-view task-id))
            (when on-success
              (funcall on-success
                       (list :task-id task-id
                             :worktree (my/task-worktree task-id)
                             :outcome 'live))))
          (let* ((resume-state (my/task-session--stored-resume-state task-id))
                 (resolved-launch-config
                 (my/task-session--pickup-resolve-launch-config
                  interactive-p launch-config advanced-options resume-state)))
            (my/task-session-prepare-work-async
             task-id
             :resume-state resume-state
             :on-success
             (lambda (result)
               (condition-case inner-err
                   (let ((resolved-id (plist-get result :task-id)))
                     (my/task-session-create resolved-id resolved-launch-config
                                             :display-fn (unless restore-session #'ignore)
                                             :resume-state resume-state)
                     (when restore-session
                       (my/task-session-restore-view resolved-id))
                     (when on-success
                       (funcall on-success
                                (append result
                                        (list :outcome 'started)))))
                 (error
                  (when on-error
                    (funcall on-error (error-message-string inner-err))))))
             :on-error on-error))))
    (quit
     (when on-error
       (funcall on-error "Quit")))
    (error
     (when on-error
       (funcall on-error (error-message-string err))))))

(defun my/task-session-bootstrap-context (task &optional worktree)
  "Return task bootstrap context plist for TASK."
  (when-let* ((task-id (my/task-resolve-id task))
              (file (my/task-note-file task-id)))
    (let* ((filetype (denote-filetype-heuristics file))
           (title (or (my/task-note-title file)
                      (denote-retrieve-front-matter-title-value file filetype)
                      (denote-retrieve-filename-title file)))
           (skill (my/task-note-skill file))
           (task-note-content (my/task-note-content file))
           (agents-files (my/task-session-applicable-agents-files worktree)))
      (list :task-id task-id
            :title title
            :skill skill
            :task-note-content task-note-content
            :agents-files agents-files))))

;;;###autoload
(defun my/task-session-clear-buffer (task-id)
  "Kill the live session buffer for TASK-ID when present."
  (when-let ((session-buffer (get-buffer (my/task-session-buffer-name task-id))))
    (let ((kill-buffer-query-functions nil))
      (kill-buffer session-buffer))))

(defun my/task-session-active-ids ()
  "Return list of task-ids with active live sessions.
This is a switcher hot path, so it syncs from live session buffers without
forcing a full durable task-index repair."
  (mapcar (lambda (entry) (plist-get entry :task-id))
          (my/task-session-active-entries)))

(defun my/task-session-active-entries ()
  "Return active task index entries after syncing against live sessions."
  (my/task-session-sync-active)
  (my/task-index-entries-where :active t))

(defun my/task-session-sync-active ()
  "Sync transient active-session flags against live `agent-task-*' buffers."
  (let ((live-task-ids nil))
    (dolist (buf (buffer-list))
      (when-let ((task-id (and (string-prefix-p "agent-task-" (buffer-name buf))
                               (buffer-live-p buf)
                               (buffer-local-value 'my/task-session-task-id buf))))
        (when (and (stringp task-id)
                   (my/agent-session-live-p buf))
          (my/task-session-sync-entry task-id buf)
          (push task-id live-task-ids))))
    (setq live-task-ids (delete-dups live-task-ids))
    (dolist (entry (my/task-index-entries))
      (let ((task-id (plist-get entry :task-id)))
        (cond
         ((member task-id live-task-ids)
          (if-let ((reason (my/task-session-stale-reason task-id)))
              (my/task-session-prune-stale task-id reason)
            (my/task-session-active-set task-id t)))
         ((plist-get entry :active)
          (my/task-session-active-set task-id nil)))))
    live-task-ids))

;;;###autoload
(defun my/task-session-stale-reason (task-id &optional entry)
  "Return stale reason symbol for TASK-ID active session, or nil."
  (cond
   ((null (my/task-note-file task-id))
    'missing-file)
   ((not (equal (my/task-note-status task-id) "todo"))
    'non-todo-task)
   ((null (or (plist-get (or entry (my/task-index-get task-id)) :worktree)
              (my/task-worktree task-id)))
    'missing-worktree)
   ((null (my/task-session-live-buffer task-id))
    'dead-session)
   (t nil)))

;;;###autoload
(defun my/task-session-prune-stale (task-id reason)
  "Clear stale active session state for TASK-ID with REASON symbol."
  (when-let ((session-buffer (get-buffer (my/task-session-buffer-name task-id))))
    (let ((kill-buffer-query-functions nil))
      (kill-buffer session-buffer)))
  (my/task-session-state-remove task-id)
  (message "Cleared stale active session (%s): %s" reason task-id))

(defun my/task-session-kill-orphaned-buffers ()
  "Kill orphaned agent-task-* buffers."
  (dolist (buf (buffer-list))
    (when (and (string-prefix-p "agent-task-" (buffer-name buf))
               (buffer-local-value 'my/task-session-task-id buf)
               (not (my/task-session-state-active-p
                     (buffer-local-value 'my/task-session-task-id buf)))
               (null (get-buffer-window-list buf nil t)))
      (with-current-buffer buf
        (let ((kill-buffer-query-functions nil))
          (kill-buffer))))))

;;;###autoload
(defun my/task-session-release (task-id &optional worktree)
  "Release active session state for TASK-ID."
  (when worktree
    (my/hephaestus-release worktree)
    (my/task-session-clear-worktree-state task-id))
  (my/task-session-state-remove task-id))

(defun my/task-session-active-set (task-id active)
  "Set TASK-ID active session flag to ACTIVE in the in-memory index."
  (let* ((existing (my/task-index-get task-id))
         (old-active (plist-get existing :active)))
    (unless (eq old-active active)
      (let ((entry (copy-tree (or existing
                                  (list :task-id task-id)))))
        (setq entry (plist-put entry :active active))
        (puthash task-id entry my/task-index)
        (my/task-session--notify task-id :changes '(:active) :active active)))))

(defun my/task-session-state-add (task)
  "Add TASK to active sessions."
  (when-let ((id (my/task-resolve-id task)))
    (my/task-session-active-set id t)))

(defun my/task-session-state-remove (task)
  "Remove TASK from active sessions."
  (when-let ((id (my/task-resolve-id task)))
    (when-let ((entry (my/task-index-get id)))
      (when (plist-get entry :active)
        (setq entry (plist-put (copy-tree entry) :active nil))
        (puthash id entry my/task-index)
        (my/task-session--notify id :changes '(:active) :active nil)))))

(defun my/task-session-state-active-p (task)
  "Return non-nil if TASK has an active session."
  (when-let ((id (my/task-resolve-id task)))
    (when-let ((entry (my/task-index-get id)))
      (plist-get entry :active))))

(cl-defun my/task-session-create (task launch-config &key display-fn resume-state)
  "Create or resume live agent session for TASK using LAUNCH-CONFIG.
When RESUME-STATE is non-nil, resume the stored backend session instead of
starting a fresh one."
  (let* ((task-id (my/task-resolve-id task))
         (file (and task-id (my/task-note-file task-id))))
    (unless task-id
      (user-error "Could not resolve task: %s" task))
    (unless file
      (user-error "Task file not found for: %s" task-id))
    (let ((worktree (my/task-worktree-repairing file)))
      (unless worktree
        (user-error "No worktree assigned to task: %s" (file-name-nondirectory file)))
      (let* ((selected-config (my/task-session-launch-config-normalize launch-config))
             (selected-backend (plist-get selected-config :backend))
             (selected-options (plist-get selected-config :options))
             (bootstrap-context (my/task-session-bootstrap-context file worktree))
             (session-name (plist-get bootstrap-context :title))
             (bootstrap-prompt (my/agent-bootstrap-prompt selected-backend bootstrap-context))
             (session-buffer-name (my/task-session-buffer-name task-id))
             (session-buffer (get-buffer session-buffer-name))
             (effective-resume-state
              (if (and resume-state (equal selected-backend "pi"))
                  (my/task-session--resolve-pi-resume-state task-id worktree resume-state)
                resume-state))
             (startup-session-id
              (when (and (null effective-resume-state)
                         (equal selected-backend "pi"))
                (require 'my-agent-pi)
                (my/agent-pi-session-file task-id worktree))))
        (when session-buffer
          (let ((kill-buffer-query-functions nil))
            (kill-buffer session-buffer))
          (setq session-buffer nil))
        (setq session-buffer
              (let ((process-environment
                     (cons (format "MY_TASK_ID=%s" task-id)
                           (seq-remove
                            (lambda (entry)
                              (string-prefix-p "MY_TASK_ID=" entry))
                            process-environment))))
                (if effective-resume-state
                    (let* ((resume-id (plist-get effective-resume-state :id))
                           (pi-missing-file-p (and (equal selected-backend "pi")
                                                   resume-id
                                                   (not (file-exists-p resume-id))))
                           (resume-args (list selected-backend
                                              resume-id
                                              session-buffer-name
                                              worktree
                                              :display-fn (or display-fn #'pop-to-buffer-same-window)
                                              :options selected-options)))
                      (when pi-missing-file-p
                        (setq resume-args (append resume-args
                                                  (list :bootstrap-prompt bootstrap-prompt))))
                      (when (equal selected-backend "pi")
                        (setq resume-args (append resume-args
                                                  (list :session-name session-name))))
                      (apply #'my/agent-session-resume-start resume-args))
                  (let ((start-args (list selected-backend
                                          session-buffer-name
                                          worktree
                                          :display-fn (or display-fn #'pop-to-buffer-same-window)
                                          :options selected-options
                                          :bootstrap-prompt bootstrap-prompt
                                          :task-id task-id
                                          :session-id startup-session-id)))
                    (when (equal selected-backend "pi")
                      (setq start-args (append start-args
                                               (list :session-name session-name))))
                    (apply #'my/agent-session-start start-args)))))
        (unless (buffer-live-p session-buffer)
          (user-error "Failed to create %s session buffer for task %s"
                      selected-backend task-id))
        (when startup-session-id
          (my/task-note-session-persist-state
           task-id
           selected-backend
           (if (equal selected-backend "pi")
               (my/agent-pi-session-timestamp startup-session-id)
             startup-session-id)
           (my/task-session--worktree-front-matter worktree)))
        (with-current-buffer session-buffer
          (setq my/task-session-task-id task-id
                my/task-session-backend selected-backend
                my/task-session-options selected-options))
        (my/task-session-state-add task-id)
        session-buffer))))

(defun my/task-session--resolve-pi-resume-state (task-id worktree resume-state)
  "Return concrete Pi RESUME-STATE for TASK-ID in WORKTREE.
Pi task notes store only `session: pi:TIMESTAMP`, so this reconstructs the
exact Pi session file path from TASK-ID, WORKTREE, and the persisted timestamp.
If the task note's persisted worktree differs from WORKTREE, update the note so
future resumes continue to use the exact reconstructed path."
  (require 'my-agent-pi)
  (when-let* ((stored-timestamp (plist-get resume-state :id))
              (resolved-state (my/agent-pi-session-resolve task-id
                                                           worktree
                                                           stored-timestamp)))
    (let* ((resolved-id (plist-get resolved-state :id))
           (resolved-timestamp (my/agent-pi-session-timestamp resolved-id))
           (desired-worktree (my/task-session--worktree-front-matter worktree))
           (stored-worktree (ignore-errors (my/task-note-worktree-get task-id))))
      (when (or (not (equal resolved-timestamp stored-timestamp))
                (not (equal desired-worktree stored-worktree)))
        (my/task-note-session-persist-state
         task-id
         "pi"
         resolved-timestamp
         desired-worktree))
      (list :backend "pi" :id resolved-id))))
(defun my/task-session-restore-view (task)
  "Restore TASK's live session in the selected window."
  (my/task-session-kill-orphaned-buffers)
  (let* ((task-id (my/task-resolve-id task))
         (file (and task-id (my/task-note-file task-id))))
    (unless task-id
      (user-error "Could not resolve task: %s" task))
    (unless file
      (user-error "Task file not found for: %s" task-id))
    (unless (my/task-worktree-repairing file)
      (user-error "No worktree assigned to task: %s" (file-name-nondirectory file)))
    (let ((session-buffer (my/task-session-ensure-live task-id)))
      (unless session-buffer
        (user-error "No live session for task %s; restart via my/task-pickup"
                    task-id))
      (with-current-buffer session-buffer
        (setq my/task-session-task-id task-id))
      (set-window-buffer (selected-window) session-buffer)
      (my/agent-session-resize-to-window session-buffer (selected-window)))))

(defun my/task-session-current-title ()
  "Return the task title for the current buffer context."
  (let ((task-id my/task-session-task-id)
        (file buffer-file-name)
        (dir default-directory))
    (cond
     ((and task-id
           (stringp task-id))
      (if-let ((title (ignore-errors (my/task-note-title task-id))))
          (or title (buffer-name))
        (buffer-name)))
     ((and file
           (bound-and-true-p denote-directory)
           (denote-file-is-in-denote-directory-p file)
           (denote-file-has-denoted-filename-p file))
      (or (my/task-note-title file)
          (buffer-name)))
     ((or (and file (string-prefix-p (expand-file-name "~/work/") file))
          (and dir (string-prefix-p (expand-file-name "~/work/") dir)))
      (my/task-session-title-from-path (or file dir)))
     (t
      (buffer-name)))))

(defun my/task-session-worktree-root-from-path (path)
  "Return containing direct-child worktree root for PATH under ~/work/, or nil."
  (when path
    (let* ((work-root (file-name-as-directory (expand-file-name "~/work/")))
           (expanded (expand-file-name path)))
      (when (string-prefix-p work-root expanded)
        (let* ((relative (directory-file-name
                          (string-remove-prefix work-root expanded)))
               (parts (split-string relative "/" t)))
          (when (>= (length parts) 3)
            (file-name-as-directory
             (expand-file-name
              (mapconcat #'identity (seq-take parts 3) "/")
              work-root))))))))

(defun my/task-session--title-backfill-finish (worktree-path)
  "Clear in-flight title backfill marker for WORKTREE-PATH."
  (remhash (file-name-as-directory (expand-file-name worktree-path))
           my/task-session--title-backfill-pending))

(defun my/task-session--queue-title-backfill (worktree-path)
  "Asynchronously backfill transient task ownership for WORKTREE-PATH.
This keeps git off the synchronous task-title path while still restoring
user-facing task titles shortly after first visiting an attached task worktree
in a fresh Emacs session."
  (let ((normalized (file-name-as-directory (expand-file-name worktree-path))))
    (when (my/task--feature-worktree-p normalized)
      (unless (gethash normalized my/task-session--title-backfill-pending)
        (puthash normalized t my/task-session--title-backfill-pending)
        (my/git-run-async
       normalized '("rev-parse" "--abbrev-ref" "HEAD")
       :name "task-title-backfill"
       :on-success
       (lambda (output _code)
         (unwind-protect
             (let* ((branch (string-trim output))
                    (task-id (my/task-session--call-repair
                              #'my/worktree-repair-branch-task-id branch))
                    (task-file (and task-id (my/task-note-file task-id))))
               (when (and task-file
                          (equal (my/task-note-status task-file) "todo")
                          (my/task--feature-worktree-p normalized))
                 (my/task-index-worktree-set task-id normalized)
                 (my/task-session--notify task-id
                                          :changes '(:worktree)
                                          :worktree normalized)))
           (my/task-session--title-backfill-finish normalized)))
       :on-error
       (lambda (_code _output)
         (my/task-session--title-backfill-finish normalized)))))))

(defun my/task-session-title-from-path (path)
  "Derive task title from PATH under ~/work/.
Avoid synchronous git in the task-title path; use transient indexed worktree
ownership when available and trigger asynchronous backfill when it is missing."
  (if-let* ((worktree-path (my/task-session-worktree-root-from-path path))
            (task-id (my/task-index-find-by-worktree worktree-path))
            (task-file (my/task-note-file task-id)))
      (or (my/task-note-title task-file)
          (buffer-name))
    (when-let ((worktree-path (my/task-session-worktree-root-from-path path)))
      (my/task-session--queue-title-backfill worktree-path))
    (buffer-name)))

(cl-defun my/task-session-prepare-work-async (task-id &key resume-state on-success on-error)
  "Prepare task TASK-ID for work asynchronously.
When RESUME-STATE is Pi-backed and the task note records a worktree name,
require that exact worktree for strict Pi resume."
  (let ((file (my/task-note-file task-id)))
    (unless file
      (when on-error
        (funcall on-error (format "Task not found: %s" task-id)))
      (cl-return-from my/task-session-prepare-work-async))
    (let* ((status (my/task-status file))
           (owner-repo (my/task-owner-repo file))
           (owner (car owner-repo))
           (repo (cdr owner-repo))
           (branch (my/task-branch task-id))
           (claimed (my/task-session--call-repair
                     #'my/worktree-repair-claimed-worktrees-for-pickup))
           (existing-worktree (let ((path (my/task-worktree task-id)))
                                (and path
                                     (my/task--feature-worktree-p path)
                                     path)))
           (pinned-pi-worktree
            (my/task-session--pinned-pi-worktree task-id owner repo branch claimed existing-worktree resume-state)))
      (cond
       ((equal status "done")
        (when on-error
          (funcall on-error "Task is already done")))
       ((equal status "discarded")
        (when on-error
          (funcall on-error "Task is discarded")))
       ((not (equal status "todo"))
        (when on-error
          (funcall on-error (format "Unknown task status: %s" status))))
       ((plist-get pinned-pi-worktree :error)
        (when on-error
          (funcall on-error (plist-get pinned-pi-worktree :error))))
       ((and (plist-get pinned-pi-worktree :path)
             existing-worktree
             (not (equal (plist-get pinned-pi-worktree :path) existing-worktree)))
        (when on-error
          (funcall on-error
                   (format "Recorded Pi worktree %s does not match live task worktree %s"
                           (plist-get pinned-pi-worktree :path)
                           existing-worktree))))
       ((plist-get pinned-pi-worktree :path)
        (let ((recorded-wt (plist-get pinned-pi-worktree :path)))
          (my/task-index-worktree-set task-id recorded-wt)
          (my/task-session--notify task-id :changes '(:worktree) :worktree recorded-wt)
          (my/task-session-resume-on-branch-async
           recorded-wt branch
           :on-success
           (lambda ()
             (when on-success
               (funcall on-success
                        (list :worktree recorded-wt
                              :branch branch
                              :task-id task-id
                              :status "todo"))))
           :on-error
           (lambda (err-msg)
             (if (string-prefix-p "branch not found:" err-msg)
                 (my/task-session-setup-worktree-async
                  recorded-wt task-id
                  :on-success
                  (lambda (_new-branch)
                    (when on-success
                      (funcall on-success
                               (list :worktree recorded-wt
                                     :branch branch
                                     :task-id task-id
                                     :status "todo"))))
                  :on-error
                  (lambda (setup-err-msg)
                    (my/task-session-clear-worktree-state task-id)
                    (when on-error
                      (funcall on-error setup-err-msg))))
               (my/task-session-clear-worktree-state task-id)
               (when on-error
                 (funcall on-error err-msg)))))))
       (existing-worktree
        (my/task-index-worktree-set task-id existing-worktree)
        (when on-success
          (funcall on-success
                   (list :worktree existing-worktree
                         :branch branch
                         :task-id task-id
                         :status "todo"))))
       (t
        (message "Preparing task... (allocating worktree)")
        (my/hephaestus-allocate-async
         owner repo branch
         :fetch t
         :on-success
         (lambda (allocated-worktree)
           (my/task-index-worktree-set task-id allocated-worktree)
           (my/task-session--notify task-id :changes '(:worktree) :worktree allocated-worktree)
           (if (my/task-session-reset-wip task-id allocated-worktree)
               (progn
                 (message "Task ready: %s" branch)
                 (when on-success
                   (funcall on-success
                            (list :worktree allocated-worktree
                                  :branch branch
                                  :task-id task-id
                                  :status "todo"))))
             (my/task-session-clear-worktree-state task-id)
             (when on-error
               (funcall on-error
                        (format "Failed to reset WIP commit in %s"
                                allocated-worktree)))))
         :on-error
         (lambda (err-msg)
           (my/task-session-clear-worktree-state task-id)
           (when on-error
             (funcall on-error err-msg)))))))))

(cl-defun my/task-session-command-pickup (&optional task &key launch-config advanced-options interactive-p)
  "Pick up (start or resume) work on a task."
  (let ((task-id (my/task-resolve-id task)))
    (unless task-id
      (user-error "Could not resolve task: %s" task))
    (my/task-session-pickup-start-async
     task-id
     :launch-config launch-config
     :advanced-options advanced-options
     :restore-session t
     :interactive-p interactive-p
     :on-success
     (lambda (result)
       (when-let ((msg (my/task-session--pickup-unusable-message
                        (plist-get result :unusable-worktrees))))
         (message "%s" msg)))
     :on-error
     (lambda (err-msg)
       (message "Task pickup failed: %s"
                (my/task-session--pickup-error-message err-msg))))))

(defun my/task-session-command-exit (&optional task)
  "Pause TASK, checkpointing local work before releasing its worktree."
  (let* ((task-id (my/task-resolve-id task))
         (file (and task-id (my/task-note-file task-id))))
    (unless task-id
      (user-error "Could not resolve task: %s" task))
    (unless file
      (user-error "Task file not found for: %s" task-id))
    (let ((worktree (my/task-worktree-repairing task-id))
          (title (or (my/task-note-title file) (file-name-base file))))
      (if worktree
          (let ((checkpointed (my/task-session--checkpoint-wip task-id worktree)))
            (my/task-session-clear-buffer task-id)
            (my/task-session-release task-id worktree)
            (message "%s: %s"
                     (if checkpointed
                         "Task checkpointed and exited"
                       "Task exited")
                     title))
        (my/task-session-prune-stale task-id 'missing-worktree)
        (user-error "No worktree found for task %s — cannot detach" task-id)))))

(provide 'my-task-session)
;;; my-task-session.el ends here
