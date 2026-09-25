;;; my-emacs-editing-tests.el --- Tests for editing defaults -*- lexical-binding: t -*-

;;; Commentary:

;; Regression coverage for editing defaults.

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

(ert-deftest my/editing-ordinary-file-opens-writable ()
  (let ((file (make-temp-file "my-editing-test")))
    (unwind-protect
        (let ((buffer (find-file-noselect file)))
          (unwind-protect
              (with-current-buffer buffer
                (should-not buffer-read-only))
            (kill-buffer buffer)))
      (delete-file file))))

(provide 'my-emacs-editing-tests)
;;; my-emacs-editing-tests.el ends here
