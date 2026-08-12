;;; my-task-index-tests.el --- Tests for transient task state -*- lexical-binding: t -*-

;;; Commentary:

;; Task index transient-state coverage.

;;; Code:

(require 'my-task-test-support)

(ert-deftest my/task-index-put-stores-transient-worktree-state ()
  (my/task-index-test--with-isolated-index
    (let ((task-id "20260324T082728"))
      (my/task-index-put task-id (list :worktree "/tmp/a/") t)
      (let ((entry (my/task-index-get task-id)))
        (should (equal (plist-get entry :worktree) "/tmp/a/"))
        (should (equal (my/task-index-worktree task-id) "/tmp/a/"))))))

(ert-deftest my/task-index-put-normalizes-worktree-paths ()
  (my/task-index-test--with-isolated-index
    (let ((task-id "20260324T082728"))
      (my/task-index-worktree-set task-id "/tmp/a")
      (should (equal (my/task-index-worktree task-id) "/tmp/a/")))))

(ert-deftest my/task-index-clear-prunes-empty-entry ()
  (my/task-index-test--with-isolated-index
    (let ((task-id "20260324T082728"))
      (my/task-index-worktree-set task-id "/tmp/a/")
      (my/task-index-worktree-clear task-id)
      (should-not (my/task-index-get task-id)))))

(ert-deftest my/task-index-find-by-worktree-matches-normalized-paths ()
  (my/task-index-test--with-isolated-index
    (my/task-index-worktree-set "20260324T082728" "/tmp/a")
    (should (equal (my/task-index-find-by-worktree "/tmp/a/")
                   "20260324T082728"))))

(ert-deftest my/task-index-claimed-worktrees-returns-only-live-claims ()
  (my/task-index-test--with-isolated-index
    (my/task-index-worktree-set "20260324T082728" "/tmp/a/")
    (my/task-index-put "20260324T082729" (list :active t))
    (should (equal (my/task-index-claimed-worktrees)
                   '("/tmp/a/")))))

(ert-deftest my/task-index-prune-invalid-removes-bad-task-ids-in-memory ()
  (my/task-index-test--with-isolated-index
    (puthash "not-a-task-id" (list :task-id "not-a-task-id" :worktree "/tmp/a/")
             my/task-index)
    (puthash "20260324T082728" (list :task-id "20260324T082728" :worktree "/tmp/b/")
             my/task-index)
    (should (= (my/task-index-prune-invalid) 1))
    (should-not (gethash "not-a-task-id" my/task-index))
    (should (equal (plist-get (gethash "20260324T082728" my/task-index) :worktree)
                   "/tmp/b/"))))

(provide 'my-task-index-tests)
;;; my-task-index-tests.el ends here
