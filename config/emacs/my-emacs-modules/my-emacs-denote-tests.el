;;; my-emacs-denote-tests.el --- Tests for Denote configuration -*- lexical-binding: t -*-

;;; Commentary:

;; Regression coverage for reusable Denote content templates.

;;; Code:

(require 'ert)
(require 'my-emacs-denote)

(ert-deftest my/denote-ordinary-note-defaults-to-org-with-native-identity ()
  (let* ((root (make-temp-file "denote-org-note-" t))
         (denote-directory root)
         note-buffer)
    (unwind-protect
        (let ((file (denote "Ordinary note" nil nil nil nil 'empty nil
                            "20261030T110000")))
          (setq note-buffer (find-buffer-visiting file))
          (should (equal (file-name-extension file) "org"))
          (with-current-buffer note-buffer
            (should (derived-mode-p 'org-mode))
            (should (string-prefix-p "#+title:" (buffer-string)))
            (should (equal (denote-retrieve-front-matter-title-value file 'org)
                           "Ordinary note"))
            (should (equal (denote-retrieve-front-matter-identifier-value file 'org)
                           "20261030T110000"))))
      (when (buffer-live-p note-buffer)
        (with-current-buffer note-buffer (set-buffer-modified-p nil))
        (kill-buffer note-buffer))
      (delete-directory root t))))

(ert-deftest my/denote-task-template-is-content-only ()
  (let ((template (alist-get 'task-workflow-v3 denote-templates)))
    (should (stringp template))
    (dolist (heading '("* Context" "* Goals" "* Non-Goals" "* Constraints"))
      (should (string-match-p (regexp-quote heading) template)))
    (should (equal (alist-get 'task denote-templates) template))
    (should (equal (alist-get 'empty denote-templates) ""))
    (should-not (string-match-p "Dependencies" template))
    (should-not (string-match-p "repo:" template))))

(ert-deftest my/denote-task-binding-releases-old-prefix ()
  (should (eq (keymap-lookup (current-global-map) "C-c n T") #'my/denote-task))
  (should-not (keymap-lookup (current-global-map) "C-c t"))
  (should-not (fboundp 'my/task-add))
  (should-not (fboundp 'my/task-list-start-agent)))

(ert-deftest my/denote-default-directory-covers-documents-and-tasks ()
  (should (equal denote-directory (expand-file-name "~/work/docs/")))
  (should (eq denote-file-type 'org))
  (should (equal denote-dired-directories (list denote-directory)))
  (should denote-dired-directories-include-subdirectories))

(ert-deftest my/denote-auto-revert-is-task-only ()
  (let ((root (make-temp-file "denote-docs-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'my/denote-task-directory)
                   (lambda () (expand-file-name "tasks/" root))))
          (dolist (name '("20261022T100000--note.org"
                          "tasks/20261022T100001--task.org"
                          "tasks/epic/20261022T100002==todo--legacy.org"
                          "tasks/20261022T100003--old-task.md"))
            (let ((file (expand-file-name name root))
                  enabled)
              (make-directory (file-name-directory file) t)
              (write-region "" nil file nil 'silent)
              (with-temp-buffer
                (setq-local buffer-file-name file)
                (cl-letf (((symbol-function 'auto-revert-mode)
                           (lambda (&rest _) (setq enabled t))))
                  (my/denote-task-auto-revert-enable-maybe))
                (should (eq (not (null enabled))
                            (and (string-prefix-p "tasks/" name)
                                 (string-suffix-p ".org" name))))))))
      (delete-directory root t))))

(ert-deftest my/denote-links-resolve-across-documents-and-tasks ()
  (let* ((root (make-temp-file "denote-links-" t))
         (denote-directory root)
         (document (expand-file-name "20261022T110000--design.md" root))
         (task (expand-file-name "tasks/epic/20261022T110001==legacy--task.org" root)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory task) t)
          (write-region "" nil document nil 'silent)
          (write-region "" nil task nil 'silent)
          (should (equal (denote-get-path-by-id "20261022T110000") document))
          (should (equal (denote-get-path-by-id "20261022T110001") task))
          (dolist (file (list document task))
            (should
             (equal (my/denote-link-normalize-file-arg
                     (lambda (target &rest _) target)
                     (file-relative-name file root) 'org "Link")
                    file))
            (dolist (format '(org markdown-yaml))
              (with-temp-buffer
                (setq buffer-file-name (if (eq format 'org) task document))
                (denote-link (file-relative-name file root) format "Link")
                (should
                 (equal (buffer-string)
                        (if (eq format 'org)
                            (format "[[denote:%s][Link]]" (denote-retrieve-filename-identifier file))
                          (format "[Link](denote:%s)" (denote-retrieve-filename-identifier file)))))))))
      (delete-directory root t))))

(provide 'my-emacs-denote-tests)
;;; my-emacs-denote-tests.el ends here
