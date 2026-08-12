;;; my-worktree-repair-tests.el --- Tests for worktree safety and recovery helpers -*- lexical-binding: t -*-

;;; Commentary:

;; Focused detached-worktree safety coverage.

;;; Code:

(require 'my-task-test-support)
(require 'my-worktree-repair)

(declare-function my/task-session-clear-worktree-state "my-task-session" (task-id))

(ert-deftest my/worktree-repair-detached-worktree-recovery-report-includes-task-id-and-reclaimability ()
  (cl-letf (((symbol-function 'my/worktree-dirty-state)
             (lambda (_worktree)
               '(:path "/Users/jamesl/work/brucenunk/home-config/e/"
                 :branch nil
                 :detached t
                 :status-lines (" M file.el")
                 :dirty t
                 :has-untracked nil)))
            ((symbol-function 'my/task-index-find-by-worktree)
             (lambda (_path)
               nil))
            ((symbol-function 'my/git-lines-in-dir)
             (lambda (dir &rest args)
               (should (equal dir "/Users/jamesl/work/brucenunk/home-config/e/"))
               (should (equal args '("reflog" "--format=%gs" "-n" "40" "HEAD")))
               '("checkout: moving from jamesl-20260327T192220 to HEAD")))
            ((symbol-function 'my/task-note-file)
             (lambda (_task-id)
               "/tmp/task.md"))
            ((symbol-function 'my/task-note-status)
             (lambda (_task-file)
               "todo"))
            ((symbol-function 'my/task-note-owner-repo)
             (lambda (_task-file)
               '("brucenunk" . "home-config"))))
    (let ((report (my/worktree-repair-detached-worktree-recovery-report
                   "/Users/jamesl/work/brucenunk/home-config/e")))
      (should (equal (plist-get report :owner) "brucenunk"))
      (should (equal (plist-get report :repo) "home-config"))
      (should (equal (plist-get report :task-id) "20260327T192220"))
      (should (eq (plist-get report :attribution) 'reflog))
      (should (plist-get report :reclaimable)))))

(ert-deftest my/worktree-repair-detached-worktree-recovery-report-falls-back-to-reflog-provenance ()
  (cl-letf (((symbol-function 'my/worktree-dirty-state)
             (lambda (_worktree)
               '(:path "/Users/jamesl/work/brucenunk/home-config/e/"
                 :branch nil
                 :detached t
                 :status-lines (" M file.el")
                 :dirty t
                 :has-untracked nil)))
            ((symbol-function 'my/task-index-find-by-worktree)
             (lambda (_path)
               nil))
            ((symbol-function 'my/git-lines-in-dir)
             (lambda (dir &rest args)
               (should (equal dir "/Users/jamesl/work/brucenunk/home-config/e/"))
               (should (equal args '("reflog" "--format=%gs" "-n" "40" "HEAD")))
               '("checkout: moving from jamesl-20260327T192220 to HEAD")))
            ((symbol-function 'my/task-note-file)
             (lambda (_task-id)
               "/tmp/task.md"))
            ((symbol-function 'my/task-note-status)
             (lambda (_task-file)
               "todo"))
            ((symbol-function 'my/task-note-owner-repo)
             (lambda (_task-file)
               '("brucenunk" . "home-config"))))
    (let ((report (my/worktree-repair-detached-worktree-recovery-report
                   "/Users/jamesl/work/brucenunk/home-config/e")))
      (should (equal (plist-get report :task-id) "20260327T192220"))
      (should (eq (plist-get report :attribution) 'reflog)))))

(ert-deftest my/worktree-repair-detached-worktree-recovery-report-ignores-generic-reflog-task-mentions ()
  (cl-letf (((symbol-function 'my/worktree-dirty-state)
             (lambda (_worktree)
               '(:path "/Users/jamesl/work/brucenunk/home-config/e/"
                 :branch nil
                 :detached t
                 :status-lines (" M file.el")
                 :dirty t
                 :has-untracked nil)))
            ((symbol-function 'my/task-index-find-by-worktree)
             (lambda (_path)
               nil))
            ((symbol-function 'my/git-lines-in-dir)
             (lambda (_dir &rest _args)
               '("commit: WIP [20260327T192220] checkpoint before exit"
                 "checkout: moving from main to jamesl-20260327T192220")))
            ((symbol-function 'my/task-note-file)
             (lambda (_task-id)
               "/tmp/task.md"))
            ((symbol-function 'my/task-note-status)
             (lambda (_task-file)
               "todo"))
            ((symbol-function 'my/task-note-owner-repo)
             (lambda (_task-file)
               '("brucenunk" . "home-config"))))
    (let ((report (my/worktree-repair-detached-worktree-recovery-report
                   "/Users/jamesl/work/brucenunk/home-config/e")))
      (should-not (plist-get report :task-id))
      (should-not (plist-get report :attribution)))))

(ert-deftest my/worktree-repair-detached-worktree-recovery-report-ignores-invalid-index-claim ()
  (cl-letf (((symbol-function 'my/worktree-dirty-state)
             (lambda (_worktree)
               '(:path "/Users/jamesl/work/brucenunk/home-config/e/"
                 :branch nil
                 :detached t
                 :status-lines (" M file.el")
                 :dirty t
                 :has-untracked nil)))
            ((symbol-function 'my/task-index-find-by-worktree)
             (lambda (_path)
               "20260327T192220"))
            ((symbol-function 'my/task-note-file)
             (lambda (_task-id)
               "/tmp/task.md"))
            ((symbol-function 'my/task-note-status)
             (lambda (_task-file)
               "done"))
            ((symbol-function 'my/task-note-owner-repo)
             (lambda (_task-file)
               '("brucenunk" . "home-config"))))
    (let ((report (my/worktree-repair-detached-worktree-recovery-report
                   "/Users/jamesl/work/brucenunk/home-config/e")))
      (should-not (plist-get report :task-id))
      (should-not (plist-get report :attribution)))))

(ert-deftest my/worktree-repair-detached-worktree-recovery-report-ignores-invalid-branch-attribution ()
  (cl-letf (((symbol-function 'my/worktree-dirty-state)
             (lambda (_worktree)
               '(:path "/Users/jamesl/work/brucenunk/home-config/e/"
                 :branch "jamesl-20260327T192220"
                 :detached nil
                 :status-lines nil
                 :dirty nil
                 :has-untracked nil)))
            ((symbol-function 'my/task-note-file)
             (lambda (_task-id)
               "/tmp/task.md"))
            ((symbol-function 'my/task-note-status)
             (lambda (_task-file)
               "done"))
            ((symbol-function 'my/task-note-owner-repo)
             (lambda (_task-file)
               '("brucenunk" . "home-config"))))
    (let ((report (my/worktree-repair-detached-worktree-recovery-report
                   "/Users/jamesl/work/brucenunk/home-config/e")))
      (should-not (plist-get report :task-id))
      (should-not (plist-get report :attribution)))))

(ert-deftest my/worktree-repair-reclaim-detached-worktree-clears-transient-session-state ()
  (let (session-calls)
    (cl-letf (((symbol-function 'my/worktree-dirty-state)
               (lambda (_worktree)
                 '(:path "/Users/jamesl/work/brucenunk/home-config/e/"
                   :branch nil
                   :detached t
                   :status-lines (" M file.el")
                   :dirty t
                   :has-untracked nil)))
              ((symbol-function 'my/task-index-find-by-worktree)
               (lambda (_path)
                 nil))
              ((symbol-function 'my/git-lines-in-dir)
               (lambda (_dir &rest _args)
                 '("checkout: moving from jamesl-20260327T192220 to HEAD")))
              ((symbol-function 'my/task-note-file)
               (lambda (_task-id)
                 "/tmp/task.md"))
              ((symbol-function 'my/task-note-status)
               (lambda (_task-file)
                 "todo"))
              ((symbol-function 'my/task-note-owner-repo)
               (lambda (_task-file)
                 '("brucenunk" . "home-config")))
              ((symbol-function 'my/worktree-repair--call-session)
               (lambda (fn task-id)
                 (push (list fn task-id) session-calls)))
              ((symbol-function 'my/worktree-reclaim)
               (lambda (path &optional _force-untracked)
                 (should (equal path "/Users/jamesl/work/brucenunk/home-config/e/"))
                 '(:path "/Users/jamesl/work/brucenunk/home-config/e/"
                   :branch nil
                   :detached t
                   :status-lines nil
                   :dirty nil
                   :has-untracked nil))))
      (let ((result (my/worktree-repair-reclaim-detached-worktree
                     "/Users/jamesl/work/brucenunk/home-config/e")))
        (should (equal (nreverse session-calls)
                       '((my/task-session-clear-buffer "20260327T192220")
                         (my/task-session-clear-worktree-state "20260327T192220")
                         (my/task-session-state-remove "20260327T192220"))))
        (should (eq (plist-get result :mode) 'reclaim))
        (should (equal (plist-get result :task-id) "20260327T192220"))
        (should-not (plist-get result :dirty))))))

(ert-deftest my/worktree-repair-reclaim-detached-worktree-refuses-untracked-by-default ()
  (cl-letf (((symbol-function 'my/worktree-dirty-state)
             (lambda (_worktree)
               '(:path "/Users/jamesl/work/brucenunk/home-config/e/"
                 :branch nil
                 :detached t
                 :status-lines ("?? new-file.el")
                 :dirty t
                 :has-untracked t))))
    (should-error (my/worktree-repair-reclaim-detached-worktree
                   "/Users/jamesl/work/brucenunk/home-config/e")
                  :type 'user-error)))

(ert-deftest my/worktree-repair-recover-detached-worktree-attaches-branch-attributed-task-branch ()
  (my/task-index-test--with-isolated-index
    (let ((checkout-calls nil)
          (notify-events nil)
          (dirty-state-calls 0))
      (cl-letf (((symbol-function 'my/worktree-dirty-state)
                 (lambda (_worktree)
                   (setq dirty-state-calls (1+ dirty-state-calls))
                   (if (= dirty-state-calls 1)
                       '(:path "/Users/jamesl/work/brucenunk/home-config/e/"
                         :branch "jamesl-20260327T192220"
                         :detached t
                         :status-lines (" M file.el")
                         :dirty t
                         :has-untracked nil)
                     '(:path "/Users/jamesl/work/brucenunk/home-config/e/"
                       :branch "jamesl-20260327T192220"
                       :detached nil
                       :status-lines (" M file.el")
                       :dirty t
                       :has-untracked nil))))
                ((symbol-function 'my/task-note-file)
                 (lambda (_task-id)
                   "/tmp/task.md"))
                ((symbol-function 'my/task-note-file)
                 (lambda (_task-id)
                   "/tmp/task.md"))
                ((symbol-function 'my/task-note-status)
                 (lambda (_task-file)
                   "todo"))
                ((symbol-function 'my/task-note-owner-repo)
                 (lambda (_task-file)
                   '("brucenunk" . "home-config")))
                ((symbol-function 'my/task-worktree-repairing)
                 (lambda (_task-id)
                   nil))
                ((symbol-function 'my/task-index-find-by-worktree)
                 (lambda (_path)
                   nil))
                ((symbol-function 'my/worktree-default-for-path)
                 (lambda (_path)
                   "/Users/jamesl/work/brucenunk/home-config/main/"))
                ((symbol-function 'my/git-success-in-dir-p)
                 (lambda (dir &rest args)
                   (should (equal dir "/Users/jamesl/work/brucenunk/home-config/main/"))
                   (should (equal args '("rev-parse" "--verify" "jamesl-20260327T192220")))
                   t))
                ((symbol-function 'my/git-run-in-dir)
                 (lambda (dir &rest args)
                   (setq checkout-calls (cons (cons dir args) checkout-calls))
                   '(0 . "")))
                ((symbol-function 'my/task-state-notify)
                 (lambda (task-id source &rest props)
                   (push (append (list :task-id task-id :source source) props)
                         notify-events))))
        (let ((result (my/worktree-repair-recover-detached-worktree
                       "20260327T192220"
                       "/Users/jamesl/work/brucenunk/home-config/e")))
          (should (equal (cdr (car checkout-calls))
                         '("checkout" "jamesl-20260327T192220")))
          (should (equal (plist-get (my/task-index-get "20260327T192220") :worktree)
                         "/Users/jamesl/work/brucenunk/home-config/e/"))
          (should (equal (plist-get result :branch) "jamesl-20260327T192220"))
          (should (eq (plist-get result :mode) 'recover))
          (should-not (plist-get result :detached))
          (should (equal (plist-get (car notify-events) :task-id) "20260327T192220")))))))

(ert-deftest my/worktree-repair-recover-detached-worktree-attaches-reflog-attributed-task-branch ()
  (my/task-index-test--with-isolated-index
    (let ((checkout-calls nil))
      (cl-letf (((symbol-function 'my/worktree-dirty-state)
                 (lambda (_worktree)
                   '(:path "/Users/jamesl/work/brucenunk/home-config/e/"
                     :branch nil
                     :detached t
                     :status-lines (" M file.el")
                     :dirty t
                     :has-untracked nil)))
                ((symbol-function 'my/task-note-file)
                 (lambda (_task-id)
                   "/tmp/task.md"))
                ((symbol-function 'my/task-note-status)
                 (lambda (_task-file)
                   "todo"))
                ((symbol-function 'my/task-note-owner-repo)
                 (lambda (_task-file)
                   '("brucenunk" . "home-config")))
                ((symbol-function 'my/task-worktree-repairing)
                 (lambda (_task-id)
                   nil))
                ((symbol-function 'my/task-index-find-by-worktree)
                 (lambda (_path)
                   nil))
                ((symbol-function 'my/git-lines-in-dir)
                 (lambda (_dir &rest _args)
                   '("checkout: moving from jamesl-20260327T192220 to HEAD")))
                ((symbol-function 'my/worktree-default-for-repo)
                 (lambda (_owner _repo)
                   "/Users/jamesl/work/brucenunk/home-config/main/"))
                ((symbol-function 'my/git-success-in-dir-p)
                 (lambda (_dir &rest _args)
                   t))
                ((symbol-function 'my/git-run-in-dir)
                 (lambda (dir &rest args)
                   (push (cons dir args) checkout-calls)
                   '(0 . "")))
                ((symbol-function 'my/task-state-notify)
                 (lambda (&rest _args)
                   nil)))
        (let ((result (my/worktree-repair-recover-detached-worktree
                       "20260327T192220"
                       "/Users/jamesl/work/brucenunk/home-config/e")))
          (should (equal (cdr (car checkout-calls))
                         '("checkout" "jamesl-20260327T192220")))
          (should (equal (plist-get result :task-id) "20260327T192220")))))))

(ert-deftest my/worktree-repair-recover-detached-worktree-refuses-unattributed-worktree ()
  (cl-letf (((symbol-function 'my/worktree-dirty-state)
             (lambda (_worktree)
               '(:path "/Users/jamesl/work/brucenunk/home-config/e/"
                 :branch nil
                 :detached t
                 :status-lines (" M file.el")
                 :dirty t
                 :has-untracked nil)))
            ((symbol-function 'my/task-note-file)
             (lambda (_task-id)
               "/tmp/task.md"))
            ((symbol-function 'my/task-note-status)
             (lambda (_task-file)
               "todo"))
            ((symbol-function 'my/task-note-owner-repo)
             (lambda (_task-file)
               '("brucenunk" . "home-config")))
            ((symbol-function 'my/task-worktree-repairing)
             (lambda (_task-id)
               nil))
            ((symbol-function 'my/git-lines-in-dir)
             (lambda (_dir &rest _args)
               nil)))
    (should-error (my/worktree-repair-recover-detached-worktree
                   "20260327T192220"
                   "/Users/jamesl/work/brucenunk/home-config/e")
                  :type 'user-error)))

(ert-deftest my/worktree-repair-recover-detached-worktree-refuses-worktree-attributed-to-different-task ()
  (cl-letf (((symbol-function 'my/worktree-dirty-state)
             (lambda (_worktree)
               '(:path "/Users/jamesl/work/brucenunk/home-config/e/"
                 :branch "jamesl-20260327T192220"
                 :detached t
                 :status-lines (" M file.el")
                 :dirty t
                 :has-untracked nil)))
            ((symbol-function 'my/task-note-file)
             (lambda (_task-id)
               "/tmp/task.md"))
            ((symbol-function 'my/task-note-status)
             (lambda (_task-file)
               "todo"))
            ((symbol-function 'my/task-note-owner-repo)
             (lambda (_task-file)
               '("brucenunk" . "home-config")))
            ((symbol-function 'my/task-worktree-repairing)
             (lambda (_task-id)
               nil)))
    (should-error (my/worktree-repair-recover-detached-worktree
                   "20260414T215613"
                   "/Users/jamesl/work/brucenunk/home-config/e")
                  :type 'user-error)))

(ert-deftest my/worktree-repair-claimed-worktrees-for-pickup-returns-transient-claims ()
  (my/task-index-test--with-isolated-index
    (my/task-index-put "20260324T103418" (list :worktree "/tmp/a/"))
    (my/task-index-put "20260324T103419" (list :active t))
    (cl-letf (((symbol-function 'my/task-note-file)
               (lambda (task-id)
                 (and (equal task-id "20260324T103418")
                      "/tmp/task.md")))
              ((symbol-function 'my/task-note-status)
               (lambda (task-file)
                 (should (equal task-file "/tmp/task.md"))
                 "todo"))
              ((symbol-function 'file-directory-p)
               (lambda (path)
                 (equal path "/tmp/a/")))
              ((symbol-function 'my/git-branch)
               (lambda (path)
                 (should (equal path "/tmp/a/"))
                 "jamesl-20260324T103418")))
      (should (equal (my/worktree-repair-claimed-worktrees-for-pickup)
                     '("/tmp/a/"))))))

(ert-deftest my/worktree-repair-closeout-state-finds-reflog-attributed-detached-worktree ()
  (cl-letf (((symbol-function 'my/task-worktree-repairing)
             (lambda (_task-id)
               nil))
            ((symbol-function 'my/task-note-file)
             (lambda (_task-id)
               "/tmp/task.md"))
            ((symbol-function 'my/task-note-owner-repo)
             (lambda (_task-file)
               '("brucenunk" . "home-config")))
            ((symbol-function 'my/worktree-default-for-repo)
             (lambda (_owner _repo)
               "/Users/jamesl/work/brucenunk/home-config/main/"))
            ((symbol-function 'my/git-success-in-dir-p)
             (lambda (_dir &rest _args)
               t))
            ((symbol-function 'my/worktree-list-for-repo)
             (lambda (_owner _repo)
               (list (list :path "/Users/jamesl/work/brucenunk/home-config/e/"
                           :detached t))))
            ((symbol-function 'my/worktree-dirty-state)
             (lambda (_worktree)
               '(:path "/Users/jamesl/work/brucenunk/home-config/e/"
                 :branch nil
                 :detached t
                 :status-lines (" M file.el")
                 :dirty t
                 :has-untracked nil)))
            ((symbol-function 'my/task-index-find-by-worktree)
             (lambda (_path)
               nil))
            ((symbol-function 'my/git-lines-in-dir)
             (lambda (_dir &rest _args)
               '("checkout: moving from jamesl-20260327T192220 to HEAD")))
            ((symbol-function 'my/task-note-file)
             (lambda (_task-id)
               "/tmp/task.md"))
            ((symbol-function 'my/task-note-status)
             (lambda (_task-file)
               "todo")))
    (let ((state (my/worktree-repair-closeout-state "20260327T192220")))
      (should (equal (plist-get state :worktree)
                     "/Users/jamesl/work/brucenunk/home-config/e/"))
      (should (eq (plist-get state :mode) 'detached)))))

(ert-deftest my/worktree-repair-closeout-state-keeps-single-clean-detached-task-worktree-visible ()
  (cl-letf (((symbol-function 'my/task-worktree-repairing)
             (lambda (_task-id)
               nil))
            ((symbol-function 'my/task-note-file)
             (lambda (_task-id)
               "/tmp/task.md"))
            ((symbol-function 'my/task-note-owner-repo)
             (lambda (_task-file)
               '("brucenunk" . "home-config")))
            ((symbol-function 'my/worktree-list-for-repo)
             (lambda (_owner _repo)
               (list (list :path "/Users/jamesl/work/brucenunk/home-config/e/"
                           :detached t))))
            ((symbol-function 'my/worktree-dirty-state)
             (lambda (_worktree)
               '(:path "/Users/jamesl/work/brucenunk/home-config/e/"
                 :branch nil
                 :detached t
                 :status-lines nil
                 :dirty nil
                 :has-untracked nil)))
            ((symbol-function 'my/task-index-find-by-worktree)
             (lambda (_path)
               nil))
            ((symbol-function 'my/git-lines-in-dir)
             (lambda (_dir &rest _args)
               '("checkout: moving from jamesl-20260327T192220 to HEAD")))
            ((symbol-function 'my/task-note-status)
             (lambda (_task-file)
               "todo")))
    (let ((state (my/worktree-repair-closeout-state "20260327T192220")))
      (should (equal (plist-get state :worktree)
                     "/Users/jamesl/work/brucenunk/home-config/e/"))
      (should (eq (plist-get state :mode) 'detached)))))

(ert-deftest my/worktree-repair-closeout-state-ignores-unattributed-detached-dirty-worktree ()
  (cl-letf (((symbol-function 'my/task-worktree-repairing)
             (lambda (_task-id)
               nil))
            ((symbol-function 'my/task-note-file)
             (lambda (_task-id)
               "/tmp/task.md"))
            ((symbol-function 'my/task-note-owner-repo)
             (lambda (_task-file)
               '("brucenunk" . "home-config")))
            ((symbol-function 'my/worktree-list-for-repo)
             (lambda (_owner _repo)
               (list (list :path "/Users/jamesl/work/brucenunk/home-config/e/"
                           :detached t))))
            ((symbol-function 'my/worktree-dirty-state)
             (lambda (_worktree)
               '(:path "/Users/jamesl/work/brucenunk/home-config/e/"
                 :branch nil
                 :detached t
                 :status-lines (" M file.el")
                 :dirty t
                 :has-untracked nil)))
            ((symbol-function 'my/task-index-find-by-worktree)
             (lambda (_path)
               nil))
            ((symbol-function 'my/git-lines-in-dir)
             (lambda (_dir &rest _args)
               nil))
            ((symbol-function 'my/task-note-status)
             (lambda (_task-file)
               "todo")))
    (let ((state (my/worktree-repair-closeout-state "20260327T192220")))
      (should-not (plist-get state :blocked-reason))
      (should-not (plist-get state :worktree))
      (should (eq (plist-get state :mode) 'none)))))

(ert-deftest my/worktree-repair-closeout-state-dedupes-same-path-attached-and-detached-state ()
  (cl-letf (((symbol-function 'my/task-worktree-repairing)
             (lambda (_task-id)
               "/Users/jamesl/work/brucenunk/home-config/e/"))
            ((symbol-function 'my/task-note-file)
             (lambda (_task-id)
               "/tmp/task.md"))
            ((symbol-function 'my/task-note-owner-repo)
             (lambda (_task-file)
               '("brucenunk" . "home-config")))
            ((symbol-function 'my/worktree-list-for-repo)
             (lambda (_owner _repo)
               (list (list :path "/Users/jamesl/work/brucenunk/home-config/e/"
                           :detached t))))
            ((symbol-function 'my/worktree-dirty-state)
             (lambda (_worktree)
               '(:path "/Users/jamesl/work/brucenunk/home-config/e/"
                 :branch nil
                 :detached t
                 :status-lines (" M file.el")
                 :dirty t
                 :has-untracked nil)))
            ((symbol-function 'my/task-index-find-by-worktree)
             (lambda (_path)
               nil))
            ((symbol-function 'my/git-lines-in-dir)
             (lambda (_dir &rest _args)
               '("checkout: moving from jamesl-20260327T192220 to HEAD")))
            ((symbol-function 'my/task-note-status)
             (lambda (_task-file)
               "todo")))
    (let ((state (my/worktree-repair-closeout-state "20260327T192220")))
      (should-not (plist-get state :blocked-reason))
      (should (equal (plist-get state :worktree)
                     "/Users/jamesl/work/brucenunk/home-config/e/"))
      (should (eq (plist-get state :mode) 'attached)))))

(ert-deftest my/worktree-repair-closeout-state-blocks-when-attached-and-detached-task-worktrees-exist ()
  (cl-letf (((symbol-function 'my/task-worktree-repairing)
             (lambda (_task-id)
               "/Users/jamesl/work/brucenunk/home-config/b/"))
            ((symbol-function 'my/task-note-file)
             (lambda (_task-id)
               "/tmp/task.md"))
            ((symbol-function 'my/task-note-owner-repo)
             (lambda (_task-file)
               '("brucenunk" . "home-config")))
            ((symbol-function 'my/worktree-default-for-repo)
             (lambda (_owner _repo)
               "/Users/jamesl/work/brucenunk/home-config/main/"))
            ((symbol-function 'my/git-success-in-dir-p)
             (lambda (_dir &rest _args)
               t))
            ((symbol-function 'my/worktree-list-for-repo)
             (lambda (_owner _repo)
               (list (list :path "/Users/jamesl/work/brucenunk/home-config/e/"
                           :detached t))))
            ((symbol-function 'my/worktree-dirty-state)
             (lambda (_worktree)
               '(:path "/Users/jamesl/work/brucenunk/home-config/e/"
                 :branch nil
                 :detached t
                 :status-lines (" M file.el")
                 :dirty t
                 :has-untracked nil)))
            ((symbol-function 'my/task-index-find-by-worktree)
             (lambda (_path)
               nil))
            ((symbol-function 'my/git-lines-in-dir)
             (lambda (_dir &rest _args)
               '("checkout: moving from jamesl-20260327T192220 to HEAD")))
            ((symbol-function 'my/task-note-status)
             (lambda (_task-file)
               "todo")))
    (let ((state (my/worktree-repair-closeout-state "20260327T192220")))
      (should (eq (plist-get state :blocked-reason)
                  'attached-and-detached-worktrees))
      (should (equal (plist-get state :ambiguous-worktrees)
                     '("/Users/jamesl/work/brucenunk/home-config/b/"
                       "/Users/jamesl/work/brucenunk/home-config/e/"))))))

(ert-deftest my/worktree-repair-claimed-worktrees-for-pickup-prunes-stale-non-todo-claims ()
  (my/task-index-test--with-isolated-index
    (my/task-index-put "20260324T103418" (list :worktree "/tmp/a/"))
    (let (cleared)
      (cl-letf (((symbol-function 'my/task-note-file)
                 (lambda (_task-id)
                   "/tmp/task.md"))
                ((symbol-function 'my/task-note-status)
                 (lambda (_task-file)
                   "done"))
                ((symbol-function 'my/task-index-worktree-clear)
                 (lambda (task-id &optional _persist)
                   (setq cleared task-id))))
        (should-not (my/worktree-repair-claimed-worktrees-for-pickup))
        (should (equal cleared "20260324T103418"))))))

(ert-deftest my/worktree-repair-claimed-worktrees-for-pickup-prunes-branch-mismatched-claims ()
  (my/task-index-test--with-isolated-index
    (my/task-index-put "20260324T103418" (list :worktree "/tmp/a/"))
    (let (cleared)
      (cl-letf (((symbol-function 'my/task-note-file)
                 (lambda (_task-id)
                   "/tmp/task.md"))
                ((symbol-function 'my/task-note-status)
                 (lambda (_task-file)
                   "todo"))
                ((symbol-function 'file-directory-p)
                 (lambda (path)
                   (equal path "/tmp/a/")))
                ((symbol-function 'my/git-branch)
                 (lambda (path)
                   (should (equal path "/tmp/a/"))
                   "jamesl-20260324T999999"))
                ((symbol-function 'my/task-index-worktree-clear)
                 (lambda (task-id &optional _persist)
                   (setq cleared task-id))))
        (should-not (my/worktree-repair-claimed-worktrees-for-pickup))
        (should (equal cleared "20260324T103418"))))))

(provide 'my-worktree-repair-tests)
;;; my-worktree-repair-tests.el ends here
