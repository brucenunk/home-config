;;; my-emacs-denote-tests.el --- Tests for Denote configuration -*- lexical-binding: t -*-

;;; Commentary:

;; Regression coverage for reusable Denote content templates.

;;; Code:

(require 'ert)
(require 'my-emacs-denote)

(defconst my/denote-test--mermaid-themes
  (expand-file-name
   "../../mermaid/themes"
   (file-name-directory (or load-file-name buffer-file-name)))
  "Source directory of the generated Mermaid templates.")

(ert-deftest my/denote-mermaid-template-follows-yaml-front-matter ()
  (let* ((temp-dir (make-temp-file "my-denote-mermaid-test" t))
         (config-dir (expand-file-name "config" temp-dir))
         (installed-themes (expand-file-name "mermaid/themes" config-dir))
         (source-template
          (expand-file-name "doric-obsidian.md" my/denote-test--mermaid-themes))
         (denote-directory (expand-file-name "notes" temp-dir))
         (custom-enabled-themes '(doric-obsidian))
         (process-environment (copy-sequence process-environment))
         note-buffer)
    (unwind-protect
        (progn
          (make-directory installed-themes t)
          (make-directory denote-directory t)
          (copy-directory my/denote-test--mermaid-themes installed-themes nil t t)
          (setenv "XDG_CONFIG_HOME" config-dir)
          (should (eq (alist-get 'mermaid denote-templates)
                      'my/denote--mermaid-template))
          (let* ((path (denote "Mermaid example" nil 'markdown-yaml
                               denote-directory nil 'mermaid nil
                               "20260924T104159"))
                 (template (with-temp-buffer
                             (insert-file-contents source-template)
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

(ert-deftest my/denote-mermaid-theme-follows-enabled-theme ()
  (let ((custom-enabled-themes '(doric-obsidian doric-marble)))
    (should (eq (my/denote--mermaid-theme) 'doric-obsidian)))
  (let ((custom-enabled-themes '(doric-marble)))
    (should (eq (my/denote--mermaid-theme) 'doric-marble)))
  (let ((custom-enabled-themes '(modus-vivendi)))
    (should (eq (my/denote--mermaid-theme) 'doric-marble))))

(ert-deftest my/denote-mermaid-templates-use-their-doric-palette ()
  (dolist (theme '(doric-marble doric-obsidian))
    (load (locate-library (format "%s-theme" theme)) nil t)
    (let ((palette-colours
           (mapcar (lambda (entry) (downcase (cadr entry)))
                   (symbol-value (intern (format "%s-palette" theme)))))
          template-colours)
      (with-temp-buffer
        (insert-file-contents
         (expand-file-name (format "%s.md" theme)
                           my/denote-test--mermaid-themes))
        (goto-char (point-min))
        (while (re-search-forward "#[[:xdigit:]]\\{6\\}" nil t)
          (push (downcase (match-string 0)) template-colours)))
      (dolist (colour (delete-dups template-colours))
        (should (member colour palette-colours))))))

(ert-deftest my/denote-mermaid-templates-have-no-diagram-content ()
  (dolist (theme '(doric-marble doric-obsidian))
    (with-temp-buffer
      (insert-file-contents
       (expand-file-name (format "%s.md" theme)
                         my/denote-test--mermaid-themes))
      (should (search-forward "flowchart TD" nil t))
      (should (= (how-many "^  classDef ") 11))
      (should-not (search-forward "-->" nil t))
      (should-not (search-forward "subgraph " nil t)))))

(provide 'my-emacs-denote-tests)
;;; my-emacs-denote-tests.el ends here
