;;; my-repo-tests.el --- Tests for live repo/worktree discovery -*- lexical-binding: t -*-

;;; Commentary:

;; Live repo/worktree discovery coverage.

;;; Code:

(require 'my-task-test-support)
(require 'my-repo)
(require 'my-worktree)

(ert-deftest my/repo-list-scans-live-work-tree ()
  (let* ((temp-root (make-temp-file "my-repo-live-tests" t))
         (my/repo-root temp-root)
         (my/worktree-root temp-root)
         (repo-dir (expand-file-name "brucenunk/home-config/" temp-root)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "trunk/.git" repo-dir) t)
          (make-directory (expand-file-name "tasks/epic/" temp-root) t)
          (should (equal (my/repo-list)
                         '(("brucenunk" . "home-config")))))
      (delete-directory temp-root t))))

(ert-deftest my/repo-owner-for-repo-uses-live-scan ()
  (cl-letf (((symbol-function 'my/repo-list)
             (lambda ()
               '(("brucenunk" . "home-config")))))
    (should (equal (my/repo-owner-for-repo "home-config")
                   "brucenunk"))
    (should-error (my/repo-owner-for-repo "missing") :type 'user-error)))

(ert-deftest my/worktree-default-for-repo-detects-shared-primary-clone-with-arbitrary-branch-name ()
  (let* ((temp-root (make-temp-file "my-worktree-default" t))
         (my/worktree-root temp-root)
         (repo-dir (expand-file-name "brucenunk/home-config/" temp-root))
         (trunk-dir (expand-file-name "trunk/" repo-dir))
         (feature-dir (expand-file-name "a/" repo-dir)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" trunk-dir) t)
          (make-directory feature-dir t)
          (with-temp-file (expand-file-name ".git" feature-dir)
            (insert "gitdir: /tmp/shared-gitdir\n"))
          (should (equal (my/worktree-default-for-repo "brucenunk" "home-config")
                         trunk-dir)))
      (delete-directory temp-root t))))

(ert-deftest my/worktree-list-for-repo-parses-git-porcelain-output ()
  (let* ((temp-root (make-temp-file "my-worktree-list" t))
         (my/worktree-root temp-root)
         (repo-dir (expand-file-name "brucenunk/home-config/" temp-root))
         (main-dir (expand-file-name "main/" repo-dir))
         (a-dir (expand-file-name "a/" repo-dir))
         (b-dir (expand-file-name "b/" repo-dir)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" main-dir) t)
          (cl-letf (((symbol-function 'my/git-lines-in-dir)
                     (lambda (dir &rest args)
                       (should (equal dir main-dir))
                       (should (equal args '("worktree" "list" "--porcelain")))
                       (list (format "worktree %s" main-dir)
                             "branch refs/heads/main"
                             ""
                             (format "worktree %s" a-dir)
                             "detached"
                             ""
                             (format "worktree %s" b-dir)
                             "branch refs/heads/jamesl-20260324T103418"
                             ""))))
            (should (equal (my/worktree-list-for-repo "brucenunk" "home-config")
                           (list (list :path main-dir :branch "main" :detached nil)
                                 (list :path a-dir :branch nil :detached t)
                                 (list :path b-dir
                                       :branch "jamesl-20260324T103418"
                                       :detached nil))))))
      (delete-directory temp-root t))))

(ert-deftest my/worktree-list-for-repo-parses-porcelain-when-blank-lines-are-missing ()
  (let* ((temp-root (make-temp-file "my-worktree-list-collapsed" t))
         (my/worktree-root temp-root)
         (repo-dir (expand-file-name "brucenunk/home-config/" temp-root))
         (main-dir (expand-file-name "main/" repo-dir))
         (a-dir (expand-file-name "a/" repo-dir))
         (b-dir (expand-file-name "b/" repo-dir)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" main-dir) t)
          (cl-letf (((symbol-function 'my/git-lines-in-dir)
                     (lambda (_dir &rest _args)
                       (list (format "worktree %s" main-dir)
                             "branch refs/heads/main"
                             (format "worktree %s" a-dir)
                             "detached"
                             (format "worktree %s" b-dir)
                             "branch refs/heads/jamesl-20260414T215613"))))
            (should (equal (my/worktree-list-for-repo "brucenunk" "home-config")
                           (list (list :path main-dir :branch "main" :detached nil)
                                 (list :path a-dir :branch nil :detached t)
                                 (list :path b-dir
                                       :branch "jamesl-20260414T215613"
                                       :detached nil))))))
      (delete-directory temp-root t))))

(provide 'my-repo-tests)
;;; my-repo-tests.el ends here
