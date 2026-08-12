;;; my-emacs-editing-tests.el --- Tests for editing defaults -*- lexical-binding: t -*-

;;; Commentary:

;; Regression coverage for read-only-by-default file buffer policy.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'my-emacs-editing)

(ert-deftest my/markdown-follow-file-link-other-window-visits-local-file ()
  (require 'markdown-mode)
  (let ((markdown-open-image-command nil)
        (markdown-translate-filename-function #'identity)
        visited-file)
    (cl-letf (((symbol-function 'find-file-other-window)
               (lambda (file &optional _wildcards)
                 (setq visited-file file))))
      (should (my/markdown-follow-file-link-other-window
               "../notes/target.md#section"))
      (should (equal visited-file "../notes/target.md")))))

(ert-deftest my/markdown-follow-file-link-other-window-defers-non-file-links ()
  (require 'markdown-mode)
  (let ((markdown-open-image-command "open-image")
        (markdown-translate-filename-function #'identity))
    (cl-letf (((symbol-function 'find-file-other-window)
               (lambda (&rest _args)
                 (ert-fail "Unexpected file visit"))))
      (should-not (my/markdown-follow-file-link-other-window
                   "https://example.com/notes.md"))
      (should-not (my/markdown-follow-file-link-other-window "diagram.png"))
      (should-not (my/markdown-follow-file-link-other-window "#section")))))

(ert-deftest my/markdown-file-link-handler-is-registered ()
  (require 'markdown-mode)
  (should (memq #'my/markdown-follow-file-link-other-window
                markdown-follow-link-functions)))

(ert-deftest my/global-read-only-file-buffers-enable-makes-ordinary-file-read-only ()
  (let* ((temp-dir (make-temp-file "my-editing-test" t))
         (file (expand-file-name "ordinary.txt" temp-dir))
         (my/global-read-only-file-buffers-writable-directories nil))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "content\n"))
          (with-temp-buffer
            (setq buffer-file-name file)
            (my/global-read-only-file-buffers-enable)
            (should buffer-read-only)))
      (delete-directory temp-dir t))))

(ert-deftest my/global-read-only-file-buffers-enable-keeps-task-files-writable ()
  (let* ((temp-dir (make-temp-file "my-editing-test" t))
         (tasks-dir (expand-file-name "tasks/" temp-dir))
         (file (expand-file-name "20260507T130729==todo--sample.md" tasks-dir))
         (my/global-read-only-file-buffers-writable-directories (list tasks-dir)))
    (unwind-protect
        (progn
          (make-directory tasks-dir t)
          (with-temp-file file
            (insert "---\ntitle: Sample\n---\n"))
          (with-temp-buffer
            (setq buffer-file-name file
                  buffer-read-only t)
            (my/global-read-only-file-buffers-enable)
            (should-not buffer-read-only)))
      (delete-directory temp-dir t))))

(ert-deftest my/global-read-only-file-buffers-enable-keeps-editor-files-writable ()
  (let* ((temp-dir (make-temp-file "my-editing-test" t))
         (file (expand-file-name "COMMIT_EDITMSG" temp-dir))
         (my/global-read-only-file-buffers-writable-directories nil))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "commit message\n"))
          (with-temp-buffer
            (setq buffer-file-name file
                  buffer-read-only t)
            (my/global-read-only-file-buffers-enable)
            (should-not buffer-read-only)))
      (delete-directory temp-dir t))))

(provide 'my-emacs-editing-tests)
;;; my-emacs-editing-tests.el ends here
