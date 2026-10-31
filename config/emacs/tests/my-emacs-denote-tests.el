;;; my-emacs-denote-tests.el --- Tests for Denote configuration -*- lexical-binding: t -*-

;;; Commentary:

;; Regression coverage for Denote startup and reusable content templates.

;;; Code:

(require 'ert)
(require 'my-emacs-denote)

(ert-deftest my/denote-ordinary-note-defaults-to-org-with-native-identity ()
  (let* ((root (make-temp-file "denote-org-note-" t))
         (denote-directory root)
         note-buffer)
    (unwind-protect
        (let ((file (denote "Ordinary note" nil nil nil nil "" nil
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
  (let* ((reader (alist-get 'task-workflow denote-templates))
         (template (funcall reader)))
    (should (functionp reader))
    (should (stringp template))
    (should (equal template "* Context\n\n"))
    (should (equal (mapcar #'car denote-templates) '(task-workflow)))
    (should-not (string-match-p "Dependencies" template))
    (should-not (string-match-p "repo:" template))))

(ert-deftest my/denote-template-reads-requested-file-on-demand ()
  (let ((user-emacs-directory (make-temp-file "denote-templates-" t)))
    (unwind-protect
        (dolist (filename '("task-workflow.org" "technical-note.org"))
          (let ((file (locate-user-emacs-file (concat "denote-templates/" filename))))
            (make-directory (file-name-directory file) t)
            (dolist (body '("* First version\n" "* Revised version\n"))
              (write-region body nil file nil 'silent)
              (should (equal (my/denote-template filename) body))
              (when (equal filename "task-workflow.org")
                (should (equal (funcall (alist-get 'task-workflow denote-templates))
                               body))))))
      (delete-directory user-emacs-directory t))))

(ert-deftest my/denote-extracted-template-inserts-into-org-notes ()
  (let* ((root (make-temp-file "denote-template-note-" t))
         (denote-directory root))
    (unwind-protect
        (let* ((file (denote "Template test" nil 'org nil nil 'task-workflow))
               (buffer (find-buffer-visiting file)))
          (unwind-protect
              (with-current-buffer buffer
                (should (derived-mode-p 'org-mode))
                (should (string-suffix-p (my/denote-template "task-workflow.org")
                                         (buffer-string))))
            (when (buffer-live-p buffer)
              (with-current-buffer buffer (set-buffer-modified-p nil))
              (kill-buffer buffer))))
      (delete-directory root t))))

(ert-deftest my/denote-startup-sorts-all-files-newest-first ()
  (let* ((root (make-temp-file "denote-startup-" t))
         (denote-directory root)
         (my/denote-startup-notes-buffer nil)
         ;; Startup must not depend on interactive settings or prompt history.
         (denote-sort-dired-default-sort-component 'title)
         (denote-sort-component-history '("keywords"))
         (files '("20261030T100000--alpha.org"
                  "tasks/20261031T100000--zulu.org"
                  "20261029T100000--middle.md"))
         notes-buffer)
    (unwind-protect
        (progn
          (dolist (name files)
            (let ((file (expand-file-name name root)))
              (make-directory (file-name-directory file) t)
              (write-region "" nil file nil 'silent)))
          (save-window-excursion
            (let ((original (window-buffer)))
              (setq notes-buffer (my/denote-startup-buffer))
              (should (eq (window-buffer) original))))
          (with-current-buffer notes-buffer
            (should (derived-mode-p 'dired-mode))
            (should (equal denote-sort-dired--last-arguments
                           '("" identifier t nil nil)))
            (should (equal (cdr dired-directory)
                           (list (nth 1 files) (nth 0 files) (nth 2 files)))))
          (should (eq denote-sort-dired-default-sort-component 'title))
          (should (equal denote-sort-component-history '("keywords"))))
      (when (buffer-live-p notes-buffer) (kill-buffer notes-buffer))
      (delete-directory root t))))

(ert-deftest my/denote-startup-falls-back-for-empty-or-missing-directory ()
  (let ((root (make-temp-file "denote-empty-startup-" t))
        (my/denote-startup-notes-buffer nil))
    (unwind-protect
        (dolist (denote-directory (list root (expand-file-name "missing/" root)))
          (should (eq (my/denote-startup-buffer) (get-scratch-buffer-create))))
      (delete-directory root t))))

(ert-deftest my/denote-startup-reuses-refreshes-and-recreates-notes-buffer ()
  (let* ((root (make-temp-file "denote-repeated-startup-" t))
         (denote-directory root)
         (my/denote-startup-notes-buffer nil)
         (old (expand-file-name "20261029T100000--old.org" root))
         (new (expand-file-name "20261030T100000--new.org" root)))
    (unwind-protect
        (progn
          (write-region "" nil old nil 'silent)
          (let ((first (my/denote-startup-buffer)))
            (write-region "" nil new nil 'silent)
            (should (eq (my/denote-startup-buffer) first))
            (with-current-buffer first
              (should (equal (cdr dired-directory)
                             (list (file-name-nondirectory new)
                                   (file-name-nondirectory old)))))
            (kill-buffer first)
            (let ((second (my/denote-startup-buffer)))
              (should (buffer-live-p second))
              (should-not (eq first second))
              (delete-file old)
              (delete-file new)
              (should (eq (my/denote-startup-buffer) (get-scratch-buffer-create)))
              (kill-buffer second))))
      (when (buffer-live-p my/denote-startup-notes-buffer)
        (kill-buffer my/denote-startup-notes-buffer))
      (delete-directory root t))))

(ert-deftest my/denote-startup-preserves-requested-buffers ()
  (let ((noninteractive nil)
        (initial-buffer-choice nil))
    (cl-letf (((symbol-function 'daemonp) (lambda () nil))
              ((symbol-function 'my/denote-startup-buffer)
               (lambda () (ert-fail "Replaced an explicitly requested buffer"))))
      (dolist (mode '(org-mode dired-mode fundamental-mode))
        (with-temp-buffer
          (setq major-mode mode)
          (let ((original (current-buffer)))
            (my/denote-startup)
            (should (eq (current-buffer) original)))))
      (should (eq initial-buffer-choice #'my/denote-startup-buffer)))))

(ert-deftest my/denote-startup-shows-notes-only-on-empty-interactive-startup ()
  (let ((initial-buffer-choice nil)
        (notes (generate-new-buffer " *startup-notes-test*")))
    (unwind-protect
        (save-window-excursion
          (cl-letf (((symbol-function 'my/denote-startup-buffer) (lambda () notes)))
            (dolist (state '((nil nil t) (nil t nil) (t nil nil)))
              (let ((noninteractive (nth 0 state)))
                (cl-letf (((symbol-function 'daemonp) (lambda () (nth 1 state))))
                  (switch-to-buffer (get-scratch-buffer-create))
                  (my/denote-startup)
                  (should (eq (eq (current-buffer) notes) (nth 2 state)))
                  (should (eq initial-buffer-choice #'my/denote-startup-buffer)))))))
      (kill-buffer notes))))

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