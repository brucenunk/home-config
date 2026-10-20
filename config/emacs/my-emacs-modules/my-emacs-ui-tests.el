;;; my-emacs-ui-tests.el --- Isolated typography and mode line tests -*- lexical-binding: t -*-

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
(require 'time)
(require 'flymake)
(defvar vc-mode)
;; Loading the actual UI configuration must not start global UI machinery.
(cl-letf (((symbol-function 'auto-dark-mode) #'ignore)
          ((symbol-function 'pulsar-global-mode) #'ignore)
          ((symbol-function 'lin-global-mode) #'ignore)
          ((symbol-function 'display-time-mode) #'ignore))
  (require 'my-emacs-ui))

;; Native startup regenerates agent-shell-mode through shell-maker-start-v2.
;; The pinned package's initial definition embeds an unquoted keymap and cannot
;; be called directly before that startup. Follow the native definition path,
;; suppressing only process initialization in this isolated typography suite.
(with-temp-buffer
  (cl-letf (((symbol-function 'shell-maker--initialize) #'ignore))
    (shell-maker-start-v2 :config (agent-shell--make-shell-maker-config)
                          :buffer-name (buffer-name) :no-focus t)))

(ert-deftest my/ui-writeroom-is-opt-in-and-restores-writing-layout ()
  (should (commandp 'writeroom-mode))
  (require 'writeroom-mode)
  (should (= writeroom-width 80))
  (should writeroom-restore-window-config)
  (should (equal writeroom-local-effects '(visual-line-mode)))
  (should-not (bound-and-true-p global-writeroom-mode))
  ;; Frame effects need a graphical manual check.  Exercise the real buffer
  ;; effects and window restoration without changing fullscreen in batch.
  (let ((writeroom-global-effects nil))
    (dolist (mode '(text-mode markdown-mode))
      (save-window-excursion
        (with-temp-buffer
          (funcall mode)
          (should-not (bound-and-true-p writeroom-mode))
          (insert (make-string 200 ?a) " " (make-string 200 ?b))
          (set-buffer-modified-p nil)
          (switch-to-buffer (current-buffer))
          (delete-other-windows)
          (split-window-below)
          (let ((text (buffer-string))
                (modeline mode-line-format)
                (mixed (bound-and-true-p mixed-pitch-mode)))
            (unwind-protect
                (progn
                  (writeroom-mode 1)
                  (should (= (length (window-list)) 1))
                  (should visual-line-mode)
                  (should visual-fill-column-mode)
                  (should (= visual-fill-column-width 80))
                  (should visual-fill-column-center-text)
                  (should-not mode-line-format)
                  (should (eq mixed (bound-and-true-p mixed-pitch-mode))))
              (writeroom-mode -1))
            (should (= (length (window-list)) 2))
            (should (equal modeline mode-line-format))
            (should-not visual-line-mode)
            (should-not visual-fill-column-mode)
            (should (equal text (buffer-string)))
            (should-not (buffer-modified-p))))))))

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
                   agent-shell-viewport-edit-mode agent-shell-mode text-mode comint-mode
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

(defun my/ui-test--header-remappings (agent-shell-p)
  "Check header underline remappings, expected only when AGENT-SHELL-P."
  (dolist (face '(header-line header-line-inactive))
    (if (and agent-shell-p (facep face))
        ;; Exactly one relative entry; keep the global face as the base.
        (should (equal (assq face face-remapping-alist)
                       (list face '(:underline nil) face)))
      (should-not (assq face face-remapping-alist)))))

(ert-deftest my/ui-agent-shell-header-underlines-are-local-and-repeatable ()
  (let* ((faces (seq-filter #'facep '(header-line header-line-inactive
                                    mode-line mode-line-inactive)))
         (attributes (mapcar #'face-all-attributes faces)))
    (cl-letf (((symbol-function 'agent-shell-viewport--update-header) #'ignore))
      (dolist (mode '(agent-shell-mode
                     agent-shell-viewport-view-mode agent-shell-viewport-edit-mode
                     markdown-mode text-mode comint-mode emacs-lisp-mode))
        (with-temp-buffer
          (funcall mode)
          (let ((agent-shell-p (memq mode '(agent-shell-mode
                                           agent-shell-viewport-view-mode
                                           agent-shell-viewport-edit-mode))))
            (my/ui-test--header-remappings agent-shell-p)
            ;; Reapplying setup must leave other buffer-local policy intact.
            (face-remap-add-relative 'mode-line :weight 'bold)
            (let ((others (seq-remove
                           (lambda (entry) (memq (car entry) faces))
                           (copy-tree face-remapping-alist))))
              (dotimes (_ 3) (my/agent-shell-header-no-underline))
              (my/ui-test--header-remappings agent-shell-p)
              (should (equal others
                             (seq-remove
                              (lambda (entry) (memq (car entry) faces))
                              face-remapping-alist)))
              (should (equal (cadr (assq 'mode-line face-remapping-alist))
                             '(:weight bold)))))))
      ;; Major-mode changes clear local cookies/remaps; each hook reinstalls
      ;; only the policy for its mode, including a later unrelated mode.
      (with-temp-buffer
        (dolist (mode '(agent-shell-mode agent-shell-viewport-view-mode
                       agent-shell-viewport-edit-mode agent-shell-mode text-mode))
          (funcall mode)
          (my/ui-test--header-remappings (not (eq mode 'text-mode))))))
    (should (equal attributes (mapcar #'face-all-attributes faces)))
    (should-not (default-value 'my/agent-shell-header-face-cookies))))

(ert-deftest my/ui-agent-shell-header-tolerates-missing-inactive-face ()
  (let ((original-facep (symbol-function 'facep)))
    (cl-letf (((symbol-function 'agent-shell-viewport--update-header) #'ignore)
              ((symbol-function 'facep)
               (lambda (face)
                 (unless (eq face 'header-line-inactive)
                   (funcall original-facep face)))))
      (dolist (mode '(agent-shell-mode
                     agent-shell-viewport-view-mode agent-shell-viewport-edit-mode))
        (with-temp-buffer
          (funcall mode)
          (my/agent-shell-header-no-underline)
          (my/ui-test--header-remappings t)
          (should (= (length my/agent-shell-header-face-cookies) 1)))))))

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
          (dolist (mode '(agent-shell-mode markdown-mode agent-shell-viewport-view-mode
                          agent-shell-viewport-edit-mode))
            (with-temp-buffer
              (funcall mode)
              (dolist (theme '(doric-marble doric-obsidian))
                (mapc #'disable-theme custom-enabled-themes)
                (load-theme theme t)
                (set-face-attribute 'default nil :family "Test Fixed")
                (set-face-attribute 'variable-pitch nil :family "Test Variable")
                (run-hooks 'fontaine-set-preset-hook)
                (my/ui-test--header-remappings (not (eq mode 'markdown-mode)))
                (if (eq mode 'agent-shell-mode)
                    (progn
                      (should-not (bound-and-true-p mixed-pitch-mode))
                      (should-not (assq 'default face-remapping-alist)))
                  (should mixed-pitch-mode)
                  (should (equal (my/ui-test--remapped-family 'default) "Test Variable"))
                  (should (equal (my/ui-test--remapped-family 'font-lock-doc-face) "Test Fixed"))
                  (dolist (face '(markdown-table-face agent-shell-markdown-inline-code
                                  agent-shell-markdown-source-block agent-shell-markdown-table))
                    (should (equal (my/ui-test--remapped-family face) "Test Fixed"))))
                (if (eq mode 'agent-shell-viewport-view-mode)
                    (should (equal (my/ui-test--remapped-family 'agent-shell-viewport-prompt)
                                   "Test Variable"))
                  (should-not (assq 'agent-shell-viewport-prompt face-remapping-alist)))
                (should (my/ui-test--inherits-p 'agent-shell-markdown-table-border
                                               'agent-shell-markdown-table))))))
      (mapc #'disable-theme custom-enabled-themes)
      (mapc #'enable-theme (reverse original-themes))
      (set-face-attribute 'default nil :family original-default)
      (set-face-attribute 'variable-pitch nil :family original-variable))))

(ert-deftest my/ui-modeline-quiet-buffer-states ()
  (with-temp-buffer
    (should (equal (my/modeline-status) ""))
    (insert "Unsaved")
    ;; Process output and generated viewports are not unsaved files.
    (should (equal (my/modeline-status) ""))
    (dolist (active '(t nil))
      (cl-letf (((symbol-function 'mode-line-window-selected-p) (lambda () active)))
        (let ((base (if active 'mode-line-buffer-id 'shadow)))
          (should (eq (get-text-property 0 'face (my/modeline-buffer-name)) base))
          (let ((buffer-file-name "/work/unsaved.el"))
            (should (equal (get-text-property 0 'face (my/modeline-buffer-name))
                           (list 'italic base)))
            (set-buffer-modified-p nil)
            (should (eq (get-text-property 0 'face (my/modeline-buffer-name)) base))
            (set-buffer-modified-p t)))))
    (setq buffer-read-only t)
    (let ((marker (my/modeline-status)))
      (should (equal marker " RO "))
      (should (eq (get-text-property 0 'face marker) 'shadow))
      (should (equal (get-text-property 0 'help-echo marker) "Read-only buffer")))
    (setq buffer-read-only nil)
    (should (equal (my/modeline-status) ""))))

(ert-deftest my/ui-modeline-exceptional-states-do-not-contact-remote-hosts ()
  (with-temp-buffer
    (insert "one\ntwo\n")
    (set-buffer-modified-p nil)
    (narrow-to-region 1 4)
    (let ((default-directory "/ssh:unreachable.invalid:/work/")
          (defining-kbd-macro t))
      (cl-letf (((symbol-function 'process-file)
                 (lambda (&rest _) (ert-fail "Redisplay started a process")))
                ((symbol-function 'file-exists-p)
                 (lambda (&rest _) (ert-fail "Redisplay probed a file"))))
        (should (equal (my/modeline-status) " Remote  Narrow  Recording "))))))

(ert-deftest my/ui-modeline-secondary-details-yield-to-state-and-small-windows ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'mode-line-window-selected-p) (lambda () t))
              ((symbol-function 'window-total-width) (lambda (&rest _) 100)))
      (should (my/modeline-details-p 100))
      (setq buffer-read-only t)
      (should-not (my/modeline-details-p 100))
      (should (my/modeline-details-p 80)))
    (cl-letf (((symbol-function 'mode-line-window-selected-p) (lambda () t))
              ((symbol-function 'window-total-width) (lambda (&rest _) 40)))
      (should-not (my/modeline-details-p 70))
      (should-not (my/modeline-details-p 80))
      (should-not (my/modeline-details-p 100)))
    (cl-letf (((symbol-function 'mode-line-window-selected-p) (lambda () nil))
              ((symbol-function 'window-total-width) (lambda (&rest _) 200)))
      (should-not (my/modeline-details-p 70)))))

(ert-deftest my/ui-modeline-name-budget-and-active-inactive-faces ()
  (with-temp-buffer
    (rename-buffer "a-long-buffer-name-with-100%-literal-content")
    (let ((buffer-file-name "/work/full-name.el"))
      (cl-letf (((symbol-function 'window-total-width) (lambda (&rest _) 40))
                ((symbol-function 'format-mode-line) (lambda (&rest _) "  ·  7:07 pm "))
                ((symbol-function 'mode-line-window-selected-p) (lambda () t)))
        (let ((name (my/modeline-buffer-name)))
          (should (<= (string-width name) 20))
          (should (string-suffix-p "…" name))
          (should (eq (get-text-property 0 'face name) 'mode-line-buffer-id))
          (should (equal (get-text-property 0 'help-echo name) buffer-file-name))
          (should (keymapp (get-text-property 0 'local-map name))))
        (insert "changed")
        (setq buffer-read-only t)
        (should (<= (+ (string-width (my/modeline-buffer-name))
                       (string-width (my/modeline-status)) 13 4)
                    40)))
      (cl-letf (((symbol-function 'mode-line-window-selected-p) (lambda () nil)))
        (should (equal (get-text-property 0 'face (my/modeline-buffer-name))
                       '(italic shadow)))))))

(ert-deftest my/ui-modeline-preserves-native-status-without-minor-mode-clutter ()
  (with-temp-buffer
    (let ((mode-line-process '(" Running"))
          (display-time-string "7:07 pm"))
      (cl-letf (((symbol-function 'mode-line-window-selected-p) (lambda () nil)))
        (should (equal (my/modeline-context) '("" nil mode-line-process nil)))
        (should-not (my/modeline-info))))
    (should (memq 'mode-line-format-right-align (default-value 'mode-line-format)))
    (should-not (memq 'mode-line-modes (default-value 'mode-line-format)))
    (should-not (memq 'mode-line-misc-info (default-value 'mode-line-format)))
    (should (equal mode-line-right-align-edge 'right-margin))))

(ert-deftest my/ui-modeline-rendered-constructs-preserve-literals-and-clock ()
  ;; Batch frames do not render mode lines.  Run this test in an isolated
  ;; terminal Emacs as well as the ordinary batch suite.
  (skip-unless (not (string-empty-p (format-mode-line "probe"))))
  (with-temp-buffer
    (rename-buffer "100%-literal")
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((display-time-string "7:07 pm")
            (mode-line-process " Running%b")
            (mode-name "Mode%b")
            (vc-mode " Git:topic%b"))
        (dolist (active '(t nil))
          (cl-letf (((symbol-function 'mode-line-window-selected-p) (lambda () active))
                    ((symbol-function 'window-total-width) (lambda (&rest _) 140)))
            (let ((rendered (format-mode-line (default-value 'mode-line-format)
                                             nil nil (current-buffer))))
              (should (string-match-p (regexp-quote "100%-literal") rendered))
              (should (string-match-p (regexp-quote "Running%b") rendered))
              (if active
                  (progn
                    (should (string-match-p "7:07 pm" rendered))
                    (should-not (string-match-p "  ·  7:07 pm" rendered))
                    (should (string-match-p (regexp-quote "100%-literal  ·  Mode%b")
                                            rendered))
                    (should (string-match-p (regexp-quote "  ·  Git:topic%b") rendered)))
                (should-not (string-match-p "Git:" rendered))
                (should-not (string-match-p "7:07 pm" rendered))))))))))

(ert-deftest my/ui-modeline-branch-uses-available-width-and-keeps-vc-styling ()
  (skip-unless (not (string-empty-p (format-mode-line "probe"))))
  (with-temp-buffer
    (rename-buffer "modeline-example.el")
    (emacs-lisp-mode)
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let* ((display-time-string "7:07 pm")
             (branch "Git:feature/a-long-descriptive-branch-name-with-a-distinctive-suffix")
             (vc-mode (propertize (concat " " branch) 'face 'vc-edited-state)))
        (dolist (width '(100 160))
          (cl-letf (((symbol-function 'mode-line-window-selected-p) (lambda () t))
                    ((symbol-function 'window-total-width) (lambda (&rest _) width)))
            (let ((rendered (format-mode-line (default-value 'mode-line-format)
                                             nil nil (current-buffer))))
              (ert-info ((substring-no-properties rendered))
                (should (string-match-p "modeline-example.el  ·  Emacs Lisp  ·  Git:"
                                        rendered))
                (should (string-match-p "7:07 pm" rendered))
                (should-not (string-match-p "  ·  7:07 pm" rendered))
                (should (<= (string-width rendered) width))
                (should (eq (get-text-property (string-match "Git:" rendered)
                                               'face rendered)
                            'vc-edited-state))
                (if (= width 160)
                    (should (string-match-p (regexp-quote branch) rendered))
                  (should-not (string-match-p (regexp-quote branch) rendered))
                  (should (string-match-p "Git:feature/a-long-descriptive" rendered)))))))))))

(ert-deftest my/ui-modeline-right-group-has-no-leading-or-empty-separators ()
  (skip-unless (not (string-empty-p (format-mode-line "probe"))))
  (with-temp-buffer
    (insert "Example text")
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((display-time-string "8:22 pm")
            report)
        ;; Exercise native counters, invalidation, faces, and mouse actions
        ;; through a synchronous in-memory backend, not parsed mock counts.
        (setq-local flymake-diagnostic-functions
                    (list (lambda (callback &rest _)
                            (setq report callback)
                            (funcall callback nil))))
        (flymake-mode 1)
        (flymake-start nil t)
        (cl-letf (((symbol-function 'mode-line-window-selected-p) (lambda () t))
                  ((symbol-function 'window-total-width) (lambda (&rest _) 120)))
          (should (equal (format-mode-line (my/modeline-info)) "8:22 pm "))
          (funcall report
                   (cl-loop for position from 1 to 3 collect
                            (flymake-make-diagnostic (current-buffer)
                                                     position (1+ position)
                                                     :note "Example note"))
                   :region (cons (point-min) (point-max)))
          (let ((rendered (format-mode-line (my/modeline-info))))
            (should (equal rendered "3 info  ·  8:22 pm "))
            (should (facep (get-text-property 0 'face rendered)))
            (should (keymapp (get-text-property 2 'keymap rendered))))
          (funcall report
                   (list (flymake-make-diagnostic (current-buffer) 1 2
                                                  :note "Example note"))
                   :region (cons (point-min) (point-max)))
          (should (equal (format-mode-line (my/modeline-info))
                         "1 info  ·  8:22 pm "))
          (funcall report
                   (cl-loop for type in '(:error :error :warning)
                            for position from 1 collect
                            (flymake-make-diagnostic (current-buffer)
                                                     position (1+ position)
                                                     type "Example diagnostic"))
                   :region (cons (point-min) (point-max)))
          (should (equal (format-mode-line (my/modeline-info))
                         "2 errors, 1 warning  ·  8:22 pm "))
          (funcall report nil :region (cons (point-min) (point-max)))
          (should (equal (format-mode-line (my/modeline-info)) "8:22 pm "))
          (flymake-mode -1)
          (should (equal (format-mode-line (my/modeline-info)) "8:22 pm "))
          (let ((flymake-mode t)
                (flymake-mode-line-exception "Wait%b")
                (flymake-mode-line-error-counter nil)
                (flymake-mode-line-warning-counter nil)
                (flymake-mode-line-note-counter nil))
            (should (equal (format-mode-line (my/modeline-info))
                           "Wait%b  ·  8:22 pm "))))))))

(ert-deftest my/ui-modeline-clock-is-local-12-hour-with-spaced-am-pm ()
  (should (equal display-time-format "%-I:%M %P"))
  (should (= display-time-interval 60))
  (should-not display-time-default-load-average)
  (should (eq display-time-mail-function #'ignore))
  (let ((display-time-string "")
        (now (encode-time 0 7 19 18 10 2026)))
    (cl-letf (((symbol-function 'current-time) (lambda () now)))
      (display-time-update)
      (should (equal (string-trim display-time-string) "7:07 pm"))
      (setq now (time-add now 60))
      (display-time-update)
      (should (equal (string-trim display-time-string) "7:08 pm"))
      (setq now (encode-time 0 0 0 18 10 2026))
      (display-time-update)
      (should (equal (string-trim display-time-string) "12:00 am"))
      (setq now (encode-time 0 0 12 18 10 2026))
      (display-time-update)
      (should (equal (string-trim display-time-string) "12:00 pm")))))

(ert-deftest my/ui-modeline-markers-inherit-theme-faces-without-decoration ()
  (unwind-protect
      (dolist (theme '(doric-marble doric-obsidian))
        (mapc #'disable-theme custom-enabled-themes)
        (load-theme theme t)
        (with-temp-buffer
          (insert "Unsaved")
          (setq buffer-read-only t)
          (should (eq (get-text-property 0 'face (my/modeline-status)) 'shadow))
          (let ((buffer-file-name "/work/unsaved.el"))
            (cl-letf (((symbol-function 'mode-line-window-selected-p) (lambda () t)))
              (should (equal (get-text-property 0 'face (my/modeline-buffer-name))
                             '(italic mode-line-buffer-id)))))))
    (mapc #'disable-theme custom-enabled-themes)))

(provide 'my-emacs-ui-tests)
;;; my-emacs-ui-tests.el ends here