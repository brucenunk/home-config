;;; my-task.el --- Task management -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (denote "3.0"))

;;; Commentary:

;; Denote-based task management system.
;;
;; Public commands and functions:
;;   - my/task-todo-add — create a new todo task
;;   - my/task-todo-list — list all todo task file paths
;;   - my/task-todo-summary — return total todo task count
;;   - my/task-select — prompt user to select a task
;;   - my/task-owner-from-path — derive owner from a ~/work worktree path
;;   - my/task-owner-repo — resolve owner/repo pair from task metadata
;;   - my/task-owner-repo-snapshot — resolve owner/repo pair from snapshot state before note reads
;;   - my/task-repo-snapshot — resolve repo from snapshot state before note reads
;;   - my/task-repo — get repo name from combined front-matter owner/repo slug
;;   - my/task-owner — get owner from canonical repo metadata or combined front-matter slug
;;   - my/task-owner-snapshot — resolve owner from snapshot state before note reads
;;   - my/task-status — get task status from denote signature
;;   - my/task-skill — get configured task skill from task front-matter
;;   - my/task-session-get — get persisted backend-tagged session metadata
;;   - my/task-session-format — encode backend-tagged session metadata
;;   - my/task-session-parse — parse backend-tagged session metadata
;;   - my/task-session-register-backend-session — persist backend-reported session metadata
;;   - my/task-session-set — persist backend-tagged session metadata
;;   - my/task-session-clear — clear persisted session metadata
;;   - my/task-title — get denote title for a task
;;   - my/task-branch — derive task branch name from identifier
;;   - my/task-session-buffer-name — derive agent session buffer name
;;   - my/task-worktree — get the claimed worktree for a task
;;   - my/task-worktree-repairing — get the repaired worktree path for task commands
;;   - my/task-state-entries-raw — list transient task state entries without UI fallbacks
;;   - my/task-state-entries — list task state entries for UI consumers
;;   - my/task-state-notify — broadcast a task-state change event
;;   - my/task-find-by-branch — find a task note by task branch
;;   - my/task-find-by-worktree — find a task note by worktree path
;;   - my/task-mark-done — rename a task note to done
;;   - my/task-mark-todo — rename a task note to todo
;;   - my/task-mark-discarded — rename a task note to discarded
;;   - my/task-startup-recover-index-async — schedule async recovery of missing startup WIP state
;;   - my/task-finish — finish a task immediately, wiping and releasing its worktree
;;   - my/task-detached-worktree-recovery-report — inspect detached-dirty recovery state
;;   - my/task-reclaim-detached-worktree — reclaim a detached dirty worktree slot
;;   - my/task-recover-detached-worktree — recover a detached worktree to a known task branch
;;   - my/task-discard — discard a task immediately, wiping and releasing its worktree
;;   - my/task-dired-discard — Dired `D' wrapper for explicit discard
;;   - my/task-session-add — add a task to active sessions
;;   - my/task-session-remove — remove a task from active sessions
;;   - my/task-session-active-p — check if a task has an active session
;;   - my/task-session-restore — restore a task session in the selected window
;;   - my/task-current-title — derive task title for the current context
;;   - my/task-list — open the task list UI
;;   - my/tasks-map — shared task command prefix map
;;   - my/task-file-p — check if current buffer is a task file
;;   - my/task-resolve-id — normalize nil, task-id, or file path to task-id
;;   - my/task-file — resolve a task-id to the current task file path
;;   - my/task-pickup-launch-config — derive batch pickup launch options
;;   - my/task-pickup-start-async — asynchronously start or resume a task
;;   - my/task-pickup — start or resume work on a task
;;   - my/task-stash — compatibility command explaining stash removal
;;   - my/task-exit — pause a task, checkpointing local work before releasing its worktree
;;
;; `my-task.el` is the stable facade for task APIs. Heavy session/worktree
;; behavior lives in `my-task-session.el`; indexed state lives in
;; `my-task-index.el`; repair behavior lives in `my-worktree-repair.el`.

;;; Code:

(require 'cl-lib)
(require 'denote)
(require 'my-agent)
(require 'my-git)
(require 'my-task-index)
(require 'my-task-note)
(require 'my-worktree)
(require 'subr-x)

(declare-function denote-retrieve-file-title "denote" (file))
(declare-function denote-retrieve-filename-title "denote" (file))
(declare-function denote-retrieve-front-matter-title-value "denote" (file file-type))

(declare-function dired-get-marked-files "dired" (&optional localp arg filter distinguish-one-marked error))
(declare-function dired-get-filename "dired" (&optional localp no-error-if-not-filep))
(declare-function dired-unmark-all-marks "dired" ())

(declare-function my/task-discard-run "my-task-finish" (task-id))
(declare-function my/task-finish-run "my-task-finish" (task-id))
(declare-function my/task-index-entry "my-task-index" (task-id))
(declare-function my/task-index-get "my-task-index" (task-id))
(declare-function my/task-index-entries "my-task-index")
(declare-function my/task-index-worktree "my-task-index" (task-id))
(declare-function my/task-list-show "my-task-list")

(declare-function my/task-session-clear-buffer "my-task-session" (task-id))
(declare-function my/task-session-command-exit "my-task-session" (&optional task))
(declare-function my/task-session-command-pickup "my-task-session" (&optional task &key launch-config advanced-options interactive-p))
(declare-function my/task-session-current-title "my-task-session" ())
(declare-function my/task-session-ensure-live "my-task-session" (task-id))
(declare-function my/task-session-pickup-launch-config "my-task-session" (&optional advanced-options))
(declare-function my/task-session-pickup-start-async "my-task-session" (task-id &key launch-config advanced-options restore-session interactive-p on-success on-error))
(declare-function my/task-session-prepare-work-async "my-task-session" (task-id &key on-success on-error))
(declare-function my/task-session-release "my-task-session" (task-id &optional worktree))
(declare-function my/task-session-restore-view "my-task-session" (task))
(declare-function my/task-session-resume-on-branch-async "my-task-session" (worktree-path branch &key on-success on-error))
(declare-function my/task-session-setup-worktree-async "my-task-session" (worktree-path task-id &key on-success on-error))
(declare-function my/task-session-stale-reason "my-task-session" (task-id &optional entry))
(declare-function my/task-session-state-active-p "my-task-session" (task))
(declare-function my/task-session-state-add "my-task-session" (task))
(declare-function my/task-session-state-remove "my-task-session" (task))

(declare-function my/worktree-repair-branch-task-id "my-worktree-repair" (branch))
(declare-function my/worktree-repair-detached-worktree-recovery-report "my-worktree-repair" (worktree-path))
(declare-function my/worktree-repair-entry "my-worktree-repair" (task-id))
(declare-function my/worktree-repair-closeout-state "my-worktree-repair" (task-id))
(declare-function my/worktree-repair-reclaim-detached-worktree "my-worktree-repair" (worktree-path &optional force-untracked))
(declare-function my/worktree-repair-recover-detached-worktree "my-worktree-repair" (task-id worktree-path))
(declare-function my/worktree-repair-worktree "my-worktree-repair" (task-id))
(declare-function my/worktree-attached-for-branch "my-worktree" (owner repo branch))

(defvar my/task-state-change-functions nil
  "Hook run after task-visible state changes.
Hook functions receive one EVENT plist.  EVENT includes `:task-id' and
`:source', and may include additional keys such as `:changes' or
`:revert-buffers'.")

(defvar my/task--startup-recovery-running nil
  "Non-nil while async startup worktree recovery is in flight.")

(defvar my/task--startup-recovery-callbacks nil
  "Callbacks waiting for the current async startup worktree recovery result.")

(defvar-keymap my/tasks-map
  :doc "Shared keymap for task command prefixes."
  "a" #'my/task-todo-add
  "l" #'my/task-list
  "p" #'my/task-pickup
  "D" #'my/task-discard
  "X" #'my/task-exit
  "F" #'my/task-finish)

(define-error 'my/task-error "Task error")
(define-error 'my/task-done-error "Task already complete" 'my/task-error)
(define-error 'my/task-discarded-error "Task already discarded" 'my/task-error)
(define-error 'my/task-no-worktree-error "No available worktree" 'my/task-error)
(define-error 'my/task-missing-worktree-error "Task worktree missing" 'my/task-error)

(defun my/task--call-session (fn &rest args)
  "Load `my-task-session' and call FN with ARGS."
  (require 'my-task-session)
  (apply fn args))

