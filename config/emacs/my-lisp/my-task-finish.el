;;; my-task-finish.el --- Task closeout helpers -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (denote "3.0") (seq "2.24"))

;;; Commentary:

;; Direct finish/discard closeout helpers.
;;
;; Lifecycle contract:
;;   - `finish` is the user-facing declaration that a task is complete
;;   - `discard` abandons a todo task while preserving the note as `discarded`
;;   - both paths perform destructive worktree cleanup and release the slot for
;;     reuse immediately
;;   - paused-work behavior such as `exit` does not belong here
;;
;; Public functions:
;;   - my/task-finish-run — close out a finished task immediately
;;   - my/task-discard-run — discard a todo task immediately

;;; Code:

(require 'cl-lib)
(require 'denote)
(require 'my-task)
(require 'my-task-index)
(require 'my-task-note)
(require 'my-git)
(require 'my-worktree)
(require 'subr-x)

(declare-function my/task-owner-repo-snapshot "my-task" (task &optional entry))
(declare-function my/task-state-notify "my-task" (task-id source &rest props))
(declare-function my/task-session-clear-buffer "my-task-session" (task-id))
(declare-function my/task-session-release "my-task-session" (task-id &optional worktree))
(declare-function my/task-note-owner-repo "my-task-note" (task))
(declare-function my/task-note-status "my-task-note" (task))
(declare-function my/task-note-todo-list "my-task-note" ())
(declare-function my/worktree-repair-closeout-state "my-worktree-repair" (task-id))

(defun my/task-finish--notify (task-id &rest props)
  "Broadcast a finish-originated task-state change for TASK-ID."
  (apply #'my/task-state-notify task-id 'finish props))

(defun my/task-finish--call-session (fn &rest args)
  "Load `my-task-session' and call FN with ARGS."
  (require 'my-task-session)
  (apply fn args))

(defun my/task-finish--refresh-task-buffer (file)
  "Refresh the visiting buffer for FILE when it is safe to do so."
  (when-let ((buf (get-file-buffer file)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (if (buffer-modified-p)
            (message "Warning: skipping task buffer refresh for %s (unsaved modifications)"
                     (file-name-nondirectory file))
          (condition-case err
              (revert-buffer t t t)
            (error
             (message "Warning: skipping task buffer refresh for %s: %s"
                      (file-name-nondirectory file)
                      (error-message-string err)))))))))

(defun my/task-finish--closeout-worktree-state (task-id)
  "Return safe closeout worktree state for TASK-ID or signal a blocking error."
  (require 'my-worktree-repair)
  (let* ((state (my/worktree-repair-closeout-state task-id))
         (blocked-reason (plist-get state :blocked-reason))
         (ambiguous (plist-get state :ambiguous-worktrees)))
    (when blocked-reason
      (user-error "Cannot close out task %s safely (%s): %s"
                  task-id
                  blocked-reason
                  (mapconcat #'identity ambiguous ", ")))
    state))

(defun my/task-finish--repo-location (&optional task-file)
  "Return (OWNER REPO DEFAULT-WT) using TASK-FILE."
  (let* ((task-id (and task-file (denote-retrieve-filename-identifier task-file)))
         (owner-repo (or (and task-id (my/task-owner-repo-snapshot task-id))
                         (and task-file (my/task-note-owner-repo task-file))))
         (owner (car owner-repo))
         (repo (cdr owner-repo))
         (default-wt (and owner repo (my/worktree-default-for-repo owner repo))))
    (list owner repo default-wt)))

(defun my/task-finish--delete-branch (task-id branch default-wt)
  "Delete BRANCH for TASK-ID from DEFAULT-WT when possible."
  (when (and branch default-wt)
    (pcase-let ((`(,local-code . ,local-out)
                 (my/git-run-in-dir default-wt "rev-parse" "--quiet" "--verify" branch))
                (`(,remote-code . ,remote-out)
                 (my/git-run-in-dir default-wt "rev-parse" "--quiet" "--verify"
                                    (format "refs/remotes/origin/%s" branch))))
      (let ((local-tip (and (zerop local-code) (string-trim local-out)))
            (remote-tip (and (zerop remote-code) (string-trim remote-out))))
        (when (and local-tip remote-tip
                   (not (string-empty-p local-tip))
                   (not (string-empty-p remote-tip))
                   (not (string= local-tip remote-tip)))
          (message "Warning: task %s: local branch %s (%s) differs from origin (%s)"
                   task-id branch (substring local-tip 0 (min 12 (length local-tip)))
                   (substring remote-tip 0 (min 12 (length remote-tip)))))))
    (pcase-let ((`(,code . ,output)
                 (my/git-run-in-dir default-wt "branch" "-D" branch)))
      (cond
       ((zerop code)
        (message "Deleted local branch %s" branch))
       ((string-match-p "not found" output)
        (message "Branch %s already deleted" branch))
       (t
        (message "Warning: could not delete branch %s: %s" branch (string-trim output)))))))

(defun my/task-finish--reset-worktree (worktree)
  "Reset and clean WORKTREE destructively before release."
  (when (and worktree (file-directory-p worktree))
    (pcase-let ((`(,reset-code . ,reset-output)
                 (my/git-run-in-dir worktree "reset" "--hard" "HEAD")))
      (unless (zerop reset-code)
        (error "Failed to reset worktree %s: %s" worktree (string-trim reset-output))))
    (pcase-let ((`(,clean-code . ,clean-output)
                 (my/git-run-in-dir worktree "clean" "-fd")))
      (unless (zerop clean-code)
        (error "Failed to clean worktree %s: %s" worktree (string-trim clean-output))))))

(cl-defun my/task-finish--closeout (task-id transition-fn success-label
                                           &key clear-buffer allow-status
                                           post-transition-fn
                                           transition-before-teardown)
  "Run direct closeout for TASK-ID using TRANSITION-FN.
SUCCESS-LABEL is the past-tense verb used in the success message.
CLEAR-BUFFER clears the live task session buffer before release when non-nil.
ALLOW-STATUS permits an existing non-`todo' task note status to skip
TRANSITION-FN while still completing teardown.
POST-TRANSITION-FN runs after the note transition when one occurred.
TRANSITION-BEFORE-TEARDOWN runs the note transition before destructive
worktree cleanup."
  (let ((task-file (denote-get-path-by-id task-id)))
    (unless task-file
      (error "Task %s: file not found" task-id))
    (let ((task-status (my/task-note-status task-file)))
      (unless (or (equal task-status "todo")
                  (and allow-status (equal task-status allow-status)))
        (error "Task note is %s; cannot %s" task-status success-label))
      (let* ((branch (my/task-branch task-id))
             (closeout-state (my/task-finish--closeout-worktree-state task-id))
             (worktree (plist-get closeout-state :worktree))
             (repo-location (my/task-finish--repo-location task-file))
             (default-wt (nth 2 repo-location))
             (transitioned-file task-file))
        (when clear-buffer
          (my/task-finish--call-session #'my/task-session-clear-buffer task-id))
        (when (and transition-before-teardown
                   (equal task-status "todo"))
          (my/task-finish--refresh-task-buffer task-file)
          (setq transitioned-file (funcall transition-fn task-file))
          (when post-transition-fn
            (funcall post-transition-fn task-id)))
        (my/task-finish--reset-worktree worktree)
        (my/task-finish--call-session #'my/task-session-release task-id worktree)
        (my/task-finish--delete-branch task-id branch default-wt)
        (when (and (not transition-before-teardown)
                   (equal task-status "todo"))
          (my/task-finish--refresh-task-buffer task-file)
          (setq transitioned-file (funcall transition-fn task-file))
          (when post-transition-fn
            (funcall post-transition-fn task-id)))
        (my/task-index-remove task-id)
        (my/task-finish--notify task-id
                                :changes '(:worktree :active)
                                :worktree nil
                                :active nil)
        (message "Task %s: %s"
                 success-label
                 (denote-retrieve-filename-title transitioned-file))))))

(defun my/task-finish--check-off-deps (task-id)
  "Check off TASK-ID in `## Dependencies' sections of all todo tasks.
Scans every todo task file for unchecked dependency lines referencing
TASK-ID (via denote:TASK-ID) and marks them checked.
Skips files that are open in a buffer with unsaved modifications."
  (let ((pattern (regexp-quote (format "denote:%s" task-id)))
        (checked 0))
    (dolist (file (my/task-note-todo-list))
      (let ((buf (get-file-buffer file)))
        (if (and buf (buffer-modified-p buf))
            (message "Warning: skipping dep check-off in %s (unsaved modifications)"
                     (file-name-nondirectory file))
          (with-temp-buffer
            (insert-file-contents file)
            (goto-char (point-min))
            (when (re-search-forward "^## Dependencies$" nil t)
              (let ((section-start (point))
                    (section-end (or (save-excursion
                                       (and (re-search-forward "^## " nil t)
                                            (match-beginning 0)))
                                     (point-max)))
                    (modified nil))
                (goto-char section-start)
                (while (re-search-forward
                        (format "^- \\[ \\] \\(.*%s.*\\)$" pattern)
                        section-end t)
                  (replace-match "- [x] \\1")
                  (setq modified t)
                  (cl-incf checked))
                (when modified
                  (write-region (point-min) (point-max) file nil 'silent)
                  (when buf
                    (with-current-buffer buf
                      (revert-buffer t t t))))))))))
    (when (> checked 0)
      (message "Checked off %d dependenc%s on task %s"
               checked (if (= checked 1) "y" "ies") task-id))))

;;;###autoload
(defun my/task-finish-run (task-id)
  "Close out TASK-ID immediately.
This resets, cleans, detaches, and releases the task worktree before marking
the note done."
  (my/task-finish--closeout task-id
                            #'my/task-mark-done
                            "finished"
                            :post-transition-fn #'my/task-finish--check-off-deps))

;;;###autoload
(defun my/task-discard-run (task-id)
  "Discard TASK-ID immediately.
This marks the note discarded, then resets, cleans, detaches, and releases
the task worktree."
  (my/task-finish--closeout task-id
                            #'my/task-mark-discarded
                            "discarded"
                            :clear-buffer t
                            :allow-status "discarded"
                            :transition-before-teardown t))

(provide 'my-task-finish)
;;; my-task-finish.el ends here
