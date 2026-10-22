;;; my-emacs-denote-tests.el --- Tests for Denote configuration -*- lexical-binding: t -*-

;;; Commentary:

;; Regression coverage for reusable Denote content templates.

;;; Code:

(require 'ert)
(require 'my-emacs-denote)

(defconst my/denote-test--mermaid-template
  (expand-file-name
   "../../mermaid/themes/neutral.md"
   (file-name-directory (or load-file-name buffer-file-name)))
  "Source of the neutral Mermaid template.")

(ert-deftest my/denote-mermaid-template-follows-yaml-front-matter ()
  (let* ((temp-dir (make-temp-file "my-denote-mermaid-test" t))
         (config-dir (expand-file-name "config" temp-dir))
         (installed-themes (expand-file-name "mermaid/themes" config-dir))
         (denote-directory (expand-file-name "notes" temp-dir))
         (process-environment (copy-sequence process-environment))
         note-buffer)
    (unwind-protect
        (progn
          (make-directory installed-themes t)
          (make-directory denote-directory t)
          (copy-file my/denote-test--mermaid-template
                     (expand-file-name "neutral.md" installed-themes))
          (setenv "XDG_CONFIG_HOME" config-dir)
          (should (eq (alist-get 'mermaid denote-templates)
                      'my/denote--mermaid-template))
          (let* ((path (denote "Mermaid example" nil 'markdown-yaml
                               denote-directory nil 'mermaid nil
                               "20260924T104159"))
                 (template (with-temp-buffer
                             (insert-file-contents my/denote-test--mermaid-template)
                             (buffer-string))))
            (setq note-buffer (find-buffer-visiting path))
            (with-current-buffer note-buffer
              (let ((contents (buffer-string)))
                (should (string-prefix-p "---\n" contents))
                (should (string-match-p "\n---\n\n```mermaid\n---\n"
                                        contents))
                (should (string-suffix-p template contents))))))
      (when (buffer-live-p note-buffer)
        (with-current-buffer note-buffer
          (set-buffer-modified-p nil))
        (kill-buffer note-buffer))
      (delete-directory temp-dir t))))

(ert-deftest my/denote-mermaid-template-uses-neutral-config ()
  (with-temp-buffer
    (insert-file-contents my/denote-test--mermaid-template)
    (should (equal (buffer-string)
                   (concat "```mermaid\n"
                           "---\n"
                           "config:\n"
                           "  look: handDrawn\n"
                           "  theme: neutral\n"
                           "  fontFamily: Verdana\n"
                           "  themeCSS: |\n"
                           "    .cluster-label text,\n"
                           "    .cluster-label span {\n"
                           "      font-size: 20px !important;\n"
                           "      font-weight: 600 !important;\n"
                           "      letter-spacing: 0.02em;\n"
                           "    }\n"
                           "---\n"
                           "flowchart TD\n"
                           "```\n")))))

(ert-deftest my/denote-mermaid-template-has-no-diagram-content ()
  (with-temp-buffer
    (insert-file-contents my/denote-test--mermaid-template)
    (should (search-forward "flowchart TD" nil t))
    (should-not (search-forward "classDef " nil t))
    (should-not (search-forward "-->" nil t))
    (should-not (search-forward "subgraph " nil t))))

(ert-deftest my/denote-task-template-is-content-only ()
  (let ((template (alist-get 'task-workflow-v3 denote-templates)))
    (should (stringp template))
    (dolist (heading '("## Context" "## Goals" "## Non-Goals" "## Constraints"))
      (should (string-match-p (regexp-quote heading) template)))
    (should-not (string-match-p "## Dependencies" template))
    (should-not (string-match-p "repo:" template))))

(ert-deftest my/denote-task-binding-releases-old-prefix ()
  (should (eq (keymap-lookup (current-global-map) "C-c n T") #'my/denote-task))
  (should-not (keymap-lookup (current-global-map) "C-c t"))
  (should-not (fboundp 'my/task-add))
  (should-not (fboundp 'my/task-list-start-agent)))

(ert-deftest my/denote-default-directory-covers-documents-and-tasks ()
  (should (equal denote-directory (expand-file-name "~/work/docs/")))
  (should (equal denote-dired-directories (list denote-directory)))
  (should denote-dired-directories-include-subdirectories))

(ert-deftest my/denote-auto-revert-is-task-only ()
  (let ((root (make-temp-file "denote-docs-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'my/denote-task-directory)
                   (lambda () (expand-file-name "tasks/" root))))
          (dolist (name '("20261022T100000--note.md"
                          "tasks/20261022T100001--task.md"
                          "tasks/epic/20261022T100002==todo--legacy.md"))
            (let ((file (expand-file-name name root))
                  enabled)
              (make-directory (file-name-directory file) t)
              (write-region "" nil file nil 'silent)
              (with-temp-buffer
                (setq-local buffer-file-name file)
                (cl-letf (((symbol-function 'auto-revert-mode)
                           (lambda (&rest _) (setq enabled t))))
                  (my/denote-task-auto-revert-enable-maybe))
                (should (eq (not (null enabled)) (string-prefix-p "tasks/" name)))))))
      (delete-directory root t))))

(ert-deftest my/denote-links-resolve-across-documents-and-tasks ()
  (let* ((root (make-temp-file "denote-links-" t))
         (denote-directory root)
         (document (expand-file-name "20261022T110000--design.md" root))
         (task (expand-file-name "tasks/epic/20261022T110001--task.md" root)))
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
                     (file-relative-name file root) 'markdown-yaml "Link")
                    file))))
      (delete-directory root t))))

(provide 'my-emacs-denote-tests)
;;; my-emacs-denote-tests.el ends here