(defun my/task--call-repair (fn &rest args)
  "Load `my-worktree-repair' and call FN with ARGS."
  (require 'my-worktree-repair)
  (apply fn args))

(defun my/task--notify-index (task-id &rest props)
  "Broadcast an index-originated task-state change for TASK-ID."
  (apply #'my/task-state-notify task-id 'task-index props))

;;;###autoload
(defun my/task-state-notify (task-id source &rest props)
  "Broadcast a task-state change for TASK-ID from SOURCE with PROPS.
Subscribers receive a single plist containing `:task-id', `:source', and
any additional PROP key/value pairs."
  (run-hook-with-args 'my/task-state-change-functions
                      (append (list :task-id task-id :source source)
                              props)))

(cl-defun my/task--setup-worktree-async (worktree-path task-id &key on-success on-error)
  "Set up WORKTREE-PATH with a fresh task branch for TASK-ID asynchronously."
  (my/task--call-session #'my/task-session-setup-worktree-async
                         worktree-path task-id
                         :on-success on-success
                         :on-error on-error))

(cl-defun my/task--resume-on-branch-async (worktree-path branch &key on-success on-error)
  "Resume work in WORKTREE-PATH by checking out existing BRANCH asynchronously."
  (my/task--call-session #'my/task-session-resume-on-branch-async
                         worktree-path branch
                         :on-success on-success
                         :on-error on-error))

(cl-defun my/task--prepare-for-work-async (task-id &key on-success on-error)
  "Prepare task TASK-ID for work asynchronously."
  (my/task--call-session #'my/task-session-prepare-work-async
                         task-id
                         :on-success on-success
                         :on-error on-error))

;;;###autoload
(defalias 'my/task-todo-add #'my/task-note-todo-add)

;;;###autoload
(defalias 'my/task-todo-list #'my/task-note-todo-list)

;;;###autoload
(defalias 'my/task-todo-summary #'my/task-note-todo-summary)

(defun my/task--owner-repo-from-path (path)
  "Return (OWNER . REPO) derived from PATH under ~/work/, or nil.
Paths under ~/work/tasks/ are task-note paths, not repo worktrees."
  (when path
    (let* ((work-root (file-name-as-directory (expand-file-name "~/work/")))
           (expanded (expand-file-name path))
           (relative (and (string-prefix-p work-root expanded)
                          (string-remove-prefix work-root expanded))))
      (when (and relative
                 (string-match "\\`\\([^/]+\\)/\\([^/]+\\)\\(?:/\\|$\\)" relative))
        (let ((owner (match-string 1 relative))
              (repo (match-string 2 relative)))
          (unless (or (string= owner "tasks")
                      (string= repo "tasks"))
            (cons owner repo)))))))

(defun my/task--owner-from-path (path)
  "Return owner derived from PATH under ~/work/, or nil."
  (car (my/task--owner-repo-from-path path)))

(defun my/task--repo-from-path (path)
  "Return repo derived from PATH under ~/work/, or nil."
  (cdr (my/task--owner-repo-from-path path)))

;;;###autoload
(defalias 'my/task-owner-from-path #'my/task--owner-from-path)

;;;###autoload
(defun my/task-owner-repo (task)
  "Return legacy mixed (OWNER . REPO) lookup for TASK, or nil."
  (or (and (stringp task)
           (my/task--owner-repo-from-path task))
      (my/task-note-owner-repo task)))

;;;###autoload
(defun my/task-repo (task)
  "Return bare repo name for TASK."
  (cdr (my/task-owner-repo task)))

;;;###autoload
(defun my/task-owner (task)
  "Return owner for TASK, or nil."
  (car (my/task-owner-repo task)))

(defun my/task--entry-owner-repo (entry)
  "Return (OWNER . REPO) derived from indexed ENTRY, or nil."
  (when-let ((worktree (plist-get entry :worktree)))
    (my/task--owner-repo-from-path worktree)))

;;;###autoload
(defun my/task-owner-repo-snapshot (task &optional entry)
  "Return (OWNER . REPO) for TASK from snapshot state before note reads."
  (or (my/task--entry-owner-repo entry)
      (when-let* ((task-id (my/task--resolve-id task)))
        (require 'my-task-index)
        (when-let ((indexed-entry (my/task-index-get task-id)))
          (my/task--entry-owner-repo indexed-entry)))
      (and (stringp task)
           (my/task--owner-repo-from-path task))
      (ignore-errors (my/task-note-owner-repo task))))

;;;###autoload
(defun my/task-repo-snapshot (task &optional entry)
  "Return repo for TASK from snapshot state before note reads."
  (cdr (my/task-owner-repo-snapshot task entry)))

;;;###autoload
(defun my/task-owner-snapshot (task &optional entry)
  "Return owner for TASK from snapshot state before note reads."
  (car (my/task-owner-repo-snapshot task entry)))

;;;###autoload
(defalias 'my/task-status #'my/task-note-status)

;;;###autoload
(defalias 'my/task-skill #'my/task-note-skill)

;;;###autoload
(defalias 'my/task-session-get #'my/task-note-session-get)

;;;###autoload
(defalias 'my/task-session-format #'my/task-note-session-format)

;;;###autoload
(defalias 'my/task-session-parse #'my/task-note-session-parse)

;;;###autoload
(defalias 'my/task-session-set #'my/task-note-session-set)

;;;###autoload
(defalias 'my/task-session-register-backend-session #'my/task-note-session-register-backend-session)

;;;###autoload
(defalias 'my/task-session-clear #'my/task-note-session-clear)

;;;###autoload
(defalias 'my/task-title #'my/task-note-title)

;;;###autoload
(defun my/task-session-buffer-name (task-id)
  "Return agent task session buffer name for TASK-ID."
  (my/agent-task-buffer-name task-id))

;;;###autoload
(defun my/task-branch (task-id)
  "Derive branch name from TASK-ID."
  (format "jamesl-%s" task-id))

(defun my/task--branch-task-id (branch)
  "Return task-id encoded in BRANCH, or nil."
  (my/task--call-repair #'my/worktree-repair-branch-task-id branch))

(defun my/task--feature-worktree-p (worktree-path)
  "Return non-nil when WORKTREE-PATH names a task-eligible linked worktree.
This is a cheap path-based check for direct-child linked worktrees under
`~/work/{owner}/{repo}/{worktree}`, excluding the repo's default primary
worktree."
  (let* ((normalized (file-name-as-directory (expand-file-name worktree-path)))
         (work-root (file-name-as-directory (expand-file-name "~/work/")))
         (relative (and (string-prefix-p work-root normalized)
                        (directory-file-name
                         (string-remove-prefix work-root normalized))))
         (parts (and relative (split-string relative "/" t)))
         (owner (nth 0 parts))
         (repo (nth 1 parts))
         (default-worktree (and (= (length parts) 3)
                                (my/worktree-default-for-repo owner repo))))
    (and (= (length parts) 3)
         (not (equal normalized default-worktree)))))

(defun my/task--live-worktree (task-id)
  "Return attached live worktree path for TASK-ID, or nil."
  (when-let* ((task-file (my/task-file task-id))
              (owner-repo (my/task-note-owner-repo task-file))
              (owner (car owner-repo))
              (repo (cdr owner-repo))
              (worktree (my/worktree-attached-for-branch owner repo (my/task-branch task-id))))
    (when (my/task--feature-worktree-p worktree)
      worktree)))

(defun my/task--live-worktree-table (task-files)
  "Return hash table mapping TASK-FILES ids to attached live worktrees.
Worktrees are discovered once per repo to avoid repeated synchronous git scans
in UI read paths."
  (let ((repo-task-ids (make-hash-table :test 'equal))
        (worktrees (make-hash-table :test 'equal)))
    (dolist (task-file task-files)
      (when-let* ((task-id (denote-retrieve-filename-identifier task-file))
                  (owner-repo (my/task-note-owner-repo task-file)))
        (puthash owner-repo
                 (cons task-id (gethash owner-repo repo-task-ids))
                 repo-task-ids)))
    (maphash
     (lambda (owner-repo task-ids)
       (let ((owner (car owner-repo))
             (repo (cdr owner-repo)))
         (dolist (entry (my/worktree-list-for-repo owner repo))
           (when-let* ((path (plist-get entry :path))
                       (branch (plist-get entry :branch))
                       (task-id (my/task--branch-task-id branch)))
             (when (and (my/task--feature-worktree-p path)
                        (member task-id task-ids))
               (puthash task-id path worktrees))))))
     repo-task-ids)
    worktrees))

;;;###autoload
(defun my/task-worktree (task)
  "Return worktree path for TASK, or nil."
  (when-let ((task-id (my/task--resolve-id task)))
    (or (my/task-index-worktree task-id)
        (my/task--live-worktree task-id))))

;;;###autoload
(defun my/task-worktree-repairing (task)
  "Return validated worktree path for TASK, or nil.
Unlike the cheap snapshot accessor, this ignores missing or stale cached paths
and falls back to live branch discovery when possible."
  (when-let ((task-id (my/task--resolve-id task)))
    (let* ((indexed (my/task-index-worktree task-id))
           (expected-branch (my/task-branch task-id)))
      (or (and indexed
               (file-directory-p indexed)
               (equal (my/git-branch indexed) expected-branch)
               indexed)
          (my/task--live-worktree task-id)))))

(defun my/task--state-entry-copy (entry)
  "Return detached copy of transient task state ENTRY."
  (copy-tree entry))

;;;###autoload
(defun my/task-state-entries-raw ()
  "Return detached transient task state entries without UI-only fallbacks."
  (require 'my-task-index)
  (mapcar #'my/task--state-entry-copy (my/task-index-entries)))

;;;###autoload
(defun my/task-state-entries ()
  "Return detached task state entries for UI consumers.
Keep this on cached transient state only so task-list/task-dired refresh paths
avoid synchronous git worktree scans. Schedule async startup backfill in the
background so restart-time WIP state eventually repopulates even when another
task UI entry point is used first."
  (my/task-startup-recover-index-async)
  (my/task-state-entries-raw))

;;;###autoload
(defalias 'my/task-mark-done #'my/task-note-mark-done)

;;;###autoload
(defalias 'my/task-mark-todo #'my/task-note-mark-todo)

;;;###autoload
(defalias 'my/task-mark-discarded #'my/task-note-mark-discarded)

;;;###autoload
(defun my/task-find-by-branch (repo branch)
  "Return Denote task file for REPO and BRANCH, or nil."
  (when-let* ((id (string-remove-prefix "jamesl-" branch))
              (file (my/task-file id)))
    (when (string= (my/task-repo file) repo)
      file)))

;;;###autoload
(defun my/task-find-by-worktree (worktree-path)
  "Return Denote task file for WORKTREE-PATH, or nil."
  (let ((expected-owner-repo (my/task--owner-repo-from-path worktree-path)))
    (or (when-let* ((task-id (my/task-index-find-by-worktree worktree-path))
                    (task-file (my/task-file task-id)))
          (when (or (null expected-owner-repo)
                    (equal (my/task-owner-repo task-file) expected-owner-repo))
            task-file))
        (when (and (my/task--feature-worktree-p worktree-path)
                   (file-directory-p worktree-path))
          (when-let* ((task-id (my/task--branch-task-id
                                (my/git-branch worktree-path)))
                      (task-file (my/task-file task-id)))
            (when (or (null expected-owner-repo)
                      (equal (my/task-owner-repo task-file) expected-owner-repo))
              task-file))))))

;;;###autoload
(defun my/task-select ()
  "Prompt user to select a task from todo tasks."
  (my/task-startup-recover-index-async)
  (let* ((tasks (my/task-todo-list))
         (candidates
         (mapcar
           (lambda (f)
             (let* ((id (denote-retrieve-filename-identifier f))
                    (wip-p (my/task--local-entry id))
                    (title (my/task-title f)))
               (cons (format "%s%s"
                             title
                             (if wip-p " [wip]" ""))
                     id)))
           tasks))
         (selection (completing-read "Task: " candidates nil t)))
    (cdr (assoc selection candidates))))

;;;###autoload
(defun my/task-finish (&optional task)
  "Finish TASK immediately.
This is destructive: it resets, cleans, detaches, and releases the task
worktree before marking the note done."
  (interactive
   (list (my/task--resolve-id nil)))
  (require 'my-task-finish)
  (let ((task-id (my/task--resolve-id task)))
    (unless task-id
      (user-error "Could not resolve task: %s" task))
    (unless (equal (my/task-status task-id) "todo")
      (user-error "Only todo tasks can be finished"))
    (my/task-finish-run task-id)))

(defun my/task--startup-recovery-finish (result)
  "Finish async startup recovery with RESULT and notify queued callbacks."
  (setq my/task--startup-recovery-running nil)
  (let ((callbacks (nreverse my/task--startup-recovery-callbacks)))
    (setq my/task--startup-recovery-callbacks nil)
    (dolist (callback callbacks)
      (when callback
        (funcall callback result)))))

;;;###autoload
(cl-defun my/task-startup-recover-index-async (&key on-complete)
  "Asynchronously backfill transient startup WIP state from live worktrees.
This keeps git scans off synchronous UI reads while restoring attached task
worktrees into transient state shortly after startup."
  (when on-complete
    (push on-complete my/task--startup-recovery-callbacks))
  (unless my/task--startup-recovery-running
    (setq my/task--startup-recovery-running t)
    (run-with-idle-timer
     0 nil
     (lambda ()
       (condition-case err
           (let ((recovered nil)
                 (pruned nil)
                 (live-worktrees (my/task--live-worktree-table (my/task-todo-list))))
             (dolist (entry (my/task-index-entries))
               (let* ((task-id (plist-get entry :task-id))
                      (worktree (plist-get entry :worktree))
                      (expected-branch (and task-id (my/task-branch task-id))))
                 (let ((actual-branch (and worktree
                                           (file-directory-p worktree)
                                           (ignore-errors (my/git-branch worktree)))))
                   (when (and task-id
                              worktree
                              (or (not (file-directory-p worktree))
                                  (and actual-branch
                                       (not (equal actual-branch expected-branch)))))
                     (my/task-index-worktree-clear task-id)
                     (my/task--notify-index task-id :changes '(:worktree) :worktree nil)
                     (push task-id pruned)))))
             (maphash
              (lambda (task-id worktree)
                (unless (equal (my/task-index-worktree task-id) worktree)
                  (my/task-index-worktree-set task-id worktree)
                  (my/task--notify-index task-id :changes '(:worktree) :worktree worktree)
                  (push task-id recovered)))
              live-worktrees)
             (my/task--startup-recovery-finish
              (list :recovered (nconc (nreverse pruned)
                                      (nreverse recovered))
                    :failed nil)))
         (error
          (my/task--startup-recovery-finish
           (list :recovered nil
                 :failed (list (error-message-string err))))))))))

(defun my/task--local-entry (task-id &optional live-worktrees)
  "Return read-only local task entry for todo TASK-ID, or nil.
When LIVE-WORKTREES is non-nil, it should be a hash table mapping task ids to
live attached worktree paths for this read pass. Without that explicit table,
this stays on cached transient state only."
  (when (equal (my/task-status task-id) "todo")
    (or (when-let ((entry (my/task-index-entry task-id)))
          (when (plist-get entry :worktree)
            entry))
        (when-let ((worktree (and live-worktrees
                                  (gethash task-id live-worktrees))))
          (list :task-id task-id :worktree worktree)))))

(defun my/task--task-files-from-paths (paths)
  "Return Denote task files from PATHS, preserving order."
  (delete-dups
   (delq nil
         (mapcar (lambda (file)
                   (when (and (stringp file)
                              (denote-file-is-in-denote-directory-p file)
                              (denote-file-has-denoted-filename-p file))
                     (expand-file-name file)))
                 paths))))

(defun my/task--discard-summary (files)
  "Return discard summary plist for task FILES."
  (let ((live-worktrees (my/task--live-worktree-table files))
        task-ids wip-task-ids plain-task-ids invalid-task-ids)
    (dolist (file files)
      (when-let ((task-id (denote-retrieve-filename-identifier file)))
        (pcase (my/task-status file)
          ("todo"
           (push task-id task-ids)
           (if (or (my/task--local-entry task-id live-worktrees)
                   (let ((closeout-state
                          (my/task--call-repair #'my/worktree-repair-closeout-state task-id)))
                     (or (plist-get closeout-state :worktree)
                         (plist-get closeout-state :blocked-reason))))
               (push task-id wip-task-ids)
             (push task-id plain-task-ids)))
          (_
           (push task-id invalid-task-ids)))))
    (list :task-ids (nreverse task-ids)
          :wip-task-ids (nreverse wip-task-ids)
          :plain-task-ids (nreverse plain-task-ids)
          :invalid-task-ids (nreverse invalid-task-ids))))

(defun my/task--discard-prompt (wip-count plain-count)
  "Return discard confirmation prompt for WIP-COUNT and PLAIN-COUNT."
  (string-join
   (delq nil
         (list
          (format "Discard %d task%s"
                  (+ wip-count plain-count)
                  (if (= (+ wip-count plain-count) 1) "" "s"))
          (when (> wip-count 0)
            (format "(%d WIP)" wip-count))
          (when (> plain-count 0)
            (format "(%d note-only)" plain-count))
          "by renaming them to discarded"
          (when (> wip-count 0)
            "and discarding all worktree changes")
          "Proceed?"))
   " "))

;;;###autoload
(defun my/task-pickup-launch-config (&optional advanced-options)
  "Return pickup launch config plist with :backend and :options."
  (my/task--call-session #'my/task-session-pickup-launch-config advanced-options))

;;;###autoload
(cl-defun my/task-pickup-start-async (task-id &key launch-config advanced-options
                                              restore-session interactive-p
                                              on-success on-error)
  "Prepare TASK-ID for work and optionally restore its workspace."
  (my/task--call-session #'my/task-session-pickup-start-async
                         task-id
                         :launch-config launch-config
                         :advanced-options advanced-options
                         :restore-session restore-session
                         :interactive-p interactive-p
                         :on-success on-success
                         :on-error on-error))

;;;###autoload
(defun my/task-detached-worktree-recovery-report (worktree-path)
  "Return recovery report plist for detached WORKTREE-PATH."
  (interactive "DWorktree: ")
  (my/task--call-repair #'my/worktree-repair-detached-worktree-recovery-report worktree-path))

;;;###autoload
(defun my/task-reclaim-detached-worktree (worktree-path &optional force-untracked)
  "Reclaim detached dirty WORKTREE-PATH for reuse."
  (interactive "DWorktree: \nP")
  (my/task--call-repair #'my/worktree-repair-reclaim-detached-worktree
                        worktree-path force-untracked))

;;;###autoload
(defun my/task-recover-detached-worktree (task worktree-path)
  "Recover detached WORKTREE-PATH to TASK's branch when safe."
  (interactive (list nil (read-directory-name "Worktree: ")))
  (let ((task-id (my/task--resolve-id task)))
    (unless task-id
      (user-error "Could not resolve task: %s" task))
    (my/task--call-repair #'my/worktree-repair-recover-detached-worktree
                          task-id worktree-path)))

;;;###autoload
(defun my/task-dired-discard ()
  "Discard selected tasks from a task Dired buffer."
  (interactive)
  (let* ((files (my/task--task-files-from-paths
                 (dired-get-marked-files nil nil nil t)))
         (summary (my/task--discard-summary files))
         (task-ids (plist-get summary :task-ids))
         (invalid-task-ids (plist-get summary :invalid-task-ids))
         (wip-task-ids (plist-get summary :wip-task-ids))
         (plain-task-ids (plist-get summary :plain-task-ids)))
    (when invalid-task-ids
      (user-error "Selection contains non-todo tasks; use d to delete notes"))
    (unless task-ids
      (user-error "No task at point or in marked files"))
    (when (yes-or-no-p (my/task--discard-prompt (length wip-task-ids)
                                                (length plain-task-ids)))
      (require 'my-task-finish)
      (dired-unmark-all-marks)
      (dolist (task-id task-ids)
        (my/task-discard-run task-id))
      (message "Discarded %d task%s"
               (length task-ids)
               (if (= (length task-ids) 1) "" "s")))))

;;;###autoload
(defun my/task-discard (&optional task)
  "Discard TASK immediately, preserving the note as `discarded'."
  (interactive)
  (require 'my-task-finish)
  (let* ((task-id (my/task--resolve-id task))
         (local-entry (and task-id (my/task--local-entry task-id)))
         (closeout-state (and task-id
                              (my/task--call-repair #'my/worktree-repair-closeout-state task-id)))
         (wip-like (or local-entry
                       (plist-get closeout-state :worktree)
                       (plist-get closeout-state :blocked-reason))))
    (unless task-id
      (user-error "Could not resolve task: %s" task))
    (unless (equal (my/task-status task-id) "todo")
      (user-error "Only todo tasks can be discarded"))
    (unless (yes-or-no-p (my/task--discard-prompt (if wip-like 1 0)
                                                  (if wip-like 0 1)))
      (user-error "Discard aborted"))
    (my/task-discard-run task-id)))

;;;###autoload
(defun my/task-session-add (task)
  "Add TASK to active sessions."
  (my/task--call-session #'my/task-session-state-add task))

;;;###autoload
(defun my/task-session-remove (task)
  "Remove TASK from active sessions."
  (my/task--call-session #'my/task-session-state-remove task))

;;;###autoload
(defun my/task-session-active-p (task)
  "Return non-nil if TASK has an active session."
  (my/task--call-session #'my/task-session-state-active-p task))

;;;###autoload
(defun my/task-session-restore (task)
  "Restore TASK's live session in the selected window."
  (interactive)
  (my/task--call-session #'my/task-session-restore-view task))

;;;###autoload
(defun my/task-current-title ()
  "Return the task title for the current buffer context."
  (my/task--call-session #'my/task-session-current-title))

;;;###autoload
(defun my/task-list ()
  "Open task list, using persisted filter settings."
  (interactive)
  (require 'my-task-list)
  (dolist (dir (denote-directories))
    (make-directory dir t))
  (my/task-list-show))

;;;###autoload
(defun my/task-file-p ()
  "Return non-nil if current buffer is a task file."
  (and buffer-file-name
       (bound-and-true-p denote-directory)
       (denote-file-is-in-denote-directory-p buffer-file-name)))

(defun my/task--resolve-from-context ()
  "Resolve task from context (dired, buffer, prompt) to task-id."
  (cond
   ((derived-mode-p 'dired-mode)
    (when-let ((f (dired-get-filename nil t)))
      (when (denote-file-is-in-denote-directory-p f)
        (denote-retrieve-filename-identifier f))))
   ((and (bound-and-true-p my/task-session-task-id)
         (stringp my/task-session-task-id))
    my/task-session-task-id)
   ((my/task-file-p)
    (denote-retrieve-filename-identifier buffer-file-name))
   (t
    (my/task-select))))

(defun my/task--resolve-id (task)
  "Resolve TASK to task-id string."
  (cond
   ((null task)
    (my/task--resolve-from-context))
   ((and (stringp task)
         (string-match-p "\\`[0-9]\\{8\\}T[0-9]\\{6\\}\\'" task))
    task)
   ((stringp task)
    (denote-retrieve-filename-identifier task))))

;;;###autoload
(defalias 'my/task--get-file #'my/task-note-file)

;;;###autoload
(defun my/task-resolve-id (task)
  "Resolve TASK to task-id string."
  (my/task--resolve-id task))

;;;###autoload
(defalias 'my/task-file #'my/task-note-file)

;;;###autoload
(cl-defun my/task-pickup (&optional task &key launch-config advanced-options)
  "Pick up (start or resume) work on a task.
When called interactively, always prompt for the task to pick up."
  (interactive (list (my/task-select) :advanced-options current-prefix-arg))
  (let ((interactive-p (called-interactively-p 'any)))
    (my/task--call-session #'my/task-session-command-pickup
                           task
                           :launch-config launch-config
                           :advanced-options advanced-options
                           :interactive-p interactive-p)))

;;;###autoload
(defun my/task-stash (&optional task)
  "Explain that task stashing has been removed."
  (interactive)
  (ignore task)
  (user-error "Task stashing has been removed; use another worktree if needed"))

;;;###autoload
(defun my/task-exit (&optional task)
  "Pause TASK, checkpointing local work before releasing its worktree."
  (interactive)
  (my/task--call-session #'my/task-session-command-exit task))

(provide 'my-task)
;;; my-task.el ends here
