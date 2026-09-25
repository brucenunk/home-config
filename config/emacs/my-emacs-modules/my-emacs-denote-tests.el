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

(provide 'my-emacs-denote-tests)
;;; my-emacs-denote-tests.el ends here
