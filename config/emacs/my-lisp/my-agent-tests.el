;;; my-agent-tests.el --- Tests for backend dispatch helpers -*- lexical-binding: t -*-

;;; Commentary:

;; Agent backend dispatch coverage.

;;; Code:

(require 'my-task-test-support)

(declare-function my/agent-bootstrap-prompt "my-agent" (backend context))
(declare-function my/agent-backend-options-default "my-agent" (backend))
(declare-function my/agent-available-backends "my-agent" ())
(declare-function my/agent-normalize-backend "my-agent" (backend))
(declare-function my/agent-single-backend "my-agent" ())
(declare-function my/agent-default-backend-resolve "my-agent" ())
(declare-function my/agent-default-launch-config "my-agent" ())
(declare-function my/agent-format-bootstrap-prompt "my-agent" (context &optional options))
(declare-function my/agent-run-in-ghostel "my-agent" (buffer-name dir command &rest args))
(declare-function my/agent-session-resume-start "my-agent"
                  (backend session-id buffer-name dir &rest args))
(declare-function my/agent-session-start "my-agent"
                  (backend buffer-name dir &rest args))
(declare-function my/agent-pi-bootstrap-prompt "my-agent-pi" (context))
(declare-function my/agent-pi-default-options "my-agent-pi" ())
(declare-function my/agent-pi-prompt-options "my-agent-pi"
                  (&optional initial-options advanced-p))
(declare-function my/agent-pi-session-file "my-agent-pi" (task-id dir))

(defvar ghostel-buffer-name)
(defvar ghostel-kill-buffer-on-exit)
(defvar ghostel-kitty-graphics-storage-limit)
(defvar ghostel-set-title-function)

(ert-deftest my/agent-normalize-backend-supports-pi ()
  (require 'my-agent)
  (should (equal (my/agent-normalize-backend "pi") "pi"))
  (should (equal (my/agent-normalize-backend "Pi") "pi")))

(ert-deftest my/agent-normalize-backend-rejects-unknown-backends ()
  (require 'my-agent)
  (should-not (my/agent-normalize-backend "other"))
  (should-not (my/agent-normalize-backend "Other")))

(ert-deftest my/agent-available-backends-normalizes-order ()
  (require 'my-agent)
  (let ((my/agent-valid-backends '("Pi" "invalid")))
    (should (equal (my/agent-available-backends)
                   '("pi")))))

(ert-deftest my/agent-available-backends-falls-back-when-customization-is-stale ()
  (require 'my-agent)
  (let ((my/agent-valid-backends '("invalid")))
    (should (equal (my/agent-available-backends)
                   '("pi")))))

(ert-deftest my/agent-single-backend-returns-only-choice ()
  (require 'my-agent)
  (let ((my/agent-valid-backends '("Pi")))
    (should (equal (my/agent-single-backend) "pi"))))

(ert-deftest my/agent-default-backend-resolve-prefers-configured-default ()
  (require 'my-agent)
  (let ((my/agent-valid-backends '("pi"))
        (my/agent-default-backend "pi"))
    (should (equal (my/agent-default-backend-resolve) "pi"))))

(ert-deftest my/agent-default-backend-resolve-falls-back-to-first-available ()
  (require 'my-agent)
  (let ((my/agent-valid-backends '("pi"))
        (my/agent-default-backend "invalid"))
    (should (equal (my/agent-default-backend-resolve) "pi"))))

(ert-deftest my/agent-backend-options-default-dispatches-pi ()
  (require 'my-agent)
  (cl-letf (((symbol-function 'my/agent-pi-default-options)
             (lambda ()
               '(:model "gemma4:26b-mlx" :thinking "medium"))))
    (provide 'my-agent-pi)
    (should (equal (my/agent-backend-options-default "pi")
                   '(:model "gemma4:26b-mlx" :thinking "medium")))))

(ert-deftest my/agent-bootstrap-prompt-dispatches-pi ()
  (require 'my-agent)
  (let ((context '(:task-id "20260405T181044" :title "Pi support")))
    (cl-letf (((symbol-function 'my/agent-pi-bootstrap-prompt)
               (lambda (value)
                 (should (equal value context))
                 "pi bootstrap")))
      (provide 'my-agent-pi)
      (should (equal (my/agent-bootstrap-prompt "pi" context)
                     "pi bootstrap")))))

(ert-deftest my/agent-session-start-dispatches-pi ()
  (require 'my-agent)
  (let (captured)
    (cl-letf (((symbol-function 'my/agent-pi-session-start)
               (lambda (&rest args)
                 (setq captured args)
                 'pi-buffer)))
      (provide 'my-agent-pi)
      (should (eq (my/agent-session-start "pi"
                                          "agent-task-1"
                                          "/tmp/worktree"
                                          :task-id "20260405T181044"
                                          :session-id "/tmp/pi-session.jsonl"
                                          :session-name "Task title"
                                          :options '(:model "gemma4:26b-mlx"))
                  'pi-buffer))
      (should (equal (cl-subseq captured 0 3)
                     '("agent-task-1" "/tmp/worktree" "20260405T181044")))
      (should (equal (plist-get (nthcdr 3 captured) :session-id)
                     "/tmp/pi-session.jsonl"))
      (should (equal (plist-get (nthcdr 3 captured) :session-name)
                     "Task title"))
      (should (equal (plist-get (nthcdr 3 captured) :options)
                     '(:model "gemma4:26b-mlx"))))))

(ert-deftest my/agent-session-resume-start-dispatches-pi ()
  (require 'my-agent)
  (let (captured)
    (cl-letf (((symbol-function 'my/agent-pi-session-resume-start)
               (lambda (&rest args)
                 (setq captured args)
                 'pi-buffer)))
      (provide 'my-agent-pi)
      (should (eq (my/agent-session-resume-start "pi"
                                                 "/tmp/pi-session.jsonl"
                                                 "agent-task-1"
                                                 "/tmp/worktree"
                                                 :session-name "Task title"
                                                 :options '(:model "gemma4:26b-mlx"))
                  'pi-buffer))
      (should (equal (cl-subseq captured 0 3)
                     '("agent-task-1" "/tmp/worktree" "/tmp/pi-session.jsonl")))
      (should (equal (plist-get (nthcdr 3 captured) :session-name)
                     "Task title"))
      (should (equal (plist-get (nthcdr 3 captured) :options)
                     '(:model "gemma4:26b-mlx"))))))

(ert-deftest my/agent-run-in-ghostel-displays-and-execs-shell-command ()
  (require 'my-agent)
  (let* ((dir (make-temp-file "my-agent-ghostel" t))
         (buffer-name (generate-new-buffer-name " *my-agent-ghostel*"))
         (require-orig (symbol-function 'require))
         displayed captured-buffer captured-program captured-args captured-directory)
    (unwind-protect
        (cl-letf (((symbol-function 'require)
                   (lambda (feature &optional filename noerror)
                     (if (eq feature 'ghostel)
                         'ghostel
                       (funcall require-orig feature filename noerror))))
                  ((symbol-function 'ghostel-exec)
                   (lambda (buffer program &optional args)
                     (setq captured-buffer buffer
                           captured-program program
                           captured-args args
                           captured-directory default-directory)
                     (let ((proc (start-process "my-agent-ghostel-test" buffer "true")))
                       (set-process-query-on-exit-flag proc nil)
                       proc))))
          (let ((buffer (my/agent-run-in-ghostel
                         buffer-name
                         dir
                         "exec pi --help"
                         :display-fn (lambda (buffer)
                                       (setq displayed buffer)))))
            (should (buffer-live-p buffer))
            (should (eq displayed buffer))
            (should (eq captured-buffer buffer))
            (should (equal captured-program "/bin/sh"))
            (should (equal captured-args '("-lc" "exec pi --help")))
            (should (equal captured-directory (file-name-as-directory dir)))
            (with-current-buffer buffer
              (should (equal default-directory (file-name-as-directory dir)))
              (should-not ghostel-kill-buffer-on-exit)
              (should (zerop ghostel-kitty-graphics-storage-limit))
              (should-not ghostel-set-title-function))))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer))
      (delete-directory dir t))))

(ert-deftest my/agent-run-in-ghostel-falls-back-when-exec-api-is-missing ()
  (require 'my-agent)
  (let* ((dir (make-temp-file "my-agent-ghostel-fallback" t))
         (buffer-name (generate-new-buffer-name " *my-agent-ghostel-fallback*"))
         (require-orig (symbol-function 'require))
         (had-ghostel-exec (fboundp 'ghostel-exec))
         (ghostel-exec-orig (and had-ghostel-exec (symbol-function 'ghostel-exec)))
         displayed sent captured-shell-buffer)
    (unwind-protect
        (progn
          (when had-ghostel-exec
            (fmakunbound 'ghostel-exec))
          (cl-letf (((symbol-function 'require)
                     (lambda (feature &optional filename noerror)
                       (if (eq feature 'ghostel)
                           'ghostel
                         (funcall require-orig feature filename noerror))))
                    ((symbol-function 'ghostel)
                     (lambda (&optional _arg)
                       (pop-to-buffer ghostel-buffer-name)
                       (setq captured-shell-buffer (current-buffer))
                       (let ((proc (start-process "my-agent-ghostel-fallback-test"
                                                  (current-buffer)
                                                  "cat")))
                         (set-process-query-on-exit-flag proc nil)
                         proc)))
                    ((symbol-function 'process-send-string)
                     (lambda (_process string)
                       (push string sent))))
            (let ((buffer (my/agent-run-in-ghostel
                           buffer-name
                           dir
                           "exec pi --help"
                           :display-fn (lambda (buffer)
                                         (setq displayed buffer)))))
              (should (eq displayed buffer))
              (should (eq buffer captured-shell-buffer))
              (should (equal (nreverse sent) '("exec pi --help" "\n")))
              (with-current-buffer buffer
                (should (equal default-directory (file-name-as-directory dir)))
                (should-not ghostel-kill-buffer-on-exit)
                (should (zerop ghostel-kitty-graphics-storage-limit))
                (should-not ghostel-set-title-function)))))
      (when had-ghostel-exec
        (fset 'ghostel-exec ghostel-exec-orig))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer))
      (delete-directory dir t))))

(ert-deftest my/agent-run-in-ghostel-exec-path-sizes-hidden-launch-from-window ()
  (require 'my-agent)
  (let* ((dir (make-temp-file "my-agent-ghostel-hidden" t))
         (buffer-name (generate-new-buffer-name " *my-agent-ghostel-hidden*"))
         (require-orig (symbol-function 'require))
         captured-window-buffer)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer (get-buffer-create " *my-agent-ghostel-origin*"))
          (cl-letf (((symbol-function 'require)
                     (lambda (feature &optional filename noerror)
                       (if (eq feature 'ghostel)
                           'ghostel
                         (funcall require-orig feature filename noerror))))
                    ((symbol-function 'ghostel-exec)
                     (lambda (buffer _program &optional _args)
                       (setq captured-window-buffer
                             (when-let ((window (get-buffer-window buffer t)))
                               (window-buffer window)))
                       (let ((proc (start-process "my-agent-ghostel-hidden-test"
                                                  buffer
                                                  "true")))
                         (set-process-query-on-exit-flag proc nil)
                         proc))))
            (let ((buffer (my/agent-run-in-ghostel
                           buffer-name
                           dir
                           "exec pi --help"
                           :display-fn #'ignore)))
              (should (buffer-live-p buffer))
              (should (eq captured-window-buffer buffer)))))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer))
      (delete-directory dir t))))

(ert-deftest my/agent-run-in-ghostel-fallback-supports-default-display ()
  (require 'my-agent)
  (let* ((dir (make-temp-file "my-agent-ghostel-default-display" t))
         (buffer-name (generate-new-buffer-name " *my-agent-ghostel-default-display*"))
         (require-orig (symbol-function 'require))
         (had-ghostel-exec (fboundp 'ghostel-exec))
         (ghostel-exec-orig (and had-ghostel-exec (symbol-function 'ghostel-exec))))
    (unwind-protect
        (progn
          (when had-ghostel-exec
            (fmakunbound 'ghostel-exec))
          (cl-letf (((symbol-function 'require)
                     (lambda (feature &optional filename noerror)
                       (if (eq feature 'ghostel)
                           'ghostel
                         (funcall require-orig feature filename noerror))))
                    ((symbol-function 'ghostel)
                     (lambda (&optional _arg)
                       (pop-to-buffer ghostel-buffer-name)
                       (let ((proc (start-process "my-agent-ghostel-default-display-test"
                                                  (current-buffer)
                                                  "cat")))
                         (set-process-query-on-exit-flag proc nil)
                         proc)))
                    ((symbol-function 'process-send-string)
                     (lambda (_process _string) nil)))
            (let ((buffer (my/agent-run-in-ghostel
                           buffer-name
                           dir
                           "exec pi --help")))
              (should (buffer-live-p buffer))
              (should (equal (buffer-name buffer) buffer-name)))))
      (when had-ghostel-exec
        (fset 'ghostel-exec ghostel-exec-orig))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer))
      (delete-directory dir t))))

(ert-deftest my/agent-format-bootstrap-prompt-omits-generic-tail-when-note-content-present ()
  (require 'my-agent)
  (should (equal (my/agent-format-bootstrap-prompt
                  '(:task-id "20260324T082727"
                    :title "Generic task"
                    :task-note-content "## Context\n\nDo the thing."
                    :agents-files ("/Users/jamesl/work/AGENTS.md")))
                 (concat
                  "**Task:** Generic task\n\n"
                  "Read these AGENTS.md files: `/Users/jamesl/work/AGENTS.md`.\n\n"
                  "Task identifier: `20260324T082727`.\n\n"
                  "## Context\n\nDo the thing."))))

(ert-deftest my/agent-default-launch-config-uses-pi-default-backend ()
  (require 'my-agent)
  (let ((my/agent-valid-backends '("pi"))
        (my/agent-default-backend "pi"))
    (cl-letf (((symbol-function 'my/agent-backend-options-default)
               (lambda (backend)
                 (should (equal backend "pi"))
                 '(:model "gpt-5.6-sol" :thinking "medium"))))
      (should (equal (my/agent-default-launch-config)
                     '(:backend "pi"
                       :options (:model "gpt-5.6-sol" :thinking "medium")))))))

(ert-deftest my/agent-pi-bootstrap-prompt-omits-explicit-agents-instructions ()
  (ignore-errors (unload-feature 'my-agent-pi t))
  (load "my-agent-pi" nil t)
  (should (equal (my/agent-pi-bootstrap-prompt
                  '(:task-id "20260405T181044"
                    :title "Pi task"
                    :skill "task-workflow-v3"
                    :task-note-content "## Context\n\nPi task body."
                    :agents-files
                    ("/Users/jamesl/work/AGENTS.md"
                     "/Users/jamesl/work/brucenunk/AGENTS.md")))
                 (concat
                  "**Task:** Pi task\n\n"
                  "Task identifier: `20260405T181044`.\n\n"
                  "## Context\n\nPi task body.\n\n"
                  "Load the `task-workflow-v3` skill and follow its instructions."))))

(ert-deftest my/agent-pi-default-options-defer-to-pi-model-default ()
  (ignore-errors (unload-feature 'my-agent-pi t))
  (load "my-agent-pi" nil t)
  (should (equal (my/agent-pi-default-options)
                 '(:model nil :thinking "medium"))))

(ert-deftest my/agent-pi-prompt-options-advanced-accepts-proxy-model ()
  (ignore-errors (unload-feature 'my-agent-pi t))
  (load "my-agent-pi" nil t)
  (let ((answers '("gpt-5.6-terra" "high"))
        (my/agent-pi-valid-models
         '("gpt-5.6-sol" "gpt-5.6-terra" "gpt-5.6-luna"
           "fable-5" "opus-5" "sonnet-5"
           "ornith:35b" "gemma4:26b-mlx")))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (prompt collection &rest _args)
                 (when (string= prompt "Pi model (advanced): ")
                   (should (equal (all-completions "" collection)
                                  '("gpt-5.6-sol"
                                    "gpt-5.6-terra"
                                    "gpt-5.6-luna"
                                    "fable-5"
                                    "opus-5"
                                    "sonnet-5"
                                    "ornith:35b"
                                    "gemma4:26b-mlx"
                                    "none"))))
                 (prog1 (car answers)
                   (setq answers (cdr answers))))))
      (should (equal (my/agent-pi-prompt-options nil t)
                     '(:model "gpt-5.6-terra" :thinking "high"))))))

(ert-deftest my/agent-pi-session-file-uses-default-tree-explicit-path ()
  (ignore-errors (unload-feature 'my-agent-pi t))
  (load "my-agent-pi" nil t)
  (let ((my/agent-pi-session-directory "/tmp/pi-sessions/"))
    (cl-letf (((symbol-function 'format-time-string)
               (lambda (&rest _args)
                 "20260422T031929929Z")))
      (should (equal (my/agent-pi-session-file "20260405T181044" "/tmp/worktree")
                     "/tmp/pi-sessions/--tmp-worktree--/2026-04-22T03-19-29-929Z_20260405T181044.jsonl")))))

(ert-deftest my/agent-pi-session-subdirectory-normalizes-managed-worktrees-to-repo ()
  (ignore-errors (unload-feature 'my-agent-pi t))
  (load "my-agent-pi" nil t)
  (let ((my/agent-pi-session-directory "/tmp/pi-sessions/"))
    (should (equal (my/agent-pi-session-subdirectory
                    "/Users/jamesl/work/Example/project/a")
                   "/tmp/pi-sessions/--Users-jamesl-work-Example-project--/"))
    (should (equal (my/agent-pi-session-subdirectory
                    "/Users/jamesl/work/Example/project")
                   "/tmp/pi-sessions/--Users-jamesl-work-Example-project--/"))
    (should (equal (my/agent-pi-session-subdirectory
                    "/tmp/worktree")
                   "/tmp/pi-sessions/--tmp-worktree--/"))))

(ert-deftest my/agent-pi-session-timestamp-normalize-accepts-compact-and-dashed-forms ()
  (ignore-errors (unload-feature 'my-agent-pi t))
  (load "my-agent-pi" nil t)
  (should (equal (my/agent-pi-session-timestamp-normalize "20260422T031929929Z")
                 "20260422T031929929Z"))
  (should (equal (my/agent-pi-session-timestamp-normalize "2026-04-22T03-19-29-929Z")
                 "20260422T031929929Z"))
  (should-not (my/agent-pi-session-timestamp-normalize "not-a-token")))

(ert-deftest my/agent-pi-session-file-for-timestamp-reconstructs-deterministic-path ()
  (ignore-errors (unload-feature 'my-agent-pi t))
  (load "my-agent-pi" nil t)
  (let ((my/agent-pi-session-directory "/tmp/pi-sessions/"))
    (should (equal (my/agent-pi-session-file-for-timestamp
                    "20260405T181044"
                    "/tmp/worktree"
                    "20260422T031929929Z")
                   "/tmp/pi-sessions/--tmp-worktree--/2026-04-22T03-19-29-929Z_20260405T181044.jsonl"))))

(ert-deftest my/agent-pi-session-timestamp-extracts-compact-token ()
  (ignore-errors (unload-feature 'my-agent-pi t))
  (load "my-agent-pi" nil t)
  (should (equal (my/agent-pi-session-timestamp
                  "/tmp/pi-sessions/--tmp-worktree--/2026-04-22T03-19-29-929Z_20260405T181044.jsonl")
                 "20260422T031929929Z")))

(ert-deftest my/agent-pi-session-resolve-reconstructs-explicit-session-file-from-timestamp ()
  (ignore-errors (unload-feature 'my-agent-pi t))
  (load "my-agent-pi" nil t)
  (let ((my/agent-pi-session-directory "/tmp/pi-sessions/"))
    (should (equal (my/agent-pi-session-resolve "20260405T181044"
                                                "/Users/jamesl/work/brucenunk/home-config/b"
                                                "20260422T021929929Z")
                   '(:id "/tmp/pi-sessions/--Users-jamesl-work-brucenunk-home-config--/2026-04-22T02-19-29-929Z_20260405T181044.jsonl")))))

(ert-deftest my/agent-pi-session-resolve-rejects-invalid-timestamp ()
  (ignore-errors (unload-feature 'my-agent-pi t))
  (load "my-agent-pi" nil t)
  (should-error (my/agent-pi-session-resolve "20260405T181044"
                                             "/tmp/worktree"
                                             "/tmp/not-a-timestamp.jsonl")
                :type 'user-error))

(ert-deftest my/agent-pi-command-argv-uses-provided-default-tree-session-file ()
  (ignore-errors (unload-feature 'my-agent-pi t))
  (load "my-agent-pi" nil t)
  (let ((my/agent-pi-session-directory "/tmp/pi-sessions/")
        (my/agent-pi-valid-models '("gemma4:26b-mlx")))
    (cl-letf (((symbol-function 'format-time-string)
               (lambda (&rest _args)
                 "20260422T031929929Z")))
      (should (equal (my/agent-pi--command-argv "/tmp/worktree"
                                                '(:model "gemma4:26b-mlx" :thinking "medium")
                                                "/tmp/pi-sessions/--tmp-worktree--/2026-04-22T03-19-29-929Z_20260405T181044.jsonl"
                                                "bootstrap"
                                                "Task title")
                     '("pi"
                       "--model" "gemma4:26b-mlx"
                       "--thinking" "medium"
                       "--session" "/tmp/pi-sessions/--tmp-worktree--/2026-04-22T03-19-29-929Z_20260405T181044.jsonl"
                       "--name" "Task title"
                       "bootstrap"))))))

(ert-deftest my/agent-pi-session-file-returns-new-path-on-separate-calls ()
  (ignore-errors (unload-feature 'my-agent-pi t))
  (load "my-agent-pi" nil t)
  (let ((my/agent-pi-session-directory "/tmp/pi-sessions/")
        (timestamps '("20260422T031929929Z" "20260422T032000000Z")))
    (cl-letf (((symbol-function 'format-time-string)
               (lambda (&rest _args)
                 (prog1 (car timestamps)
                   (setq timestamps (or (cdr timestamps) timestamps))))))
      (should (equal (my/agent-pi-session-file "20260405T181044" "/tmp/worktree")
                     "/tmp/pi-sessions/--tmp-worktree--/2026-04-22T03-19-29-929Z_20260405T181044.jsonl"))
      (should (equal (my/agent-pi-session-file "20260405T181044" "/tmp/worktree")
                     "/tmp/pi-sessions/--tmp-worktree--/2026-04-22T03-20-00-000Z_20260405T181044.jsonl")))))

(ert-deftest my/agent-pi-base-argv-includes-session-file-and-name ()
  (ignore-errors (unload-feature 'my-agent-pi t))
  (load "my-agent-pi" nil t)
  (let ((my/agent-pi-valid-models '("gemma4:26b-mlx")))
    (should (equal (my/agent-pi--base-argv "/tmp/worktree"
                                           '(:model "gemma4:26b-mlx" :thinking "medium")
                                           "/tmp/pi-sessions/20260405T181044.jsonl"
                                           "Task title")
                   '("pi"
                     "--model" "gemma4:26b-mlx"
                     "--thinking" "medium"
                     "--session" "/tmp/pi-sessions/20260405T181044.jsonl"
                     "--name" "Task title")))))

(ert-deftest my/agent-pi-base-argv-skips-session-name-flag-when-blank ()
  (ignore-errors (unload-feature 'my-agent-pi t))
  (load "my-agent-pi" nil t)
  (let ((my/agent-pi-valid-models '("gemma4:26b-mlx")))
    (should (equal (my/agent-pi--base-argv "/tmp/worktree"
                                           '(:model "gemma4:26b-mlx" :thinking "medium")
                                           "/tmp/pi-sessions/20260405T181044.jsonl"
                                           "  ")
                   '("pi"
                     "--model" "gemma4:26b-mlx"
                     "--thinking" "medium"
                     "--session" "/tmp/pi-sessions/20260405T181044.jsonl")))))

(ert-deftest my/agent-pi-base-argv-ignores-invalid-models ()
  (ignore-errors (unload-feature 'my-agent-pi t))
  (load "my-agent-pi" nil t)
  (should (equal (my/agent-pi--base-argv "/tmp/worktree"
                                         '(:model "missing" :thinking "medium")
                                         "/tmp/pi-sessions/20260405T181044.jsonl")
                 '("pi"
                   "--thinking" "medium"
                   "--session" "/tmp/pi-sessions/20260405T181044.jsonl"))))

(ert-deftest my/agent-pi-resume-argv-preserves-existing-session-name ()
  (ignore-errors (unload-feature 'my-agent-pi t))
  (load "my-agent-pi" nil t)
  (let ((session-file (make-temp-file "my-agent-pi-session" nil ".jsonl"))
        (my/agent-pi-valid-models '("gemma4:26b-mlx")))
    (unwind-protect
        (progn
          (with-temp-file session-file
            (insert "{\"type\":\"session_info\",\"name\":\"Custom name\"}\n"))
          (should (equal (my/agent-pi--resume-argv "/tmp/worktree"
                                                  session-file
                                                  '(:model "gemma4:26b-mlx" :thinking "medium")
                                                  nil
                                                  "Task title")
                         (list "pi"
                               "--model" "gemma4:26b-mlx"
                               "--thinking" "medium"
                               "--session" session-file))))
      (delete-file session-file))))

(ert-deftest my/agent-pi-resume-argv-names-missing-session-file ()
  (ignore-errors (unload-feature 'my-agent-pi t))
  (load "my-agent-pi" nil t)
  (let ((session-file (expand-file-name "missing.jsonl"
                                        (make-temp-file "my-agent-pi-session" t)))
        (my/agent-pi-valid-models '("gemma4:26b-mlx")))
    (should (equal (my/agent-pi--resume-argv "/tmp/worktree"
                                             session-file
                                             '(:model "gemma4:26b-mlx" :thinking "medium")
                                             nil
                                             "Task title")
                   (list "pi"
                         "--model" "gemma4:26b-mlx"
                         "--thinking" "medium"
                         "--session" session-file
                         "--name" "Task title")))))

(ert-deftest my/agent-pi-base-argv-applies-model-route-and-thinking-compatibility ()
  (ignore-errors (unload-feature 'my-agent-pi t))
  (load "my-agent-pi" nil t)
  (let ((my/agent-pi-valid-models '("gpt-5.6-sol"))
        (my/agent-pi-model-routes '(("gpt-5.6-sol" . "proxy-openai/gpt-5.6-sol")))
        (my/agent-pi-minimal-thinking-unsupported-models '("gpt-5.6-sol")))
    (should (equal (my/agent-pi--base-argv "/tmp/worktree"
                                           '(:model "gpt-5.6-sol" :thinking "minimal")
                                           "/tmp/pi-sessions/20260405T181044.jsonl")
                   '("pi"
                     "--model" "proxy-openai/gpt-5.6-sol"
                     "--thinking" "low"
                     "--session" "/tmp/pi-sessions/20260405T181044.jsonl")))))

(ert-deftest my/agent-pi-base-argv-applies-model-alias-route ()
  (ignore-errors (unload-feature 'my-agent-pi t))
  (load "my-agent-pi" nil t)
  (let ((my/agent-pi-valid-models '("opus-5"))
        (my/agent-pi-model-routes '(("opus-5" . "bedrock/global.example.opus-5"))))
    (should (equal (my/agent-pi--base-argv "/tmp/worktree"
                                           '(:model "opus-5" :thinking "minimal")
                                           "/tmp/pi-sessions/20260405T181044.jsonl")
                   '("pi"
                     "--model" "bedrock/global.example.opus-5"
                     "--thinking" "minimal"
                     "--session" "/tmp/pi-sessions/20260405T181044.jsonl")))))

(ert-deftest my/agent-pi-session-resolve-preserves-deterministic-path-even-before-first-write ()
  (ignore-errors (unload-feature 'my-agent-pi t))
  (load "my-agent-pi" nil t)
  (let ((my/agent-pi-session-directory "/tmp/pi-sessions/"))
    (should (equal (my/agent-pi-session-resolve
                    "20260405T181044"
                    "/tmp/worktree"
                    "20260422T031929929Z")
                   '(:id "/tmp/pi-sessions/--tmp-worktree--/2026-04-22T03-19-29-929Z_20260405T181044.jsonl")))))

(provide 'my-agent-tests)
;;; my-agent-tests.el ends here
