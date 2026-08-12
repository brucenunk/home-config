;;; my-worktree.el --- Worktree operations -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; Git worktree helper functions.
;;
;; Predicates:
;;   - my/worktree-detached-p — check if worktree has detached HEAD
;;   - my/worktree-clean-p — check if worktree has no uncommitted changes
;;
;; Discovery:
;;   - my/worktree-list-for-repo — list live git worktrees for owner/repo
;;   - my/worktree-attached-for-branch — find the attached worktree for a branch
;;
;; Operations:
;;   - my/worktree-dirty-state — inspect detached-dirty state for a worktree
;;   - my/worktree-reclaim — reset, clean, and detach a worktree for reuse
;;
;; Lookup:
;;   - my/worktree-default — find default branch worktree for current repo
;;   - my/worktree-default-for-repo — find default worktree given owner and repo
;;   - my/worktree-default-for-path — find default worktree given worktree path

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'my-git)

(declare-function magit-toplevel "magit" ())

(defcustom my/worktree-root
  (expand-file-name "~/work/")
  "Root directory containing owner/repo worktrees."
  :type 'directory
  :group 'my-task)

(defun my/worktree--normalize-path (path)
  "Return PATH normalized as an absolute directory name."
  (file-name-as-directory (expand-file-name path)))

(defun my/worktree--repo-dir (owner repo)
  "Return canonical repo directory for OWNER and REPO."
  (expand-file-name (format "%s/%s/" owner repo)
                    (file-name-as-directory my/worktree-root)))

(defun my/worktree--git-managed-p (path)
  "Return non-nil when PATH looks like a git worktree root."
  (let ((git-path (expand-file-name ".git" path)))
    (or (file-directory-p git-path)
        (file-regular-p git-path))))

(defun my/worktree--default-worktree-p (path)
  "Return non-nil when PATH is the shared default worktree root.
The default worktree is the primary clone and therefore has a real `.git'
directory, while linked worktrees have a `.git' file."
  (let ((git-path (expand-file-name ".git" path)))
    (and (file-directory-p path)
         (file-directory-p git-path))))

(defun my/worktree--command-dir (owner repo)
  "Return a live worktree directory suitable for git queries.
Prefers the default branch worktree, then any managed child worktree."
  (or (my/worktree-default-for-repo owner repo)
      (let ((repo-dir (my/worktree--repo-dir owner repo)))
        (when (file-directory-p repo-dir)
          (seq-find #'my/worktree--git-managed-p
                    (directory-files repo-dir t "^[^.].*" t))))))

(defun my/worktree--parse-entry (entry-lines)
  "Parse one `git worktree list --porcelain' ENTRY-LINES plist."
  (let (path branch detached)
    (dolist (line entry-lines)
      (cond
       ((string-prefix-p "worktree " line)
        (setq path (my/worktree--normalize-path
                    (string-remove-prefix "worktree " line))))
       ((string-prefix-p "branch refs/heads/" line)
        (setq branch (string-remove-prefix "branch refs/heads/" line)))
       ((string= line "detached")
        (setq detached t))))
    (when path
      (list :path path
            :branch branch
            :detached (or detached (null branch))))))

(defun my/worktree--parse-porcelain (lines)
  "Return parsed worktree entries from porcelain LINES.
Accept both true porcelain output with blank separators and line lists where
blank lines were dropped earlier in the pipeline."
  (let ((current nil)
        (entries nil))
    (dolist (line lines)
      (cond
       ((string-prefix-p "worktree " line)
        (when current
          (when-let ((entry (my/worktree--parse-entry (nreverse current))))
            (push entry entries)))
        (setq current (list line)))
       ((string-empty-p line)
        (when current
          (when-let ((entry (my/worktree--parse-entry (nreverse current))))
            (push entry entries))
          (setq current nil)))
       (current
        (push line current))))
    (when current
      (when-let ((entry (my/worktree--parse-entry (nreverse current))))
        (push entry entries)))
    (nreverse entries)))

;;;###autoload
(defun my/worktree-list-for-repo (owner repo)
  "Return live git worktree entries for OWNER/REPO.
Each entry is a plist containing at least `:path', `:branch', and
`:detached'."
  (when-let ((dir (my/worktree--command-dir owner repo)))
    (let* ((repo-dir (my/worktree--repo-dir owner repo))
           (entries (my/worktree--parse-porcelain
                     (my/git-lines-in-dir dir "worktree" "list" "--porcelain"))))
      (seq-filter
       (lambda (entry)
         (string-prefix-p (file-name-as-directory repo-dir)
                          (plist-get entry :path)))
       entries))))

;;;###autoload
(defun my/worktree-attached-for-branch (owner repo branch)
  "Return attached worktree path for OWNER/REPO BRANCH, or nil."
  (when-let ((entry (seq-find (lambda (candidate)
                                (and (equal (plist-get candidate :branch) branch)
                                     (not (plist-get candidate :detached))))
                              (my/worktree-list-for-repo owner repo))))
    (plist-get entry :path)))

;;;###autoload
(defun my/worktree-detached-p (worktree-path)
  "Return t if WORKTREE-PATH has a detached HEAD.
Returns nil on git errors."
  (condition-case _
      (let ((branch (car (my/git-lines-in-dir worktree-path "rev-parse" "--abbrev-ref" "HEAD"))))
        (and branch (string= branch "HEAD")))
    (error nil)))

;;;###autoload
(defun my/worktree-clean-p (worktree-path)
  "Return t if WORKTREE-PATH has no uncommitted changes."
  (null (my/git-lines-in-dir worktree-path "status" "--porcelain")))

;;;###autoload
(defun my/worktree-dirty-state (worktree-path)
  "Return detached-dirty inspection plist for WORKTREE-PATH.
The result includes `:path', `:branch', `:detached', `:status-lines',
`:dirty', and `:has-untracked'."
  (let* ((normalized (my/worktree--normalize-path worktree-path))
         (branch (my/git-branch normalized))
         (status-lines (my/git-lines-in-dir normalized "status" "--porcelain"))
         (detached (null branch))
         (has-untracked
          (cl-some (lambda (line)
                     (string-prefix-p "??" line))
                   status-lines)))
    (list :path normalized
          :branch branch
          :detached detached
          :status-lines status-lines
          :dirty (and status-lines t)
          :has-untracked has-untracked)))

;;;###autoload
(defun my/worktree-reclaim (worktree-path &optional force-untracked)
  "Reset, clean, and detach WORKTREE-PATH for reuse.
Refuse to reclaim when untracked files are present unless FORCE-UNTRACKED
is non-nil. Return a detached-dirty inspection plist for the reclaimed
worktree."
  (let* ((state (my/worktree-dirty-state worktree-path))
         (normalized (plist-get state :path)))
    (when (and (plist-get state :has-untracked)
               (not force-untracked))
      (user-error "Refusing to reclaim %s with untracked files" normalized))
    (pcase-let ((`(,reset-code . ,reset-output)
                 (my/git-run-in-dir normalized "reset" "--hard" "HEAD")))
      (unless (zerop reset-code)
        (error "Failed to reset worktree %s: %s" normalized (string-trim reset-output))))
    (pcase-let ((`(,clean-code . ,clean-output)
                 (my/git-run-in-dir normalized "clean" "-fd")))
      (unless (zerop clean-code)
        (error "Failed to clean worktree %s: %s" normalized (string-trim clean-output))))
    (pcase-let ((`(,detach-code . ,detach-output)
                 (my/git-run-in-dir normalized "checkout" "--detach" "--force" "HEAD")))
      (unless (zerop detach-code)
        (error "Failed to detach worktree %s: %s" normalized (string-trim detach-output))))
    (my/worktree-dirty-state normalized)))

;;;###autoload
(defun my/worktree-default-for-repo (owner repo)
  "Return path to the shared default worktree for OWNER/REPO, or nil."
  (let ((repo-dir (my/worktree--repo-dir owner repo)))
    (when (file-directory-p repo-dir)
      (when-let ((path (seq-find #'my/worktree--default-worktree-p
                                 (directory-files repo-dir t "^[^.].*" t))))
        (my/worktree--normalize-path path)))))

;;;###autoload
(defun my/worktree-default-for-path (worktree-path)
  "Find the default branch worktree for WORKTREE-PATH's repository.
Parses the owner/repo components under `my/worktree-root' and returns the
shared primary clone worktree."
  (let* ((clean-path (directory-file-name (expand-file-name worktree-path)))
         (work-root (file-name-as-directory (expand-file-name my/worktree-root)))
         (relative (and (string-prefix-p work-root clean-path)
                        (string-remove-prefix work-root clean-path)))
         (parts (and relative (split-string relative "/" t))))
    (when (and parts (>= (length parts) 2))
      (my/worktree-default-for-repo (nth 0 parts) (nth 1 parts)))))

;;;###autoload
(defun my/worktree-default ()
  "Find the default branch worktree for the current repository.
Returns the shared primary-clone worktree for the repo, whatever its branch
name is."
  (require 'magit)
  (my/worktree-default-for-path (magit-toplevel)))

(provide 'my-worktree)
;;; my-worktree.el ends here
