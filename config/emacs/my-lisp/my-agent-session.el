;;; my-agent-session.el --- Human-operated agent launches -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (denote "4.2") (yaml "1.2"))

;;; Commentary:

;; Public commands:
;;   - my/agent-session-start — launch from a task or without an initial prompt
;; This owns explicit human launches, not task capture, orchestration or cleanup.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'denote)
(require 'yaml)
(require 'agent-shell)
(require 'agent-shell-pi)
(require 'my-agent-catalogue)

(defvar vertico-preselect)

(defun my/agent-session--task-read (file)
  "Read a saved task FILE and its bounded YAML front matter.
Only the opening delimiter and its first closing delimiter delimit metadata."
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
    (goto-char (point-min))
    (unless (looking-at "---\r?\n")
      (user-error "Task requires opening YAML front matter: %s" file))
    (goto-char (match-end 0))
    (let* ((start (point))
           (end (or (and (re-search-forward "^---\r?$" nil t)
                         (match-beginning 0))
                    (user-error "Task has no closing front matter delimiter")))
           (metadata (yaml-parse-string (buffer-substring-no-properties start end)
                                        :object-type 'alist :object-key-type 'string
                                        :string-values t))
           (text (buffer-string))
           ;; Denote's public reader prefers a visiting buffer.  Do not mix its
           ;; unsaved/stale title with the saved snapshot sent to the agent.
           (_ (when-let* ((visiting (get-file-buffer file)))
                (unless (equal text (with-current-buffer visiting
                                     (save-restriction
                                       (widen)
                                       (buffer-substring-no-properties (point-min) (point-max)))))
                  (user-error "Task buffer differs from disk; save or revert before launching"))))
           (title (when (assoc "title" metadata)
                    (with-current-buffer (or (get-file-buffer file) (current-buffer))
                      (save-restriction
                        (widen)
                        (denote-retrieve-front-matter-title-value file 'markdown-yaml))))))
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

(defun my/agent-session--collect ()
  "Collect all user choices without mutating Git or starting an agent."
  (unless my/agent-machines
    (user-error "Configure machines and run M-x my/agent-catalogue-reload"))
  (let* ((mode (my/agent-session--choice "Start: " '("Task-backed" "Ad hoc")))
         (task (when (equal mode "Task-backed")
                 (my/agent-session--task-read
                  (read-file-name "Task file: " (expand-file-name "~/work/tasks/") nil t))))
         (worktree (equal (my/agent-session--choice
                          "Location: " '("New repository worktree" "Existing directory"))
                         "New repository worktree"))
         (repos (delete-dups
                 (cl-loop for (_ . machine) in my/agent-machines
                          append (mapcar (lambda (repo) (plist-get repo :name))
                                         (plist-get machine :repositories)))))
         (hint (plist-get task :repo))
         (repo (when worktree
                 (if (member hint repos) hint
                   (my/agent-session--choice "Repository: " (sort repos #'string<)))))
         (eligible (cl-loop for (name . machine) in my/agent-machines
                            when (or (not worktree)
                                     (cl-find repo (plist-get machine :repositories)
                                              :key (lambda (item) (plist-get item :name))
                                              :test #'equal))
                            collect name))
         (name (if (= (length eligible) 1) (car eligible)
                 (my/agent-session--choice "Machine: " (sort eligible #'string<))))
         (machine (cdr (assoc name my/agent-machines)))
         (browse (file-name-as-directory (expand-file-name (plist-get machine :directory))))
         (record (cl-find repo (plist-get machine :repositories)
                          :key (lambda (item) (plist-get item :name)) :test #'equal))
         (source (when worktree
                   (concat (file-remote-p browse) (plist-get record :path))))
         (base (when worktree
                 (let ((default (plist-get record :base-ref)))
                   (read-string (format-prompt "Base ref" default) nil nil default))))
         (directory (unless worktree
                      (let ((default-directory browse))
                        (file-name-as-directory
                         (expand-file-name (read-directory-name "Directory: " browse nil t)))))))
    (when (and directory
               (not (equal (file-remote-p directory) (file-remote-p browse))))
      (user-error "Choose a directory on the selected machine (%s)" name))
    (append (list :branch nil :machine name :source source :base base :directory directory
                  :worktree worktree)
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

;;;###autoload
(defun my/agent-session-start ()
  "Start a task-backed or ad hoc Pi conversation, optionally in a new worktree.
All selections precede mutation.  Git operations run on the chosen machine
through its file handler.  Failures never remove user work."
  (interactive)
  (let ((context (my/agent-session--collect)))
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
       nil))))

(provide 'my-agent-session)
;;; my-agent-session.el ends here