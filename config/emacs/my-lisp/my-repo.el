;;; my-repo.el --- Repository lookup helpers -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; Task-facing repo listing and owner lookup derived from the live ~/work tree.
;;
;; Functions:
;;   - my/repo-list — list available repos as (owner . repo) cons cells
;;   - my/repo-list-refresh — compatibility command for live repo discovery
;;   - my/repo-owner-for-repo — find owner for a given repo name

;;; Code:

(require 'seq)
(require 'subr-x)

(defcustom my/repo-root
  (expand-file-name "~/work/")
  "Root directory containing owner/repo worktrees."
  :type 'directory
  :group 'my-task)

(defun my/repo--normalize-root ()
  "Return normalized live repo root."
  (file-name-as-directory (expand-file-name my/repo-root)))

(defun my/repo--default-worktree-p (path)
  "Return non-nil when PATH looks like the shared default worktree root.
The default worktree is the primary clone and therefore has a real `.git'
directory, while linked feature worktrees have a `.git' file."
  (let ((git-path (expand-file-name ".git" path)))
    (and (file-directory-p path)
         (file-directory-p git-path))))

(defun my/repo--repo-visible-p (repo-dir)
  "Return non-nil when REPO-DIR contains a managed default worktree."
  (seq-some #'my/repo--default-worktree-p
            (directory-files repo-dir t "^[^.].*" t)))

(defun my/repo--owner-dirs ()
  "Return candidate owner directories under `my/repo-root'."
  (when-let ((root (my/repo--normalize-root)))
    (when (file-directory-p root)
      (seq-filter
       (lambda (path)
         (and (file-directory-p path)
              (not (member (file-name-nondirectory (directory-file-name path))
                           '("tasks" ".git" ".DS_Store")))))
       (directory-files root t "^[^.].*" t)))))

;;;###autoload
(defun my/repo-list ()
  "Return list of available repos as (OWNER . REPO) cons cells."
  (let (repos)
    (dolist (owner-dir (my/repo--owner-dirs))
      (let ((owner (file-name-nondirectory (directory-file-name owner-dir))))
        (dolist (repo-dir (directory-files owner-dir t "^[^.].*" t))
          (when (and (file-directory-p repo-dir)
                     (my/repo--repo-visible-p repo-dir))
            (push (cons owner
                        (file-name-nondirectory (directory-file-name repo-dir)))
                  repos)))))
    (sort (delete-dups repos)
          (lambda (left right)
            (string< (format "%s/%s" (car left) (cdr left))
                     (format "%s/%s" (car right) (cdr right)))))))

;;;###autoload
(defun my/repo-list-refresh ()
  "Compatibility command for live repo discovery.
Repo listing is derived live, so there is nothing to refresh."
  (interactive)
  (message "Repo list is derived live; no refresh needed."))

;;;###autoload
(defun my/repo-owner-for-repo (repo)
  "Find the owner for REPO using live repo discovery.
Returns owner string. Errors if REPO is found under multiple owners or none."
  (let ((matches (mapcar #'car
                         (seq-filter (lambda (pair)
                                       (string= (cdr pair) repo))
                                     (my/repo-list)))))
    (cond
     ((null matches)
      (user-error "No owner found for repo: %s" repo))
     ((> (length matches) 1)
      (user-error "Repo %s found under multiple owners: %s"
                  repo (string-join matches ", ")))
     (t
      (car matches)))))

(provide 'my-repo)
;;; my-repo.el ends here
