;;; my-emacs-ui-tests.el --- Isolated viewport typography tests -*- lexical-binding: t -*-

;;; Commentary:
;; Exercise the configured policy and pinned renderer, not a shared daemon.
;; Face properties/remappings are evidence of configuration, not pixel alignment.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-shell)
(require 'markdown-mode)
(require 'mixed-pitch)
(require 'doric-themes)
(require 'auto-dark)
(require 'pulsar)
(require 'lin)
;; Loading the actual UI configuration must not start global UI machinery.
(cl-letf (((symbol-function 'auto-dark-mode) #'ignore)
          ((symbol-function 'pulsar-global-mode) #'ignore)
          ((symbol-function 'lin-global-mode) #'ignore))
  (require 'my-emacs-ui))

(defun my/ui-test--remapped-family (face)
  "Return the family installed by mixed-pitch for FACE."
  (plist-get (cadr (assq face face-remapping-alist)) :family))

(defun my/ui-test--inherits-p (face base)
  "Whether FACE inherits BASE, directly or transitively."
  (or (eq face base)
      (let ((parents (face-attribute face :inherit nil nil)))
        (when (and parents (not (eq parents 'unspecified)))
          (seq-some (lambda (parent) (my/ui-test--inherits-p parent base))
                    (if (listp parents) parents (list parents)))))))

(defun my/ui-test--faces-at (text)
  "Return the face list at the start of TEXT in the current buffer."
  (goto-char (point-min))
  (search-forward text)
  (let ((faces (get-text-property (- (point) (length text)) 'face)))
    (if (listp faces) faces (list faces))))

(ert-deftest my/ui-mixed-pitch-is-limited-to-markdown-and-viewport-modes ()
  ;; Header generation needs session state, unrelated to mode typography.
  (cl-letf (((symbol-function 'agent-shell-viewport--update-header) #'ignore))
    (dolist (mode '(markdown-mode agent-shell-viewport-view-mode
                   agent-shell-viewport-edit-mode text-mode comint-mode
                   emacs-lisp-mode))
      (with-temp-buffer
        (funcall mode)
        (should (eq major-mode mode))
        (if (memq mode '(markdown-mode agent-shell-viewport-view-mode
                        agent-shell-viewport-edit-mode))
            (progn
              (should mixed-pitch-mode)
              (should (equal (my/ui-test--remapped-family 'default)
                             (face-attribute 'variable-pitch :family)))
              (dolist (face '(markdown-inline-code-face markdown-table-face
                              agent-shell-markdown-inline-code
                              agent-shell-markdown-source-block
                              agent-shell-markdown-table))
                (should (equal (my/ui-test--remapped-family face)
                               (face-attribute 'default :family)))))
          (should-not (bound-and-true-p mixed-pitch-mode)))))))

(ert-deftest my/ui-compose-keeps-raw-markdown-and-native-editing-setup ()
  (cl-letf (((symbol-function 'agent-shell-viewport--update-header) #'ignore))
    (let ((draft "Prose with `identifier`.\n\n```elisp\n(let ((x 1)) x)\n```\n\n| Name | Value |\n| --- | --- |\n| one | 1 |\n")
          baseline)
      ;; Compare editing setup with the native mode, without our typography hook.
      (let ((agent-shell-viewport-edit-mode-hook
             (remq #'mixed-pitch-mode agent-shell-viewport-edit-mode-hook)))
        (with-temp-buffer
          (agent-shell-viewport-edit-mode)
          (setq baseline (list (current-local-map) completion-at-point-functions
                               indent-line-function line-prefix wrap-prefix))))
      (with-temp-buffer
        (agent-shell-viewport-edit-mode)
        (should mixed-pitch-mode)
        (should-not buffer-read-only)
        (should (equal baseline
                       (list (current-local-map) completion-at-point-functions
                             indent-line-function line-prefix wrap-prefix)))
        (insert draft)
        (font-lock-ensure)
        (should (equal (buffer-string) draft))
        ;; No Markdown renderer/fontification is installed in compose. Raw code
        ;; and table text therefore use the same default remapping as prose.
        (dolist (text '("Prose" "identifier" "(let" "Name"))
          (should-not (my/ui-test--faces-at text)))
        (should (equal (my/ui-test--remapped-family 'default)
                       (face-attribute 'variable-pitch :family)))))))

(ert-deftest my/ui-echoed-prompt-remaps-only-viewport-family ()
  (let ((inherit (face-attribute 'agent-shell-viewport-prompt :inherit))
        (doc-attributes (face-all-attributes 'font-lock-doc-face))
        (prompt-attributes (face-all-attributes 'agent-shell-viewport-prompt)))
    (should (eq inherit 'font-lock-doc-face))
    (should (memq 'font-lock-doc-face mixed-pitch-fixed-pitch-faces))
    (cl-letf (((symbol-function 'agent-shell-viewport--update-header) #'ignore))
      (dolist (mode '(agent-shell-viewport-view-mode
                     agent-shell-viewport-edit-mode markdown-mode emacs-lisp-mode))
        (with-temp-buffer
          (funcall mode)
          (if (eq mode 'agent-shell-viewport-view-mode)
              (progn
                (should (equal (my/ui-test--remapped-family 'agent-shell-viewport-prompt)
                               (face-attribute 'variable-pitch :family)))
                ;; Only family is overridden: inheritance supplies slant/colour.
                (should (equal (cadr (assq 'agent-shell-viewport-prompt face-remapping-alist))
                               (list :family (face-attribute 'variable-pitch :family))))
                (should (equal (my/ui-test--remapped-family 'font-lock-doc-face)
                               (face-attribute 'default :family)))
                (mixed-pitch-mode -1)
                (should-not (assq 'agent-shell-viewport-prompt face-remapping-alist))
                (mixed-pitch-mode 1)
                (should my/viewport-prompt-face-cookie))
            (should-not (assq 'agent-shell-viewport-prompt face-remapping-alist))))))
    (should (equal doc-attributes (face-all-attributes 'font-lock-doc-face)))
    (should (equal prompt-attributes (face-all-attributes 'agent-shell-viewport-prompt)))))

(ert-deftest my/ui-rendered-code-and-table-face-coverage ()
  (with-temp-buffer
    (insert (agent-shell-markdown-convert
             "Prose with `identifier`.\n\n```elisp\n(let ((x 1))\n  (message \"hello\"))\n```\n\n| Name | Value |\n| --- | --- |\n| one | 1 |\n| two | 2 |\n"))
    (should (memq 'agent-shell-markdown-inline-code
                  (my/ui-test--faces-at "identifier")))
    (should (memq 'agent-shell-markdown-source-block-language
                  (my/ui-test--faces-at "elisp")))
    (should (memq 'agent-shell-markdown-source-block
                  (my/ui-test--faces-at "(let")))
    (should (memq 'font-lock-keyword-face (my/ui-test--faces-at "let")))
    (should (memq 'font-lock-string-face (my/ui-test--faces-at "\"hello\"")))
    (dolist (text '("Name" "one" "two" "│" "─"))
      (should (seq-some
               (lambda (face)
                 (my/ui-test--inherits-p face 'agent-shell-markdown-table))
               (my/ui-test--faces-at text))))
    (should (my/ui-test--inherits-p 'agent-shell-markdown-source-block-language
                                   'agent-shell-markdown-source-block))))

(ert-deftest my/ui-unfenced-tool-output-follows-viewport-default ()
  ;; Accepted limitation: plain tool results have no fixed-pitch body face.
  (cl-letf (((symbol-function 'agent-shell-viewport--update-header) #'ignore))
    (with-temp-buffer
      (agent-shell-viewport-view-mode)
      (let* ((raw "name    count\nalpha   12\n")
             (output (agent-shell--tool-call-update-output-markdown
                      `((content . [((type . "content")
                                     (content . ((type . "text") (text . ,raw))))])))))
        (let ((inhibit-read-only t))
          (insert (agent-shell-markdown-convert output)))
        (should (equal (buffer-string) raw))
        (should-not (my/ui-test--faces-at "alpha"))
        (should (equal (my/ui-test--remapped-family 'default)
                       (face-attribute 'variable-pitch :family)))))))

(ert-deftest my/ui-mixed-pitch-survives-streamed-code ()
  (cl-letf (((symbol-function 'agent-shell-viewport--update-header) #'ignore))
    (with-temp-buffer
      (agent-shell-viewport-view-mode)
      (let ((inhibit-read-only t))
        (insert "Prose.\n\n```elisp\n(let ((x 1))\n")
        (agent-shell-markdown-replace-markup :render-images nil)
        (should (string-match-p "```elisp" (buffer-string)))
        (goto-char (point-max))
        (insert "  (message \"hello\"))\n```\n")
        (agent-shell-markdown-replace-markup :render-images nil)
        (should (memq 'agent-shell-markdown-source-block
                      (my/ui-test--faces-at "(let")))
        (should (memq 'font-lock-keyword-face (my/ui-test--faces-at "let")))
        (should mixed-pitch-mode)
        (should (equal (my/ui-test--remapped-family 'agent-shell-markdown-source-block)
                       (face-attribute 'default :family)))))))

(ert-deftest my/ui-fontaine-refresh-and-theme-change-retain-policy ()
  (let ((original-default (face-attribute 'default :family))
        (original-variable (face-attribute 'variable-pitch :family))
        (original-themes custom-enabled-themes))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-viewport--update-header) #'ignore)
                  ;; :after configuration can run again when theme files load.
                  ((symbol-function 'auto-dark-mode) #'ignore))
          (dolist (mode '(markdown-mode agent-shell-viewport-view-mode
                          agent-shell-viewport-edit-mode))
            (with-temp-buffer
              (funcall mode)
              (dolist (theme '(doric-marble doric-obsidian))
                (mapc #'disable-theme custom-enabled-themes)
                (load-theme theme t)
                (set-face-attribute 'default nil :family "Test Fixed")
                (set-face-attribute 'variable-pitch nil :family "Test Variable")
                (run-hooks 'fontaine-set-preset-hook)
                (should mixed-pitch-mode)
                (should (equal (my/ui-test--remapped-family 'default) "Test Variable"))
                (if (eq mode 'agent-shell-viewport-view-mode)
                    (should (equal (my/ui-test--remapped-family 'agent-shell-viewport-prompt)
                                   "Test Variable"))
                  (should-not (assq 'agent-shell-viewport-prompt face-remapping-alist)))
                (should (equal (my/ui-test--remapped-family 'font-lock-doc-face) "Test Fixed"))
                (dolist (face '(markdown-table-face agent-shell-markdown-inline-code
                                agent-shell-markdown-source-block agent-shell-markdown-table))
                  (should (equal (my/ui-test--remapped-family face) "Test Fixed")))
                (should (my/ui-test--inherits-p 'agent-shell-markdown-table-border
                                               'agent-shell-markdown-table))))))
      (mapc #'disable-theme custom-enabled-themes)
      (mapc #'enable-theme (reverse original-themes))
      (set-face-attribute 'default nil :family original-default)
      (set-face-attribute 'variable-pitch nil :family original-variable))))

(provide 'my-emacs-ui-tests)
;;; my-emacs-ui-tests.el ends here