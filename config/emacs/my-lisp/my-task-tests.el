;;; my-task-tests.el --- Tests for task file capture -*- lexical-binding: t -*-

;;; Commentary:

;; Catalogue-backed capture and file identity against real Denote, no lifecycle.

;;; Code:

(require 'my-task-test-support)
(require 'vertico)

(defconst my/task-test--machines
  '(("machine-a" :directory "~/work/"
     :repositories ((:name "example/project" :path "/work/project/main" :base-ref "origin/main"))
     :default-model "provider/vendor/model"
     :models ((:name "provider/vendor/model" :thinking-levels ("off" "medium" "high")
               :default-thinking "medium")))))

(defmacro my/task-test--with-directory (&rest body)
  "Run BODY with an isolated shared task directory."
  (declare (indent 0) (debug t))
  `(let* ((root (make-temp-file "task-files-" t))
          (denote-directory root)
          (my/agent-machines (copy-tree my/task-test--machines))
          (denote-save-buffers t)
          (denote-templates '((task-workflow-v3 . "## Context\n\nCapture context.\n")
                              (empty . "")))
          (my/task-note-created-hook nil))
     (unwind-protect
         (progn
           (cl-letf (((symbol-function 'my/task-directory) (lambda () root))
                     ((symbol-function 'completing-read)
                      (lambda (_prompt choices &optional _predicate _require-match _initial _history default &rest _)
                        (or default (car choices)))))
             ,@body))
       (dolist (buffer (buffer-list))
         (when-let* ((file (buffer-file-name buffer)))
           (when (string-prefix-p root file)
             (with-current-buffer buffer (set-buffer-modified-p nil))
             (kill-buffer buffer))))
       (delete-directory root t))))

(ert-deftest my/task-add-creates-a-plain-note-with-skill ()
  (my/task-test--with-directory
   (let* ((notifications 0)
          (my/task-note-created-hook (list (lambda () (cl-incf notifications))))
          (file (my/task-add "New task")))
     (should (file-exists-p file))
     (should (equal (file-name-directory file) (file-name-as-directory root)))
     (should (denote-file-has-denoted-filename-p file))
     (should (string-match-p "==todo--" (file-name-nondirectory file)))
     (should (= notifications 1))
     (should-not (find-buffer-visiting file))
     (with-temp-buffer
       (insert-file-contents file)
       (should (search-forward "skill:      task-workflow-v3" nil t))
       (should (search-forward "## Context" nil t))
       (goto-char (point-min))
       (dolist (line '("repo: \"example/project\"" "machine: \"machine-a\""
                       "model: \"provider/vendor/model\""
                       "thinking: \"medium\""))
         (goto-char (point-min))
         (should (search-forward line nil t)))
       (should-not (search-forward "## Dependencies" nil t))
       (goto-char (point-min))
       (should-not (re-search-forward "^base-ref:" nil t))))))

(ert-deftest my/task-add-named-skill-uses-an-empty-template ()
  (my/task-test--with-directory
   (let ((file (my/task-add "Bump inputs" "bump-nix")))
     (with-temp-buffer
       (insert-file-contents file)
       (should (search-forward "skill:      bump-nix" nil t))
       (should-not (search-forward "## Context" nil t))))))

(ert-deftest my/task-add-unscripted-note-has-no-skill ()
  (my/task-test--with-directory
   (let ((file (my/task-add "Plain note" "none")))
     (with-temp-buffer
       (insert-file-contents file)
       (should-not (re-search-forward "^skill:" nil t))))))

(ert-deftest my/task-add-interactive-streamlined-prompts ()
  (my/task-test--with-directory
   (let ((epic (expand-file-name "epic/" root))
         note-buffer)
     (make-directory epic)
     (cl-letf (((symbol-function 'called-interactively-p) (lambda (&rest _) t))
               ((symbol-function 'denote-subdirectory-prompt) (lambda () epic))
               ((symbol-function 'read-string)
                (lambda (prompt &rest _)
                  (should (equal prompt "Title: "))
                  "Interactive note"))
               ((symbol-function 'completing-read)
                (lambda (prompt choices &rest _)
                  (should (equal prompt "Repository: "))
                  (should (equal choices '("example/project")))
                  "example/project")))
       (let ((current-prefix-arg nil))
         (call-interactively #'my/task-add))
       (setq note-buffer (current-buffer)))
     (with-current-buffer note-buffer
       (should (equal (file-name-directory buffer-file-name)
                      (file-name-as-directory epic)))
       (should (my/task-file-p))))))

(ert-deftest my/task-add-prefix-prompts-in-capture-order ()
  (my/task-test--with-directory
   (let (prompts)
     (cl-letf (((symbol-function 'called-interactively-p) (lambda (&rest _) t))
               ((symbol-function 'denote-subdirectory-prompt) (lambda () nil))
               ((symbol-function 'read-string)
		(lambda (prompt &optional initial &rest _)
                  (push prompt prompts)
                  (if (equal prompt "Title: ") "Bump" initial)))
               ((symbol-function 'completing-read)
		(lambda (prompt choices &optional _predicate _require-match _initial _history default &rest _)
                  (push prompt prompts)
                  (if (equal prompt "Workflow: ") "bump-nix" (or default (car choices))))))
       (let ((current-prefix-arg '(4)))
         (call-interactively #'my/task-add))
       (goto-char (point-min))
       (should (search-forward "skill:      bump-nix" nil t)))
     (should (equal (nreverse prompts)
                    '("Title: " "Workflow: " "Repository: " "Model: " "Thinking: "))))))

(ert-deftest my/task-add-both-interactive-forms-prompt-for-multiple-machines ()
  (my/task-test--with-directory
   (setq my/agent-machines (copy-tree my/task-test--two-machines))
   (dolist (prefix '(nil (4)))
     (let (prompts)
       (cl-letf (((symbol-function 'called-interactively-p) (lambda (&rest _) t))
                 ((symbol-function 'denote-subdirectory-prompt) (lambda () nil))
                 ((symbol-function 'read-string)
                  (lambda (prompt &rest _)
                    (should (equal prompt "Title: ")) "Multiple destinations"))
                 ((symbol-function 'completing-read)
                  (lambda (prompt choices &optional _p _r _i _h default &rest _)
                    (push prompt prompts)
                    (or default (car choices)))))
         (let ((current-prefix-arg prefix))
           (call-interactively #'my/task-add)))
       (should (equal (nreverse prompts)
                      (if prefix
                          '("Workflow: " "Repository: " "Machine: " "Model: " "Thinking: ")
                        '("Repository: " "Machine: "))))))))

(ert-deftest my/task-file-p-recognizes-existing-notes-without-mutating-them ()
  (my/task-test--with-directory
   (let* ((file (expand-file-name "20260324T103418==done--legacy.md" root))
          (contents "---\nrepo: example/project\n---\n\n## Dependencies\n\n- [ ] [denote:20260324T103419](Old task)\n"))
     (with-temp-file file (insert contents))
     (with-temp-buffer
       (setq-local buffer-file-name file)
       (should (my/task-file-p)))
     (with-temp-buffer
       (insert-file-contents file)
       (should (equal (buffer-string) contents))))))

(ert-deftest my/task-file-p-rejects-non-denote-files ()
  (my/task-test--with-directory
   (with-temp-buffer
     (setq-local buffer-file-name (expand-file-name "ordinary.md" root))
     (should-not (my/task-file-p)))))

(defconst my/task-test--two-machines
  (append my/task-test--machines
          '(("machine-b" :directory "/rpc:remote.example:~/work/"
             :repositories ((:name "example/project" :path "/srv/project.git" :base-ref "origin/master")
                            (:name "remote/only" :path "/srv/only.git" :base-ref "origin/release/stable"))
             :default-model "other/reasoner"
             :models ((:name "other/off" :thinking-levels ("off") :default-thinking "off")
                      (:name "other/reasoner" :thinking-levels ("low" "high") :default-thinking ""))))))

(ert-deftest my/task-capture-uses-loaded-configuration-and-nested-model-id ()
  (my/task-test--with-directory
   (let ((machine (cdr (assoc "machine-a" my/agent-machines))))
     (should (equal (plist-get (car (plist-get machine :models)) :name)
                    "provider/vendor/model"))
     (should (equal (my/task--metadata-read nil)
                    '((repo . "example/project") (machine . "machine-a")
                      (model . "provider/vendor/model")
                      (thinking . "medium")))))))

(ert-deftest my/task-metadata-insertion-retains-unicode-in-live-buffer ()
  (with-temp-buffer
    (insert "---\ntitle: \"Unicode\"\n---\n\nBody.\n")
    (my/task--metadata-insert '((machine . "máquina-🦊") (base-ref . "upstream/déploiement")))
    (should (multibyte-string-p (buffer-string)))
    (should (string-match-p "machine: \"máquina-🦊\"" (buffer-string)))
    (should (string-match-p "base-ref: \"upstream/déploiement\"" (buffer-string)))))

(ert-deftest my/task-capture-two-machines-prompts-and-filters-by-repo ()
  (my/task-test--with-directory
   (setq my/agent-machines (copy-tree my/task-test--two-machines))
   (let (prompts)
     (cl-letf (((symbol-function 'completing-read)
                (lambda (prompt choices &optional _p _r _i _h default &rest _)
                  (push prompt prompts)
                  (pcase prompt
                    ("Repository: " "example/project")
                    ("Machine: "
                     (should-not default)
                     (should (equal choices '("machine-a" "machine-b")))
                     "machine-b")
                    ("Thinking: " "high")
                    (_ (ert-fail "Unexpected prompt"))))))
       (should (equal (my/task--metadata-read nil)
                      '((repo . "example/project") (machine . "machine-b")
                        (model . "other/reasoner") (thinking . "high")))))
     (should (equal (nreverse prompts) '("Repository: " "Machine: " "Thinking: "))))
   (let (prompts)
     (cl-letf (((symbol-function 'completing-read)
                (lambda (prompt choices &rest _)
                  (push prompt prompts)
                  (pcase prompt
                    ("Repository: "
                     (should (equal choices '("example/project" "remote/only")))
                     "remote/only")
                    ("Thinking: "
                     (should (equal choices '("low" "high"))) "high")
                    (_ (ert-fail "Streamlined capture must use defaults"))))))
       (should (equal (my/task--metadata-read nil)
                      '((repo . "remote/only") (machine . "machine-b")
                        (model . "other/reasoner")
                        (thinking . "high")))))
     (should (equal (nreverse prompts) '("Repository: " "Thinking: "))))))

(ert-deftest my/task-capture-extended-filters-model-and-thinking ()
  (my/task-test--with-directory
   (setq my/agent-machines (copy-tree my/task-test--two-machines))
   (let (prompts)
     (cl-letf (((symbol-function 'read-string)
                (lambda (&rest _) (ert-fail "Capture must not ask for a base ref")))
               ((symbol-function 'completing-read)
                (lambda (prompt choices &optional _p _r _i _h default &rest _)
                  (push prompt prompts)
                  (pcase prompt
                    ("Repository: " "example/project")
                    ("Machine: "
                     (should-not default)
                     (should (equal choices '("machine-a" "machine-b"))) "machine-b")
                    ("Model: "
                     (should (equal default "other/reasoner"))
                     (should (equal choices '("other/off" "other/reasoner"))) "other/off")
                    ("Thinking: "
                     (should (equal default "off"))
                     (should (equal choices '("off"))) "off")))))
       (should (equal (my/task--metadata-read t)
                      '((repo . "example/project") (machine . "machine-b")
                        (model . "other/off")
                        (thinking . "off")))))
     (should (equal (nreverse prompts)
                    '("Repository: " "Machine: " "Model: " "Thinking: "))))))

(ert-deftest my/task-capture-does-not-gather-base-ref-or-call-git ()
  (my/task-test--with-directory
   (dolist (extended '(nil t))
     (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (ert-fail "No base-ref prompt")))
               ((symbol-function 'my/agent-catalogue-reload) (lambda (&rest _) (ert-fail "Capture uses loaded configuration")))
               ((symbol-function 'process-file) (lambda (&rest _) (ert-fail "No Git calls"))))
       (should-not (assq 'base-ref (my/task--metadata-read extended)))))))

(ert-deftest my/task-capture-multiple-machines-requires-explicit-choice ()
  (my/task-test--with-directory
    (setq my/agent-machines (copy-tree my/task-test--two-machines))
    (dolist (extended '(nil t))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt _choices &optional _p require-match initial history default &rest _)
                   (pcase prompt
                     ("Repository: " "example/project")
                     ("Machine: "
                      (should require-match)
                      (should-not initial)
                      (should-not history)
                      (should-not default)
                      "")
                     (_ (ert-fail "Must stop at empty machine choice"))))))
        (should-error (my/task-add "No implicit machine" "task" extended) :type 'user-error)))
    (should-not (directory-files root nil "\\.md\\'"))))

(ert-deftest my/task-capture-vertico-does-not-preselect-a-machine ()
  ;; Batch Emacs reads stdin instead of opening a minibuffer.  Supply a
  ;; headless frontend, but run Vertico's real candidate update, navigation,
  ;; and Return command rather than emulating its selection policy.
  (let ((my/agent-machines (copy-tree my/task-test--two-machines))
        (vertico-preselect 'first))
    (dolist (navigate '(nil t))
      (let ((completing-read-function
             (lambda (prompt choices predicate require-match initial history default &rest _)
               (pcase prompt
                 ("Repository: "
                  (should (eq vertico-preselect 'first))
                  "example/project")
                 ("Machine: "
                  (should-not (or initial history default))
                  (with-temp-buffer
                    (let ((minibuffer-completion-table choices)
                          (minibuffer-completion-predicate predicate)
                          (minibuffer--require-match require-match)
                          (minibuffer-default default)
                          returned)
                      (vertico--update)
                      (should (= vertico--index -1))
                      (when navigate (vertico-next))
                      (cl-letf (((symbol-function 'exit-minibuffer)
                                 (lambda () (setq returned (minibuffer-contents-no-properties)))))
                        (vertico-exit))
                      (should (equal returned (if navigate "machine-a" "")))
                      returned)))
                 (_ (ert-fail "Unexpected capture prompt"))))))
        (if navigate
            (should (equal (alist-get 'machine (my/task--metadata-read nil)) "machine-a"))
          (should-error (my/task--metadata-read nil) :type 'user-error))))
    (should (eq vertico-preselect 'first))))

(ert-deftest my/task-capture-empty-inventory-choices-and-models-stop-before-note ()
  (my/task-test--with-directory
    (dolist (machine '((:directory "~/work/" :repositories nil :default-model "" :models nil)
                       (:directory "~/work/"
                        :repositories ((:name "example/project" :path "/work/main" :base-ref "origin/main"))
                        :default-model "" :models nil)))
      (setq my/agent-machines (list (cons "machine-a" machine)))
      (should-error (my/task-add "No choices") :type 'user-error)
      (should-not (directory-files root nil "\\.md\\'")))))

(ert-deftest my/task-capture-missing-configuration-stops-before-note-creation ()
  (my/task-test--with-directory
   (let ((my/agent-machines nil))
     (should-error (my/task-add "Never created") :type 'user-error)
     (should-not (directory-files root nil "\\.md\\'")))
   ;; Listing and identity do not consume the catalogue.
   (with-temp-buffer
     (setq-local buffer-file-name (expand-file-name "20261005T100000==todo--existing.md" root))
     (should (my/task-file-p)))))

(ert-deftest my/task-capture-unusable-model-or-thinking-stops-before-note ()
  (my/task-test--with-directory
   (dolist (default '("unknown/model" ""))
     (setf (plist-get (cdar my/agent-machines) :default-model) default)
     (should-error (my/task-add "Unusable model") :type 'user-error))
   (setq my/agent-machines (copy-tree my/task-test--machines))
   (setf (plist-get (car (plist-get (cdar my/agent-machines) :models)) :default-thinking) "unsupported")
   (should-error (my/task-add "Unusable thinking") :type 'user-error)
   (should-not (directory-files root nil "\\.md\\'"))))

(ert-deftest my/task-capture-cancellation-creates-no-files ()
  (my/task-test--with-directory
   (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (signal 'quit nil))))
     (should (eq (condition-case nil (my/task-add "Cancelled") (quit 'cancelled)) 'cancelled)))
   (should-not (directory-files root nil "\\.md\\'"))))

(ert-deftest my/task-metadata-insertion-preserves-unrelated-yaml-and-body ()
  (let ((header "---\ntitle: \"Title\"\ntags: []\ncustom:\n  nested: true\nskill: review\n")
        (body "---\n\n## Context\n\nBody with repo: untouched\n---\n"))
    (with-temp-buffer
      (insert header body)
      (my/task--metadata-insert '((repo . "example/project") (machine . "machine-a")
                                  (base-ref . "local: # text") (model . "provider/vendor/model")
                                  (thinking . "high")))
      (should (string-prefix-p header (buffer-string)))
      (should (string-suffix-p body (buffer-string)))
      (should (string-match-p "base-ref: \"local: # text\"" (buffer-string)))
      (dolist (key '(repo machine base-ref model thinking))
        (goto-char (point-min))
        (should (= (how-many (format "^%s:" key)) 1))))))

(ert-deftest my/tasks-map-only-offers-capture-and-list ()
  (should (eq (lookup-key my/tasks-map "a") #'my/task-add))
  (should (eq (lookup-key my/tasks-map "l") #'my/task-list))
  (dolist (key '("D" "F" "p" "X"))
    (should-not (lookup-key my/tasks-map key)))
  (dolist (feature '(my-task-finish my-task-session my-task-index my-agent
				    my-agent-pi my-worktree-repair my-git my-repo my-worktree))
    (should-not (featurep feature))))

(provide 'my-task-tests)
;;; my-task-tests.el ends here
