;;; my-hephaestus-tests.el --- Tests for hephaestus CLI adapter -*- lexical-binding: t -*-

;;; Commentary:

;; Coverage for the narrow hephaestus adapter.

;;; Code:

(require 'my-task-test-support)

(declare-function my/hephaestus-allocate-async "my-hephaestus"
                  (owner repo branch &rest args))
(declare-function my/hephaestus-release "my-hephaestus" (worktree-path))
(declare-function my/hephaestus-resume-async "my-hephaestus"
                  (worktree-path branch &rest args))

(ert-deftest my/hephaestus-output-path-uses-first-non-empty-line ()
  (require 'my-hephaestus)
  (should (equal (my/hephaestus--output-path "\n/tmp/f/\n/tmp/g/\n")
                 "/tmp/f/"))
  (should-not (my/hephaestus--output-path "\n\n")))

(ert-deftest my/hephaestus-error-message-prefers-trimmed-stderr-then-stdout ()
  (require 'my-hephaestus)
  (should (equal (my/hephaestus--error-message "  stderr boom  " "stdout boom")
                 "stderr boom"))
  (should (equal (my/hephaestus--error-message "   " "  stdout boom  ")
                 "stdout boom"))
  (should (equal (my/hephaestus--error-message "" "")
                 "Hephaestus failed")))

(ert-deftest my/hephaestus-allocate-async-normalizes-worktree-path ()
  (require 'my-hephaestus)
  (let (result)
    (cl-letf (((symbol-function 'my/hephaestus--run-async)
               (lambda (_args &rest args)
                 (funcall (plist-get args :on-success) "/tmp/f\n" ""))))
      (my/hephaestus-allocate-async
       "brucenunk" "home-flake" "jamesl-20260324T103418"
       :fetch t
       :on-success (lambda (worktree)
                     (setq result worktree))
       :on-error (lambda (err-msg)
                   (ert-fail err-msg)))
      (should (equal result "/tmp/f/")))))

(ert-deftest my/hephaestus-resume-async-validates-and-normalizes-returned-worktree ()
  (require 'my-hephaestus)
  (let (result)
    (cl-letf (((symbol-function 'my/hephaestus--run-async)
               (lambda (_args &rest args)
                 (funcall (plist-get args :on-success) "/tmp/f\n" ""))))
      (my/hephaestus-resume-async
       "/tmp/f/" "jamesl-20260324T103418"
       :on-success (lambda (worktree)
                     (setq result worktree))
       :on-error (lambda (err-msg)
                   (ert-fail err-msg)))
      (should (equal result "/tmp/f/")))))

(ert-deftest my/hephaestus-resume-async-rejects-unexpected-worktree ()
  (require 'my-hephaestus)
  (let (error-result)
    (cl-letf (((symbol-function 'my/hephaestus--run-async)
               (lambda (_args &rest args)
                 (funcall (plist-get args :on-success) "/tmp/g/\n" ""))))
      (my/hephaestus-resume-async
       "/tmp/f/" "jamesl-20260324T103418"
       :on-success (lambda (_worktree)
                     (ert-fail "resume should not succeed"))
       :on-error (lambda (err-msg)
                   (setq error-result err-msg)))
      (should (equal error-result
                     "Hephaestus resume returned unexpected worktree /tmp/g/ (expected /tmp/f/)")))))

(ert-deftest my/hephaestus-release-is-idempotent-for-detached-worktrees ()
  (require 'my-hephaestus)
  (let (calls)
    (cl-letf (((symbol-function 'my/hephaestus--run)
               (lambda (&rest args)
                 (push (cons 'hephaestus args) calls)
                 '(:exit-code 1 :stdout "" :stderr "worktree is already detached: /tmp/worktree/")))
              ((symbol-function 'my/worktree-clean-p)
               (lambda (worktree)
                 (push (list 'clean-p worktree) calls)
                 t)))
      (should (my/hephaestus-release "/tmp/worktree/"))
      (should (equal (nreverse calls)
                     '((hephaestus "release" "/tmp/worktree/")
                       (clean-p "/tmp/worktree/")))))))

(ert-deftest my/hephaestus-release-surfaces-errors ()
  (require 'my-hephaestus)
  (cl-letf (((symbol-function 'my/hephaestus--run)
             (lambda (&rest _args)
               '(:exit-code 1 :stdout "" :stderr "refusing to release dirty worktree: /tmp/worktree/"))))
    (should-error (my/hephaestus-release "/tmp/worktree/")
                  :type 'error)))

(provide 'my-hephaestus-tests)
;;; my-hephaestus-tests.el ends here
