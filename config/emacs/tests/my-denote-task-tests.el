;;; my-denote-task-tests.el --- Tests for follow-up file identity -*- lexical-binding: t -*-

;;; Code:

(require 'ert)
(require 'my-denote-task)

(defmacro my/denote-task-test--with-directory (&rest body)
  "Run BODY with an isolated follow-up root, without a machine catalogue."
  (declare (indent 0) (debug t))
  `(let ((root (make-temp-file "denote-follow-up-" t)))
     (unwind-protect
         (cl-letf (((symbol-function 'my/denote-task-directory) (lambda () root)))
           ,@body)
       (delete-directory root t))))

(ert-deftest my/denote-task-file-p-recognizes-existing-notes-without-mutating-them ()
  (my/denote-task-test--with-directory
    (let* ((file (expand-file-name "20260324T103418==done--legacy.org" root))
           (contents "#+title: Legacy\n#+repo: example/project\n\n* Dependencies\n\n- [ ] [[denote:20260324T103419][Old task]]\n"))
      (with-temp-file file (insert contents))
      (with-temp-buffer
        (setq-local buffer-file-name file)
        (should (my/denote-task-file-p)))
      (with-temp-buffer
        (insert-file-contents file)
        (should (equal (buffer-string) contents))))))

(ert-deftest my/denote-task-file-p-rejects-non-denote-files ()
  (my/denote-task-test--with-directory
    (with-temp-buffer
      (should-not (my/denote-task-file-p))
      (dolist (name '("ordinary.org" "20261022T100000==todo--old-task.md"))
        (setq-local buffer-file-name (expand-file-name name root))
        (should-not (my/denote-task-file-p))))))

(ert-deftest my/denote-task-directory-is-under-docs ()
  (should (equal (my/denote-task-directory)
                 (expand-file-name "~/work/docs/tasks/"))))

(ert-deftest my/denote-task-file-p-is-independent-of-global-denote-root ()
  (my/denote-task-test--with-directory
    (let ((denote-directory (file-name-directory root)))
      (dolist (name '("20261022T100000--unsigned.org"
                      "epic/20261022T100001==todo--legacy.org"))
        (let ((file (expand-file-name name root)))
          (make-directory (file-name-directory file) t)
          (write-region "" nil file nil 'silent)
          (with-temp-buffer
            (setq-local buffer-file-name file)
            (should (my/denote-task-file-p)))))
      (with-temp-buffer
        (setq-local buffer-file-name
                    (expand-file-name "20261022T100002--regular-note.org" denote-directory))
        (should-not (my/denote-task-file-p))))))

(ert-deftest my/denote-task-identity-does-not-load-capture-or-catalogue ()
  (should-not (fboundp 'my/denote-task))
  (should-not (featurep 'my-agent-catalogue)))

(provide 'my-denote-task-tests)
;;; my-denote-task-tests.el ends here