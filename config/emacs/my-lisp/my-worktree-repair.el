;;; my-worktree-repair.el --- Worktree safety and recovery helpers -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; Safety helpers for live task/worktree discovery.
;;
;; Durable repo/worktree index recovery has been removed. This module keeps a
;; small compatibility surface for detached-worktree inspection, provenance,
;; explicit recovery operations, and closeout safety checks.

;;; Code:

(require 'cl-lib)
(require 'my-git)
(require 'my-task)
(require 'my-task-index)
(require 'my-task-note)
(require 'my-worktree)
(require 'seq)
(require 'subr-x)

(declare-function my/task-state-notify "my-task" (task-id source &rest props))
(declare-function my/task-branch "my-task" (task-id))
(declare-function my/task-note-file "my-task-note" (task-id))
(declare-function my/task-note-owner-repo "my-task-note" (task))
(declare-function my/task-note-status "my-task-note" (task))
(declare-function my/task-session-clear-worktree-state "my-task-session" (task-id))
(declare-function my/task-session-clear-buffer "my-task-session" (task-id))
(declare-function my/task-session-state-remove "my-task-session" (task))
(declare-function my/task-worktree "my-task" (task))
(declare-function my/task-worktree-repairing "my-task" (task))

(defconst my/worktree-repair--task-id-regexp "[0-9]\\{8\\}T[0-9]\\{6\\}"
  "Regexp matching Denote task ids embedded in branch/reflog text.")

(defun my/worktree-repair--notify (task-id &rest props)
  "Broadcast a repair-originated task-state change for TASK-ID."
  (apply #'my/task-state-notify task-id 'repair props))

(defun my/worktree-repair--call-session (fn &rest args)
  "Load `my-task-session' and call FN with ARGS."
  (require 'my-task-session)
  (apply fn args))

(defun my/worktree-repair-branch-task-id (branch)
  "Return task-id encoded in BRANCH, or nil when BRANCH is not a task branch."
  (when (and (stringp branch)
             (string-match "\\`jamesl-\\([0-9]\\{8\\}T[0-9]\\{6\\}\\)\\'" branch))
    (match-string 1 branch)))

(defun my/worktree-repair--feature-worktree-p (worktree-path)
  "Return non-nil when WORKTREE-PATH names a task-eligible linked worktree.
Repair/forensics paths should keep working even when live worktree registry
queries are unavailable, so this stays path-based rather than requiring
`git worktree list` membership."
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

(defun my/worktree-repair--owner-repo-for-worktree (worktree-path)
  "Return (OWNER . REPO) parsed from WORKTREE-PATH."
  (let* ((normalized (directory-file-name (expand-file-name worktree-path)))
         (repo-dir (directory-file-name (file-name-directory normalized)))
         (owner-dir (directory-file-name (file-name-directory repo-dir))))
    (cons (file-name-nondirectory owner-dir)
          (file-name-nondirectory repo-dir))))

(defun my/worktree-repair--task-matches-worktree-p (task-id owner repo)
  "Return non-nil when TASK-ID is a todo task for OWNER/REPO."
  (when-let ((task-file (my/task-note-file task-id)))
    (and (equal (my/task-note-status task-file) "todo")
         (equal (my/task-note-owner-repo task-file) (cons owner repo)))))

(defun my/worktree-repair--branch-exists-for-repo-p (task-id owner repo)
  "Return non-nil when TASK-ID branch exists for OWNER/REPO."
  (when-let ((default-wt (my/worktree-default-for-repo owner repo)))
    (my/git-success-in-dir-p default-wt "rev-parse" "--verify" (my/task-branch task-id))))

(defun my/worktree-repair--branch-exists-for-worktree-p (task-id worktree-path)
  "Return non-nil when TASK-ID branch exists for WORKTREE-PATH's repo."
  (let* ((owner-repo (my/worktree-repair--owner-repo-for-worktree worktree-path))
         (owner (car owner-repo))
         (repo (cdr owner-repo)))
    (my/worktree-repair--branch-exists-for-repo-p task-id owner repo)))

(defun my/worktree-repair--task-id-from-string (string)
  "Return task-id found in STRING, or nil."
  (when (and (stringp string)
             (string-match (format "\\(?:jamesl-\\|WIP \\\[\\)\\(%s\\)"
                                   my/worktree-repair--task-id-regexp)
                           string))
    (match-string 1 string)))

(defun my/worktree-repair--reflog-lines (worktree-path)
  "Return recent HEAD reflog subjects for WORKTREE-PATH, or nil on error."
  (condition-case _err
      (my/git-lines-in-dir worktree-path "reflog" "--format=%gs" "-n" "40" "HEAD")
    (error nil)))

(defun my/worktree-repair--reflog-task-id (worktree-path owner repo)
  "Return task-id inferred from WORKTREE-PATH detach reflog for OWNER/REPO, or nil."
  (when (my/worktree-repair--feature-worktree-p worktree-path)
    (let ((lines (my/worktree-repair--reflog-lines worktree-path))
          candidate)
      (cl-loop for line in lines
               when (and (string-match
                          (format "\\`checkout: moving from jamesl-\\(%s\\) to HEAD\\'"
                                  my/worktree-repair--task-id-regexp)
                          line)
                         (setq candidate (match-string 1 line))
                         (my/worktree-repair--task-matches-worktree-p candidate owner repo))
               return candidate))))

(defun my/worktree-repair--validated-index-task-id (path owner repo)
  "Return validated transient task-id for detached worktree PATH, or nil."
  (when-let ((task-id (my/task-index-find-by-worktree path)))
    (when (my/worktree-repair--task-matches-worktree-p task-id owner repo)
      task-id)))

(defun my/worktree-repair--worktree-attribution (state owner repo)
  "Return attribution plist for detached/attached worktree STATE in OWNER/REPO."
  (let* ((path (plist-get state :path))
         (branch-task-id (my/worktree-repair-branch-task-id (plist-get state :branch)))
         (validated-branch-task-id (and branch-task-id
                                        (my/worktree-repair--task-matches-worktree-p
                                         branch-task-id owner repo)
                                        branch-task-id))
         (indexed-task-id (and (null validated-branch-task-id)
                               (plist-get state :detached)
                               (my/worktree-repair--validated-index-task-id path owner repo)))
         (reflog-task-id (and (null validated-branch-task-id)
                              (plist-get state :detached)
                              (my/worktree-repair--reflog-task-id path owner repo))))
    (cond
     (validated-branch-task-id
      (list :task-id validated-branch-task-id :attribution 'branch))
     ((and indexed-task-id
           reflog-task-id
           (not (equal indexed-task-id reflog-task-id)))
      (list :task-id nil :attribution nil :conflict t))
     (reflog-task-id
      (list :task-id reflog-task-id :attribution 'reflog))
     (indexed-task-id
      (list :task-id indexed-task-id :attribution 'index))
     (t
      (list :task-id nil :attribution nil)))))

(defun my/worktree-repair--detached-reports-for-task-repo (task-id)
  "Return detached feature-worktree reports for TASK-ID's repo."
  (when-let* ((task-file (my/task-note-file task-id))
              (owner-repo (my/task-note-owner-repo task-file))
              (owner (car owner-repo))
              (repo (cdr owner-repo)))
    (let (reports)
      (dolist (entry (my/worktree-list-for-repo owner repo))
        (let ((path (plist-get entry :path)))
          (when (and (plist-get entry :detached)
                     (my/worktree-repair--feature-worktree-p path))
            (push (my/worktree-repair-detached-worktree-recovery-report path) reports))))
      (nreverse reports))))

;;;###autoload
(defun my/worktree-repair-detached-worktree-recovery-report (worktree-path)
  "Return recovery report plist for WORKTREE-PATH."
  (let* ((state (my/worktree-dirty-state worktree-path))
         (normalized (plist-get state :path))
         (owner-repo (my/worktree-repair--owner-repo-for-worktree normalized))
         (owner (car owner-repo))
         (repo (cdr owner-repo))
         (attribution (my/worktree-repair--worktree-attribution state owner repo)))
    (append
     (list :owner owner
           :repo repo
           :task-id (plist-get attribution :task-id)
           :attribution (plist-get attribution :attribution)
           :reclaimable (and (plist-get state :detached)
                             (plist-get state :dirty)
                             (not (plist-get state :has-untracked))))
     state)))

;;;###autoload
(defun my/worktree-repair-detached-worktree-for-task (task-id)
  "Return detached feature worktree path attributed to TASK-ID, or nil."
  (when-let ((report (seq-find (lambda (candidate)
                                 (equal (plist-get candidate :task-id) task-id))
                               (my/worktree-repair--detached-reports-for-task-repo task-id))))
    (plist-get report :path)))

;;;###autoload
(defun my/worktree-repair-closeout-state (task-id)
  "Return closeout-visible worktree state plist for TASK-ID.
The result contains `:worktree' when a safe live or detached worktree was
attributed to TASK-ID, and `:blocked-reason' plus `:ambiguous-worktrees' when
closeout should fail closed rather than risk orphaning additional task-owned
worktree state. Detached dirty orphans without trustworthy attribution stay in
explicit repair/reclaim territory rather than blocking unrelated task closeout."
  (let* ((attached-worktree (when-let ((path (my/task-worktree-repairing task-id)))
                              (file-name-as-directory (expand-file-name path))))
         (reports (my/worktree-repair--detached-reports-for-task-repo task-id))
         (owned-paths (delete-dups
                       (mapcar (lambda (report)
                                 (plist-get report :path))
                               (seq-filter (lambda (report)
                                             (equal (plist-get report :task-id) task-id))
                                           reports))))
         (dirty-owned-paths (delete-dups
                             (mapcar (lambda (report)
                                       (plist-get report :path))
                                     (seq-filter (lambda (report)
                                                   (and (equal (plist-get report :task-id) task-id)
                                                        (plist-get report :dirty)))
                                                 reports))))
         (remaining-owned (if attached-worktree
                              (seq-remove (lambda (path)
                                            (equal path attached-worktree))
                                          owned-paths)
                            owned-paths))
         (remaining-dirty-owned (if attached-worktree
                                    (seq-remove (lambda (path)
                                                  (equal path attached-worktree))
                                                dirty-owned-paths)
                                  dirty-owned-paths)))
    (cond
     ((> (length remaining-owned) 1)
      (list :worktree nil
            :blocked-reason 'multiple-detached-worktrees
            :ambiguous-worktrees remaining-owned))
     ((and attached-worktree remaining-owned)
      (list :worktree nil
            :blocked-reason 'attached-and-detached-worktrees
            :ambiguous-worktrees (cons attached-worktree remaining-owned)))
     (attached-worktree
      (list :worktree attached-worktree :mode 'attached))
     ((= (length remaining-dirty-owned) 1)
      (list :worktree (car remaining-dirty-owned)
            :mode 'detached))
     ((= (length remaining-owned) 1)
      (list :worktree (car remaining-owned)
            :mode 'detached))
     (t
      (list :worktree nil :mode 'none)))))

;;;###autoload
(defun my/worktree-repair-reclaim-detached-worktree (worktree-path &optional force-untracked)
  "Reclaim detached dirty WORKTREE-PATH and clear transient ownership."
  (let* ((report (my/worktree-repair-detached-worktree-recovery-report worktree-path))
         (normalized (plist-get report :path))
         (task-id (plist-get report :task-id)))
    (unless (plist-get report :detached)
      (user-error "Refusing to reclaim attached worktree %s" normalized))
    (unless (plist-get report :dirty)
      (user-error "Refusing to reclaim clean worktree %s" normalized))
    (when (and (plist-get report :has-untracked)
               (not force-untracked))
      (user-error "Refusing to reclaim %s with untracked files" normalized))
    (let ((result (my/worktree-reclaim normalized force-untracked)))
      (when task-id
        (ignore-errors
          (my/worktree-repair--call-session #'my/task-session-clear-buffer task-id))
        (ignore-errors
          (my/worktree-repair--call-session #'my/task-session-clear-worktree-state task-id))
        (ignore-errors
          (my/worktree-repair--call-session #'my/task-session-state-remove task-id)))
      (append (list :mode 'reclaim
                    :task-id task-id)
              result))))

;;;###autoload
(defun my/worktree-repair-recover-detached-worktree (task-id worktree-path)
  "Recover detached WORKTREE-PATH onto TASK-ID's branch when safe."
  (let* ((report (my/worktree-repair-detached-worktree-recovery-report worktree-path))
         (normalized (plist-get report :path))
         (owner (plist-get report :owner))
         (repo (plist-get report :repo))
         (branch (my/task-branch task-id))
         (reported-task-id (plist-get report :task-id))
         (existing-worktree (my/task-worktree-repairing task-id)))
    (unless (plist-get report :detached)
      (user-error "Refusing to recover non-detached worktree %s" normalized))
    (unless (my/worktree-repair--task-matches-worktree-p task-id owner repo)
      (user-error "Task %s does not match worktree repo %s/%s" task-id owner repo))
    (unless reported-task-id
      (user-error "Worktree %s is not attributed to any task; recover it via explicit forensic/manual flow"
                  normalized))
    (when (not (equal reported-task-id task-id))
      (user-error "Worktree %s is already attributed to task %s"
                  normalized reported-task-id))
    (when (and existing-worktree
               (not (equal (file-name-as-directory (expand-file-name existing-worktree))
                           normalized)))
      (user-error "Task %s is already assigned to %s" task-id existing-worktree))
    (unless (my/worktree-repair--branch-exists-for-worktree-p task-id normalized)
      (user-error "Task branch %s does not exist for %s" branch normalized))
    (pcase-let ((`(,code . ,output)
                 (my/git-run-in-dir normalized "checkout" branch)))
      (unless (zerop code)
        (error "Failed to checkout branch %s in %s: %s"
               branch normalized (string-trim output))))
    (my/task-index-worktree-set task-id normalized)
    (my/worktree-repair--notify task-id :changes '(:worktree) :worktree normalized)
    (append (list :mode 'recover
                  :task-id task-id
                  :branch branch)
            (my/worktree-dirty-state normalized))))

;;;###autoload
(defun my/worktree-repair-entry (task-id)
  "Return transient/live state snapshot for TASK-ID, or nil."
  (when-let ((entry (my/task-index-get task-id)))
    (let ((copy (copy-tree entry)))
      (when-let ((worktree (or (plist-get copy :worktree)
                               (my/task-worktree task-id))))
        (setq copy (plist-put copy :worktree worktree)))
      copy)))

(defun my/worktree-repair-entry-for-pickup (task-id)
  "Return transient/live state snapshot for pickup TASK-ID."
  (or (my/worktree-repair-entry task-id)
      (when-let ((worktree (my/task-worktree task-id)))
        (list :task-id task-id :worktree worktree))))

(defun my/worktree-repair-claimed-worktrees-for-pickup ()
  "Return non-stale transient claimed worktrees for pickup.
This scrubs claims for missing, non-todo, missing-path, or branch-mismatched
worktrees so stale session state does not permanently reduce slot capacity."
  (let (claimed)
    (dolist (entry (my/task-index-entries))
      (let* ((task-id (plist-get entry :task-id))
             (worktree (plist-get entry :worktree))
             (task-file (and task-id (my/task-note-file task-id)))
             (expected-branch (and task-id (my/task-branch task-id)))
             (actual-branch (and worktree
                                 (file-directory-p worktree)
                                 (ignore-errors (my/git-branch worktree)))))
        (cond
         ((or (null worktree)
              (null task-file)
              (not (equal (my/task-note-status task-file) "todo"))
              (not (file-directory-p worktree))
              (not (equal actual-branch expected-branch)))
          (when worktree
            (my/task-index-worktree-clear task-id)))
         (t
          (push worktree claimed)))))
    (nreverse claimed)))

(defun my/worktree-repair-worktree (task-id)
  "Return live or transient worktree path for TASK-ID, or nil."
  (or (my/task-index-worktree task-id)
      (my/task-worktree task-id)))

(provide 'my-worktree-repair)
;;; my-worktree-repair.el ends here
