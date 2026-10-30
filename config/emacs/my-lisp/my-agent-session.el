;;; my-agent-session.el --- Human-operated agent launches -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (denote "4.2") (marginalia "1.0"))

;;; Commentary:

;; Public commands:
;;   - my/agent-session-start-from-file — launch a saved task in a new worktree
;;   - my/agent-session-start-new-worktree — launch ad hoc in a new worktree
;;   - my/agent-session-start-in-directory — launch ad hoc in an exact directory
;; This owns explicit human launches, not task capture, orchestration or cleanup.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'denote)
(require 'marginalia)
(require 'agent-shell)
(require 'agent-shell-pi)
(require 'my-agent-catalogue)

(defvar vertico-preselect)

(defun my/agent-session--task-candidates (root)
  "Return filename titles paired with Denote Org files under ROOT.
Discovery is recursive and filename-only, ordered by Denote identifier
oldest first.  Titles need not be unique; the picker resolves saved titles."
  (when (file-directory-p root)
    (let ((denote-directory root))
      (mapcar (lambda (file)
                (cons (propertize
                       (replace-regexp-in-string
                        "-" " " (or (denote-retrieve-filename-title file) "Untitled task"))
                       'face 'denote-faces-title)
                      file))
              (denote-sort-files
               (denote-directory-files "\\.org\\'" nil nil nil t)
               'identifier)))))

(defun my/agent-session--task-metadata ()
  "Read task metadata from the current buffer's opening Org keyword header.
The header is contiguous keyword lines followed by a blank line.  Never scan
the body for metadata.  Reject duplicate launch fields rather than choosing
between conflicting values.  Values are literal Org strings, not YAML."
  (goto-char (point-min))
  (let ((case-fold-search t)
        header-p metadata)
    (while (looking-at "#\\+\\([[:alnum:]_-]+\\):[ \t]*\\([^\n\r]*\\)\r?\n")
      (setq header-p t)
      (let ((key (downcase (match-string-no-properties 1)))
            (value (match-string-no-properties 2))
            (next (match-end 0)))
        (when (member key '("title" "repo" "machine" "model" "thinking" "skill"))
          (when (assoc key metadata)
            (user-error "Duplicate task %s keyword" key))
          (push (cons key (string-trim value " +" " +")) metadata))
        (goto-char next)))
    (unless (and header-p (looking-at "[ \t]*\r?\n"))
      (user-error "Task requires an opening Org keyword header and blank separator"))
    metadata))

(defun my/agent-session--task-hints (file)
  "Return display-only title, repo and machine hints as a plist for FILE.
Read at most 16 KiB and parse only a complete opening Org header.  Missing,
invalid or unreadable values yield nil for title and an em dash for hints.
Launch validation is separate."
  (let ((metadata
         (condition-case nil
             (with-temp-buffer
               (insert-file-contents file nil 0 (* 16 1024))
               (my/agent-session--task-metadata))
           (error nil))))
    (cl-flet ((hint (key)
                (let ((value (and (listp metadata) (cdr (assoc key metadata)))))
                  (if (and (stringp value)
                           (not (string-empty-p (string-trim value)))
                           (not (string-match-p "[[:cntrl:]]" value)))
                      (string-trim value)
                    nil))))
      (list :title (hint "title")
            :repo (or (hint "repo") "—")
            :machine (or (hint "machine") "—")))))

(defun my/agent-session--task-annotate (annotations repo-width candidate)
  "Annotate CANDIDATE from ANNOTATIONS, padding its repo to REPO-WIDTH.
Marginalia aligns the first column across candidates; padding aligns machine."
  (when-let* ((hints (cdr (assoc candidate annotations))))
    (marginalia--fields
     ((truncate-string-to-width (car hints) (min repo-width (/ marginalia-field-width 2))
                                0 ?\s "…")
      :face 'shadow)
     ((cdr hints) :truncate 0.5 :face 'shadow))))

(defun my/agent-session--task-select ()
  "Select a task oldest first with Marginalia repo/machine annotations.
Colliding titles gain a relative-path suffix so every file is selectable."
  (let* ((root (expand-file-name "~/work/docs/tasks/" "/"))
         (candidates (my/agent-session--task-candidates root))
         (_ (unless candidates (user-error "No task notes under ~/work/docs/tasks/")))
         metadata used-labels
         (candidates
          (mapcar (lambda (entry)
                    (let* ((hints (my/agent-session--task-hints (cdr entry)))
                           (title (or (plist-get hints :title) (car entry)))
                           (label title)
                           (suffix 0))
                      (while (member label used-labels)
                        (setq suffix (1+ suffix)
                              label (format "%s [%s%s]" title
                                            (file-relative-name (cdr entry) root)
                                            (if (= suffix 1) "" (format " #%d" suffix)))))
                      (push label used-labels)
                      (push (cons (cdr entry) hints) metadata)
                      (cons (propertize label 'face 'denote-faces-title) (cdr entry))))
                  candidates))
         (annotations (mapcar (lambda (entry)
                                (let ((hints (cdr (assoc (cdr entry) metadata))))
                                  (cons (car entry) (cons (plist-get hints :repo)
                                                         (plist-get hints :machine)))))
                              candidates))
         (repo-width (apply #'max (mapcar (lambda (entry) (string-width (cadr entry)))
                                         annotations)))
         ;; Scope both metadata and registration to this invocation.  Filtering
         ;; and redisplay perform no file reads and leave other pickers alone.
         (marginalia-annotators
          (cons (list 'my-agent-session
                      (apply-partially #'my/agent-session--task-annotate annotations repo-width)
                      'none)
                marginalia-annotators))
         (table (denote-get-completion-table
                 (mapcar #'car candidates)
                 '(category . my-agent-session)
                 '(display-sort-function . identity)
                 '(cycle-sort-function . identity)))
         (selection (completing-read "Task: " table nil t))
         (entry (assoc selection candidates)))
    (unless entry (user-error "Select a task"))
    (cdr entry)))

(defun my/agent-session--task-read (file)
  "Read a saved Org task FILE and its bounded opening keyword header."
  (unless (equal (file-name-extension file) "org")
    (user-error "Task launch supports Org files only: %s" file))
  (with-temp-buffer
    ;; The read limit is in bytes, whereas decoded buffer-size is characters.
    ;; Validate the raw bounded read before decoding, or UTF-8 could silently
    ;; turn an oversized file into an apparently short, truncated snapshot.
    (insert (with-temp-buffer
              (set-buffer-multibyte nil)
              (insert-file-contents-literally file nil 0 (1+ (* 256 1024)))
              (when (> (buffer-size) (* 256 1024))
                (user-error "Task exceeds 256 KiB: %s" file))
              (decode-coding-string (buffer-string) 'utf-8)))
    (let* ((metadata (my/agent-session--task-metadata))
           (text (buffer-string))
           ;; Never mix unsaved/stale buffer content with the saved snapshot.
           (_ (when-let* ((visiting (get-file-buffer file)))
                (unless (equal text (with-current-buffer visiting
                                     (save-restriction
                                       (widen)
                                       (buffer-substring-no-properties (point-min) (point-max)))))
                  (user-error "Task buffer differs from disk; save or revert before launching"))))
           (title (cdr (assoc "title" metadata))))
      (dolist (key '("title" "repo" "machine" "model" "thinking" "skill"))
        (when-let* ((entry (assoc key metadata)))
          (unless (and (stringp (cdr entry))
                       (not (string-empty-p (string-trim (cdr entry))))
                       (not (string-match-p "[[:cntrl:]]" (cdr entry))))
            (user-error "Task %s must be a non-empty single-line string" key))))
      (let ((skill (cdr (assoc "skill" metadata))))
        (when (and skill (not (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9_-]*\\'" skill)))
          (user-error "Task skill must be a skill name, not an instruction"))
        (list :title (or (and title (not (string-empty-p title)) title)
                         (file-name-base file))
              :model (cdr (assoc "model" metadata))
              :thinking (cdr (assoc "thinking" metadata))
              :repo (cdr (assoc "repo" metadata))
              :prompt (concat
                       (format "Task snapshot read by Emacs from %s.\nThis provenance path is not necessarily accessible or editable on the agent host.\n\n" file)
                       text
                       (when skill
                         (format "\n\nLoad the %s agent skill and follow instructions." skill))))))))

(defun my/agent-session--choice (prompt choices)
  "Read an explicit required choice from CHOICES with PROMPT."
  (unless choices (user-error "No configured choices for %s" prompt))
  (let* ((vertico-preselect 'prompt)
         (value (completing-read prompt choices nil t)))
    (unless (member value choices) (user-error "Select a value for %s" prompt))
    value))

(defun my/agent-session--machine-select (&optional repo)
  "Return an explicitly selected catalogue entry, restricted to REPO if given.
A sole eligible machine is automatic; multiple machines have no default."
  (unless my/agent-machines
    (user-error "Configure machines and run M-x my/agent-catalogue-reload"))
  (let* ((eligible (cl-loop for (name . machine) in my/agent-machines
                            when (or (not repo)
                                     (cl-find repo (plist-get machine :repositories)
                                              :key (lambda (item) (plist-get item :name))
                                              :test #'equal))
                            collect name))
         (name (if (= (length eligible) 1) (car eligible)
                 (my/agent-session--choice "Machine: " (sort eligible #'string<)))))
    (assoc name my/agent-machines)))

(defun my/agent-session--worktree-options (&optional task)
  "Collect repository, machine and base choices, optionally using TASK hints.
Do not mutate Git or start an agent."
  (let* ((repos (delete-dups
                 (cl-loop for (_ . machine) in my/agent-machines
                          append (mapcar (lambda (repo) (plist-get repo :name))
                                         (plist-get machine :repositories)))))
         (hint (plist-get task :repo))
         (repo (if (member hint repos) hint
                 (my/agent-session--choice "Repository: " (sort repos #'string<))))
         (entry (my/agent-session--machine-select repo))
         (machine (cdr entry))
         (browse (file-name-as-directory (expand-file-name (plist-get machine :directory))))
         (record (cl-find repo (plist-get machine :repositories)
                          :key (lambda (item) (plist-get item :name)) :test #'equal))
         (source (concat (file-remote-p browse) (plist-get record :path)))
         (default (plist-get record :base-ref))
         (base (read-string (format-prompt "Base ref" default) nil nil default)))
    (append (list :branch nil :machine (car entry) :source source :base base :directory nil
                  :worktree t)
            task)))

(defun my/agent-session--git-result (source &rest args)
  "Run Git ARGS at SOURCE through its file handler; return (STATUS . OUTPUT)."
  (let ((default-directory (file-name-as-directory source)))
    (with-temp-buffer
      (let ((status (apply #'process-file "git" nil (list (current-buffer) t) nil args)))
        (cons status (string-trim (buffer-string)))))))

(defun my/agent-session--git (source &rest args)
  "Run Git ARGS at SOURCE, reporting failure without masking its output."
  (pcase-let ((`(,status . ,output) (apply #'my/agent-session--git-result source args)))
    (unless (eq status 0)
      (error "Git %s failed (%s): %s" (car args) status output))
    output))

(defun my/agent-session--base-resolve (source base)
  "Fetch a remote BASE or resolve a local BASE at SOURCE to a commit.
Accept branch names or explicit refs/heads/ and refs/remotes/ names."
  (let* ((remotes (split-string (my/agent-session--git source "remote") "\n" t))
         (short (string-remove-prefix "refs/remotes/" base))
         (remote (cl-find-if (lambda (r) (string-prefix-p (concat r "/") short))
                             (sort remotes (lambda (a b) (> (length a) (length b)))))))
    (cond
     ((string-prefix-p "refs/heads/" base))
     (remote
      (let ((branch (substring short (1+ (length remote)))))
        (my/agent-session--git source "check-ref-format" (concat "refs/heads/" branch))
        (my/agent-session--git source "fetch" "--no-tags" "--" remote
                               (format "+refs/heads/%s:refs/remotes/%s/%s" branch remote branch))
        (setq base (concat "refs/remotes/" short))))
     ((string-prefix-p "refs/" base)
      (user-error "Use a local branch or a configured remote branch: %s" base))
     (t (setq base (concat "refs/heads/" base))))
    (my/agent-session--git source "check-ref-format" base)
    (my/agent-session--git source "rev-parse" "--verify" "--end-of-options"
                           (concat base "^{commit}"))))

(defun my/agent-session--base36 (number)
  "Encode non-negative integer NUMBER in base 36."
  (let ((digits "0123456789abcdefghijklmnopqrstuvwxyz") (result ""))
    (while (> number 0)
      (setq result (concat (string (aref digits (% number 36))) result)
            number (/ number 36)))
    (if (string-empty-p result) "0" result)))

(defun my/agent-session--slug (title)
  "Make an ASCII TITLE slug of at most 40 characters."
  (let ((slug (string-trim (replace-regexp-in-string "[^a-z0-9]+" "-" (downcase title)) "-" "-")))
    (when (> (length slug) 40)
      (setq slug (substring slug 0 40))
      (when (string-match "-" slug)
        (setq slug (replace-regexp-in-string "-[^-]*\\'" "" slug))))
    (if (string-empty-p slug) "task" slug)))

(defun my/agent-session--name (context)
  "Choose an unused branch and sibling path for CONTEXT."
  (let* ((source (plist-get context :source))
         (parent (file-name-directory (directory-file-name source)))
         (stem (concat (if (plist-get context :prompt)
                           (my/agent-session--slug (plist-get context :title)) "adhoc")
                       "-" (my/agent-session--base36 (floor (float-time)))))
         (counter 0) name path available)
    (while (not available)
      (setq name (concat stem (if (= counter 0) "" (format "-%d" counter)))
            path (expand-file-name name parent))
      (let ((status (car (my/agent-session--git-result
                         source "show-ref" "--verify" "--quiet" (concat "refs/heads/" name)))))
        (unless (memq status '(0 1)) (error "Cannot check branch availability (%s)" status))
        (setq available (and (= status 1) (not (file-exists-p path)) (not (file-symlink-p path)))))
      (cl-incf counter))
    (setf (plist-get context :branch) name
          (plist-get context :directory) (file-name-as-directory path))))

(defun my/agent-session--report-failure (directory branch shell reason &optional uncertain)
  "Report REASON with retained DIRECTORY, BRANCH and SHELL; never remove work.
UNCERTAIN means submission may already have reached the agent."
  (message "Agent launch stopped: %s. Directory retained: %s; branch: %s; shell: %s. Nothing removed. %s"
           reason directory (or branch "none") (or shell "not returned")
           (if uncertain "Submission may have reached the agent; inspect the conversation before sending anything again."
             "Inspect the directory and shell; start agent-shell normally when ready.")))

(defun my/agent-session--launch (options)
  "Start a fresh Pi shell using OPTIONS, with launch-local callbacks only."
  (let* ((directory (plist-get options :directory))
         (branch (plist-get options :branch))
         (title (or (plist-get options :title)
                    (let ((name (file-name-nondirectory (directory-file-name (file-local-name directory)))))
                      (if (string-empty-p name) "/" name))))
         (prompt (plist-get options :prompt))
         (overrides (append (when-let* ((model (plist-get options :model))) (list (cons "model" model)))
                            (when-let* ((thinking (plist-get options :thinking))) (list (cons "thought_level" thinking)))))
         (phase 'starting) shell viewport subscriptions uncertain)
    ;; Do not retain the collected task/options through long-lived callbacks.
    (setq options nil)
    (cl-labels
        ((finish ()
           (setq prompt nil overrides nil)
           (when (buffer-live-p shell)
             (with-current-buffer shell
               (dolist (token subscriptions) (agent-shell-unsubscribe :subscription token))))
           (setq subscriptions nil))
         (fail (reason)
           (unless (memq phase '(finished failed))
             (setq phase 'failed)
             (finish)
             (my/agent-session--report-failure directory branch shell reason uncertain)))
         (configure ()
           (when (eq phase 'configuring)
             (condition-case err
                 (if-let* ((next (pop overrides)))
                     (let* ((category (car next)) (value (cdr next)) (settled nil)
                            (option (agent-shell-config-option :shell-buffer shell :category category)))
                       (unless (cl-find value (map-elt option :options)
                                        :key (lambda (item) (map-elt item :value)) :test #'equal)
                         (user-error "Agent does not support %s override %S" category value))
                       (agent-shell-set-config-option-value
                        :shell-buffer shell :category category :value value
                        :on-success (lambda (_result)
                                      (when (and (eq phase 'configuring) (not settled))
                                        (setq settled t)
                                        (condition-case err
                                            (if (equal value (agent-shell-config-option-value :shell-buffer shell :category category))
                                                (configure)
                                              (fail (format "Agent did not apply %s=%s" category value)))
                                          ((error quit) (fail (error-message-string err))))))
                        :on-failure (lambda (result)
                                      (when (and (eq phase 'configuring) (not settled))
                                        (setq settled t)
                                        (fail (format "Override %s=%s failed: %S" category value result))))))
                   (when prompt
                     (with-current-buffer shell
                       (when-let* ((process (get-buffer-process shell))
                                   (start (or (marker-position comint-accum-marker)
                                              (marker-position (process-mark process)))))
                         (when (and (< start (point-max))
                                    (not (text-property-not-all start (point-max) 'read-only nil)))
                           (user-error "Unsent shell input left intact; task was not submitted"))))
                     (when (buffer-live-p viewport)
                       (with-current-buffer viewport
                         (when (zerop (buffer-size)) (agent-shell-viewport-view-mode))))
                     (setq uncertain t)
                     (with-current-buffer shell
                       (agent-shell-insert :shell-buffer shell :text prompt :submit t :no-focus t)))
                   (unless (eq phase 'failed)
                     (setq phase 'finished)
                     (finish)
                     (message "Agent session ready: %s" (buffer-name shell))))
               ((error quit) (fail (error-message-string err))))))
         (ready ()
           (when (eq phase 'starting)
             (setq phase 'configuring)
             (configure))))
      (condition-case err
          (let* ((config (agent-shell-pi-make-agent-config))
                 (make-client (map-elt config :client-maker)))
            ;; Install failure observers at the public factory boundary, before
            ;; ACP can emit an error (including before the starter returns).
            (setf (map-elt config :client-maker)
                  (lambda (buffer)
                    (unless shell (setq shell buffer))
                    (when (and (eq phase 'starting) (eq buffer shell))
                      (with-current-buffer buffer
                        (setq-local agent-shell-cwd-function (lambda () directory)))
                      (push (agent-shell-subscribe-to
                             :shell-buffer buffer :event 'error
                             :on-event (lambda (event) (fail (format "Startup/configuration: %S" event))))
                            subscriptions)
                      (push (agent-shell-subscribe-to
                             :shell-buffer buffer :event 'clean-up
                             :on-event (lambda (_event) (fail "Shell closed before launch finished")))
                            subscriptions))
                    (funcall make-client buffer)))
            ;; Neutral bindings survive buffer switches and ignore conflicting
            ;; directory-local startup policy. No existing conversation is reused.
            (let ((returned (with-temp-buffer
                              (let ((default-directory directory)
                                    (agent-shell-cwd-function (lambda () directory))
                                    (agent-shell-session-strategy 'new)
                                    (enable-dir-local-variables nil)
                                    (agent-shell-buffer-name-format
                                     (lambda (_agent _project) (format "Pi · %s" title))))
                                (agent-shell-start :config config)))))
              (unless (eq phase 'failed)
                (setq shell returned)
                (when agent-shell-prefer-viewport-interaction
                  (setq viewport (map-elt (with-temp-buffer
                                           (agent-shell-insert :shell-buffer shell :text "")) :buffer)))
                (when (eq phase 'starting)
                  (push (agent-shell-subscribe-to :shell-buffer shell :event 'init-finished
                                                  :on-event (lambda (_event) (ready))) subscriptions)
                  (when (agent-shell-initialized-p :shell-buffer shell) (ready))))
              returned))
        ((error quit) (fail (error-message-string err)) shell)))))

(defun my/agent-session--start (context)
  "Create CONTEXT's worktree if requested, then launch its fresh Pi shell.
All choices must already be collected.  Failures never remove user work."
  (condition-case err
      (progn
        (when (plist-get context :worktree)
          (let* ((source (plist-get context :source))
                 (commit (my/agent-session--base-resolve source (plist-get context :base))))
            (my/agent-session--name context)
            (my/agent-session--git source "worktree" "add" "--no-track" "-b"
                                   (plist-get context :branch) "--"
                                   (file-local-name (plist-get context :directory)) commit)))
        (my/agent-session--launch context))
    ((error quit)
     (my/agent-session--report-failure (plist-get context :directory) (plist-get context :branch)
                                       nil (error-message-string err))
     nil)))

;;;###autoload
(defun my/agent-session-start-from-file (&optional file)
  "Start a saved task FILE in a new repository worktree.
When FILE is nil, select a task with styled completion.  Use a valid
repository hint, select an eligible machine and always confirm the base ref.
Submit the saved snapshot, skill instruction and independent optional overrides.
All selections precede Git mutation or agent startup."
  (interactive)
  (my/agent-session--start
   (my/agent-session--worktree-options
    (my/agent-session--task-read (expand-file-name (or file (my/agent-session--task-select)))))))

;;;###autoload
(defun my/agent-session-start-new-worktree ()
  "Select a repository, eligible machine and base ref; start Pi ad hoc.
Create a new sibling worktree, with no prompt, overrides or naming questions.
All selections precede Git mutation or agent startup."
  (interactive)
  (my/agent-session--start (my/agent-session--worktree-options)))

;;;###autoload
(defun my/agent-session-start-in-directory ()
  "Select a machine and directory, then start Pi ad hoc in that exact directory.
Browse from the selected machine's configured directory.  Create no worktree
and send no prompt or overrides.  All selections precede agent startup."
  (interactive)
  (let* ((entry (my/agent-session--machine-select))
         (browse (file-name-as-directory (expand-file-name (plist-get (cdr entry) :directory))))
         (directory (let ((default-directory browse))
                      (file-name-as-directory
                       (expand-file-name (read-directory-name "Directory: " browse nil t))))))
    (unless (equal (file-remote-p directory) (file-remote-p browse))
      (user-error "Choose a directory on the selected machine (%s)" (car entry)))
    (my/agent-session--start (list :branch nil :machine (car entry) :directory directory))))

(provide 'my-agent-session)
;;; my-agent-session.el ends here