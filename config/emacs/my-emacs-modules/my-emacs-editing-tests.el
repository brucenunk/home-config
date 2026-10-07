;;; my-emacs-editing-tests.el --- Tests for editing defaults -*- lexical-binding: t -*-

;;; Commentary:

;; Regression coverage for editing defaults.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'my-emacs-editing)

(defun my/editing-test-misspellings ()
  "Return misspelled words after fontifying and checking the current buffer."
  (font-lock-ensure)
  ;; Exercise the real packaged module and its exclusions, not a stub checker.
  ;; Checking synchronously avoids depending on idle timers in batch Emacs.
  (jinx--check-region (point-min) (point-max))
  (sort (mapcar (lambda (overlay)
                 (buffer-substring-no-properties
                  (overlay-start overlay) (overlay-end overlay)))
               (jinx--get-overlays (point-min) (point-max)))
        #'string<))

(ert-deftest my/jinx-configuration ()
  (require 'jinx)
  (should (equal (default-value 'jinx-languages) "en_AU"))
  (should (eq (key-binding (kbd "M-$")) #'jinx-correct))
  (should (eq (key-binding (kbd "C-M-$")) #'jinx-languages))
  (should (memq #'jinx-mode text-mode-hook))
  (should (memq #'jinx-mode prog-mode-hook))
  (with-temp-buffer
    (fundamental-mode)
    (should-not (bound-and-true-p jinx-mode))))

(ert-deftest my/jinx-text-and-org-exclusions ()
  (with-temp-buffer
    (insert "Correct prose zqxprosetypo https://example.test/zqxurltypo\n")
    (text-mode)
    (should jinx-mode)
    (should (equal (my/editing-test-misspellings) '("zqxprosetypo"))))
  (with-temp-buffer
    (insert "Prose zqxorgtypo\n\n"
            "~zqxverbatimtypo~ =zqxinlinecodetypo=\n\n"
            "[[https://example.test/zqxlinktypo][link]]\n\n"
            "#+begin_src emacs-lisp\n"
            "(setq zqxidentifiertypo \"zqxstringtypo\")\n"
            ";; zqxcommenttypo\n#+end_src\n")
    (org-mode)
    (should jinx-mode)
    (should (equal (my/editing-test-misspellings) '("zqxorgtypo")))))

(ert-deftest my/jinx-markdown-exclusions ()
  (require 'markdown-mode)
  (dolist (mode '(markdown-mode gfm-mode))
    (with-temp-buffer
      (insert "Prose zqxmarkdowntypo and `zqxinlinecodetypo`.\n\n"
              "[link](https://example.test/zqxlinktypo)\n\n"
              "![image](zqximagepath.png)\n\n"
              "<https://example.test/zqxurltypo>\n\n"
              "    zqxindentedcodetypo\n\n"
              "```emacs-lisp\n"
              "(setq zqxidentifiertypo \"zqxstringtypo\")\n"
              ";; zqxcommenttypo\n```\n\n"
              "~~~\nzqxuntypedcodetypo\n~~~\n\n"
              "Afterwards zqxaftertypo\n")
      (funcall mode)
      (should jinx-mode)
      (should markdown-fontify-code-blocks-natively)
      (should (equal (my/editing-test-misspellings)
                     '("zqxaftertypo" "zqxmarkdowntypo"))))))

(ert-deftest my/jinx-programming-string-exclusions ()
  (require 'nix-ts-mode)
  (require 'yaml-mode)
  (dolist (fixture '((emacs-lisp-mode .
                      "(setq zqxidentifiertypo \"zqxstringtypo\")\n(defun example () \"zqxdocstringtypo\" nil)\n;; zqxcommenttypo\n")
                     (python-mode .
                      "zqxidentifiertypo = \"zqxstringtypo\"\n# zqxcommenttypo\n")
                     (python-ts-mode .
                      "zqxidentifiertypo = \"zqxstringtypo\"\n# zqxcommenttypo\n")
                     (nix-ts-mode .
                      "{ zqxidentifiertypo = \"zqxstringtypo\"; }\n# zqxcommenttypo\n")
                     (go-ts-mode .
                      "package main\nvar zqxidentifiertypo = \"zqxstringtypo\"\n// zqxcommenttypo\n")
                     (yaml-mode .
                      "zqxidentifiertypo: \"zqxstringtypo\"\n# zqxcommenttypo\n")))
    (with-temp-buffer
      (insert (cdr fixture))
      (funcall (car fixture))
      (should jinx-mode)
      (should (equal (my/editing-test-misspellings)
                     (pcase (car fixture)
                       ('emacs-lisp-mode '("zqxcommenttypo" "zqxdocstringtypo"))
                       ('yaml-mode '("zqxcommenttypo" "zqxstringtypo"))
                       (_ '("zqxcommenttypo"))))))))

(ert-deftest my/jinx-dictionaries-and-language-switching ()
  (with-temp-buffer
    (text-mode)
    (let ((jinx-save-languages nil))
      (dolist (languages '("en_AU" "en_US" "en_AU en_US"))
        (jinx-languages languages)
        (should (= (length jinx--dicts) (length (split-string languages))))
        (should (jinx--word-valid-p "hello"))
        (should-not (jinx--word-valid-p "zqxdictionarytypo")))
      (jinx-languages "en_US")
      (should (jinx--word-valid-p "color"))
      (should-not (jinx--word-valid-p "colour"))
      (jinx-languages "en_AU")
      (should (jinx--word-valid-p "colour"))
      (jinx-languages "en_AU en_US")
      (should (jinx--word-valid-p "colour"))
      (should (jinx--word-valid-p "color")))))

(ert-deftest my/jinx-downstream-default-is-preserved ()
  (require 'jinx)
  (let ((original (default-value 'jinx-languages)))
    (unwind-protect
        (progn
          ;; Same ordering as a consumer's extraConfig after the module loads.
          (with-eval-after-load 'my-emacs-editing
            (setq-default jinx-languages "en_US"))
          (with-temp-buffer
            (text-mode)
            (should (equal jinx-languages "en_US"))
            (should (= (length jinx--dicts) 1))
            (should-not (jinx--word-valid-p "colour"))))
      (setq-default jinx-languages original))))

(ert-deftest my/jinx-global-language-selection ()
  (require 'jinx)
  (let ((original (default-value 'jinx-languages)))
    (unwind-protect
        (progn
          (with-temp-buffer
            (text-mode)
            (jinx-languages "en_US" t)
            (should-not (local-variable-p 'jinx-languages))
            (should-not (jinx--word-valid-p "colour")))
          (with-temp-buffer
            (text-mode)
            (should (equal jinx-languages "en_US"))
            (should-not (jinx--word-valid-p "colour"))))
      (setq-default jinx-languages original))))

(ert-deftest my/jinx-personal-dictionary-is-writable ()
  ;; The isolated test invocation must supply a temporary HOME and XDG config
  ;; directory: never add test words to the user's real personal dictionary.
  (let ((config-home (getenv "XDG_CONFIG_HOME")))
    (should config-home)
    (should (file-in-directory-p config-home temporary-file-directory))
    (with-temp-buffer
      (text-mode)
      (should-not (jinx--word-valid-p "zqxpersonaltestword"))
      (unwind-protect
          (progn
            ;; The correction dispatcher strips the first action key.
            (jinx--save-personal 'add ?@ "zqxpersonaltestword")
            (should (jinx--word-valid-p "zqxpersonaltestword"))
            (let ((dictionary (expand-file-name "enchant/en_AU.dic" config-home)))
              (should (file-writable-p dictionary))
              (with-temp-buffer
                (insert-file-contents dictionary)
                (should (search-forward "zqxpersonaltestword" nil t)))))
        (jinx--save-personal 'remove ?@ "zqxpersonaltestword")))))

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
