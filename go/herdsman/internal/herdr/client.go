// Package herdr wraps only the CLI operations used by herdsman.
package herdr

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

type Machine struct {
	ID      string `json:"id"`
	Label   string `json:"label"`
	Target  string `json:"target"`
	Session string `json:"session"`
	Enabled bool   `json:"enabled"`
}

func Local() Machine { return Machine{Label: "local", Enabled: true} }

func (m Machine) IsLocal() bool { return m.ID == "" && m.Label == "local" }

func (m Machine) DisplayName() string {
	if m.IsLocal() {
		return "Local"
	}
	return m.Label
}

type Workspace struct {
	ID        string `json:"workspace_id"`
	Label     string `json:"label"`
	PaneCount int    `json:"pane_count"`
	TabCount  int    `json:"tab_count"`
	Worktree  *struct {
		CheckoutPath string `json:"checkout_path"`
		Linked       bool   `json:"is_linked_worktree"`
	} `json:"worktree"`
}

type Agent struct {
	Name        string        `json:"name"`
	Kind        string        `json:"agent"`
	Status      string        `json:"agent_status"`
	WorkspaceID string        `json:"workspace_id"`
	PaneID      string        `json:"pane_id"`
	Session     *AgentSession `json:"agent_session"`
}

type AgentSession struct {
	Agent  string `json:"agent"`
	Kind   string `json:"kind"`
	Source string `json:"source"`
	Value  string `json:"value"`
}

type Snapshot struct {
	Agents     []Agent     `json:"agents"`
	Workspaces []Workspace `json:"workspaces"`
}

type apiError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *apiError) Error() string { return fmt.Sprintf("Herdr: %s: %s", e.Code, e.Message) }

type processError struct {
	error
	stderr string
}

func (e *processError) Unwrap() error { return e.error }

type Source struct {
	CheckoutPath string `json:"source_checkout_path"`
	WorkspaceID  string `json:"source_workspace_id"`
}

type Created struct {
	Workspace Workspace `json:"workspace"`
	RootPane  struct {
		ID string `json:"pane_id"`
	} `json:"root_pane"`
}

type WorktreeRequest struct{ Parent, Branch, Base, Path, Label string }

type Client struct {
	Binary  string
	SSH     string
	Timeout time.Duration
	Debug   *log.Logger
	// Daemon logs must not contain CLI stderr or API messages that can echo prompts.
	RedactErrors bool
}

func New() *Client { return &Client{Binary: "herdr", SSH: "ssh", Timeout: 30 * time.Second} }

// LocalEndpoint mirrors the pinned Herdr CLI's implicit socket selection.
// Herdsman does not pass --session: socket override wins over HERDR_SESSION.
func LocalEndpoint() (string, error) {
	if path, ok := os.LookupEnv("HERDR_SOCKET_PATH"); ok {
		return absoluteEndpoint(path)
	}
	dir, ok := os.LookupEnv("XDG_CONFIG_HOME")
	if !ok {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		dir = endpointChild(home, ".config")
	}
	dir = endpointChild(dir, "herdr")
	if session, ok := os.LookupEnv("HERDR_SESSION"); ok && session != "default" {
		// Match the pinned CLI before comparing routes. Empty-but-set is invalid.
		if len(session) == 0 || len(session) > 64 || session == "." || session == ".." || strings.IndexFunc(session, func(r rune) bool {
			return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '.' || r == '_' || r == '-')
		}) >= 0 {
			return "", fmt.Errorf("invalid HERDR_SESSION %q; expected 1–64 ASCII letters, digits, '.', '_' or '-', excluding '.' and '..'", session)
		}
		dir = endpointChild(endpointChild(dir, "sessions"), session)
	}
	return absoluteEndpoint(endpointChild(dir, "herdr.sock"))
}

// Compare literal absolute route spellings conservatively. Join/Abs would
// clean '..' lexically even though Unix resolves it after following symlinks.
// Different spellings of the same socket are intentionally not equated.
func endpointChild(dir, child string) string {
	if dir == "" {
		return child
	}
	if strings.HasSuffix(dir, string(os.PathSeparator)) {
		return dir + child
	}
	return dir + string(os.PathSeparator) + child
}
func absoluteEndpoint(path string) (string, error) {
	if filepath.IsAbs(path) {
		return path, nil
	}
	cwd, err := os.Getwd()
	if err != nil {
		return "", err
	}
	return endpointChild(cwd, path), nil
}

// invoke logs subprocess timing, not response contents or server-side phases.
// Do not log errors verbatim: CLI stderr may echo prompts or response payloads.
func (c *Client) invoke(ctx context.Context, m Machine, tool, binary string, timeout time.Duration, args ...string) ([]byte, error) {
	visible := append([]string(nil), args...)
	offset := 0
	if tool == "herdr" && len(visible) >= 2 && visible[0] == "--machine" {
		offset = 2
	}
	if tool == "herdr" && len(visible) >= offset+4 && visible[offset] == "agent" && visible[offset+1] == "prompt" && visible[offset+3] != "/quit" {
		visible[offset+3] = "<redacted>"
	}
	start := time.Now()
	data, err := run(ctx, timeout, binary, args...)
	if c.RedactErrors {
		err = redactProcessError(binary, err)
	}
	status := "ok"
	if err != nil {
		status = "error"
	}
	if c.Debug != nil {
		c.Debug.Printf("machine=%q tool=%s args=%q elapsed=%s status=%s", m.DisplayName(), tool, visible, time.Since(start), status)
	}
	return data, err
}

// Every subprocess is bounded. Keep stderr out of the JSON stream.
func redactProcessError(binary string, err error) error {
	var procErr *processError
	if errors.As(err, &procErr) {
		// run wraps the actual exec error with %w alongside stderr. Keep the cause
		// (including ErrWaitDelay), but never that wrapper's sensitive message.
		cause := errors.Unwrap(procErr.error)
		return &processError{fmt.Errorf("%s: %w (stderr omitted)", binary, cause), procErr.stderr}
	}
	return err
}

func run(ctx context.Context, timeout time.Duration, binary string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary, args...)
	// Own only this CLI invocation and its children, never the shared Herdr server.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	killGroup := func() error {
		if cmd.Process == nil {
			return os.ErrProcessDone
		}
		err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		if err == syscall.ESRCH {
			return os.ErrProcessDone
		}
		return err
	}
	cmd.Cancel = killGroup
	defer func() { _ = killGroup() }()
	cmd.WaitDelay = time.Second
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	output, err := cmd.Output()
	if ctx.Err() != nil {
		return nil, fmt.Errorf("%s: %w (outcome may be uncertain)", binary, ctx.Err())
	}
	if err != nil {
		return nil, &processError{fmt.Errorf("%s: %w: %s", binary, err, strings.TrimSpace(stderr.String())), stderr.String()}
	}
	return output, nil
}

func (c *Client) call(ctx context.Context, m Machine, timeout time.Duration, result any, args ...string) error {
	operation := strings.Join(args[:min(len(args), 2)], " ")
	if !m.IsLocal() {
		if m.ID == "" {
			return fmt.Errorf("remote machine %q has no saved profile ID", m.Label)
		}
		args = append([]string{"--machine", m.ID}, args...)
	}
	data, err := c.invoke(ctx, m, "herdr", c.Binary, timeout, args...)
	if err != nil {
		return fmt.Errorf("%s %s: %w", m.DisplayName(), operation, err)
	}
	var envelope struct {
		Result json.RawMessage `json:"result"`
		Error  json.RawMessage `json:"error"`
	}
	if err := json.Unmarshal(data, &envelope); err != nil {
		return fmt.Errorf("Herdr response: %w", err)
	}
	if len(envelope.Error) > 0 && string(envelope.Error) != "null" {
		var apiErr apiError
		if err := json.Unmarshal(envelope.Error, &apiErr); err != nil {
			return fmt.Errorf("Herdr response error: %w", err)
		}
		if c.RedactErrors {
			apiErr.Message = "server message omitted"
		}
		return &apiErr
	}
	if len(envelope.Result) == 0 || string(envelope.Result) == "null" {
		return fmt.Errorf("Herdr response has no result")
	}
	if result != nil {
		return json.Unmarshal(envelope.Result, result)
	}
	return nil
}

func (c *Client) Machines(ctx context.Context) ([]Machine, error) {
	data, err := c.invoke(ctx, Local(), "herdr", c.Binary, c.Timeout, "machine", "list", "--json")
	if err != nil {
		return nil, err
	}
	var machines []Machine
	if err := json.Unmarshal(data, &machines); err != nil {
		return nil, err
	}
	if machines == nil {
		return nil, fmt.Errorf("Herdr machine inventory must be an array")
	}
	for _, m := range machines {
		if m.ID == "" || m.Label == "" || m.Target == "" {
			return nil, fmt.Errorf("incomplete Herdr machine profile")
		}
	}
	return machines, nil
}

func (c *Client) Home(ctx context.Context, m Machine) (string, error) {
	return c.home(ctx, m, "")
}

// FetchBase refreshes exactly one remote-tracking ref in one destination command.
// The caller supplies the validated remote/branch selection; no Git probes or retries.
func (c *Client) FetchBase(ctx context.Context, m Machine, source, remote, branch string) error {
	args := []string{"-C", source, "fetch", "--no-tags", "--refmap=", "--", remote, "+refs/heads/" + branch + ":refs/remotes/" + remote + "/" + branch}
	if m.IsLocal() {
		_, err := c.invoke(ctx, m, "git", "git", c.Timeout, args...)
		return err
	}
	quoted := make([]string, len(args))
	for i, arg := range args {
		quoted[i] = "'" + strings.ReplaceAll(arg, "'", "'\\''") + "'"
	}
	_, err := c.invoke(ctx, m, "ssh", c.SSH, c.Timeout, "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--", m.Target, "git "+strings.Join(quoted, " "))
	return err
}

// Validate the owner directory inside the existing HOME lookup: Herdr's PTY
// launcher can silently fall back to HOME for a missing or non-directory cwd.
func (c *Client) OwnerHome(ctx context.Context, m Machine, owner string) (string, error) {
	return c.home(ctx, m, owner)
}

func (c *Client) home(ctx context.Context, m Machine, owner string) (string, error) {
	if m.IsLocal() {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		if owner != "" {
			path := filepath.Join(home, "work", owner)
			info, err := os.Stat(path)
			if err != nil {
				return "", fmt.Errorf("inspect owner directory %s: %w", path, err)
			}
			if !info.IsDir() {
				return "", fmt.Errorf("owner path %s is not a directory", path)
			}
		}
		return home, nil
	}
	command := `printf '%s' "$HOME"`
	if owner != "" {
		// Quote the suffix as shell data, never executable source.
		suffix := "'" + strings.ReplaceAll("/work/"+owner, "'", "'\\''") + "'"
		command = `test -d "$HOME"` + suffix + ` && printf '%s' "$HOME"`
	}
	// OpenSSH owns authentication and host policy.
	data, err := c.invoke(ctx, m, "ssh", c.SSH, c.Timeout, "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--", m.Target, command)
	if err != nil {
		if owner != "" {
			return "", fmt.Errorf("owner directory check/HOME lookup on %s failed (requires $HOME/work/%s to be a directory): %w", m.DisplayName(), owner, err)
		}
		return "", err
	}
	home := string(data)
	if !filepath.IsAbs(home) || strings.ContainsAny(home, "\r\n\x00") {
		return "", fmt.Errorf("invalid HOME returned by %s", m.Label)
	}
	return home, nil
}

func (c *Client) Agents(ctx context.Context, m Machine) ([]Agent, error) {
	var result struct {
		Agents []Agent `json:"agents"`
	}
	err := c.call(ctx, m, c.Timeout, &result, "agent", "list")
	if err == nil && result.Agents == nil {
		err = fmt.Errorf("Herdr response has no agent inventory")
	}
	return result.Agents, err
}

func (c *Client) Snapshot(ctx context.Context, m Machine) (Snapshot, error) {
	var result struct {
		Snapshot Snapshot `json:"snapshot"`
	}
	err := c.call(ctx, m, c.Timeout, &result, "api", "snapshot")
	if err == nil && (result.Snapshot.Agents == nil || result.Snapshot.Workspaces == nil) {
		err = fmt.Errorf("Herdr response has incomplete snapshot inventory")
	}
	return result.Snapshot, err
}

// WaitForQuit waits inside Herdr rather than repeatedly invoking the CLI.
// An unknown status or a disappeared agent is only a wakeup: the caller must
// still confirm absence and checkout safety in a fresh snapshot before removal.
func (c *Client) WaitForQuit(ctx context.Context, m Machine, pane string) error {
	var result struct {
		Agent Agent `json:"agent"`
	}
	err := c.call(ctx, m, 35*time.Second, &result, "agent", "wait", pane, "--until", "unknown", "--timeout", "30000")
	if err == nil {
		if result.Agent.PaneID != pane || result.Agent.Status != "unknown" {
			return fmt.Errorf("unexpected agent wait result")
		}
		return nil
	}
	// The CLI writes structured API errors to stderr and exits with code 1.
	// Do not mistake transport failures, timeouts, or error text for disappearance.
	var apiErr *apiError
	var procErr *processError
	var exitErr *exec.ExitError
	if errors.As(err, &procErr) && errors.As(err, &exitErr) && exitErr.ExitCode() == 1 {
		var envelope struct {
			Error *apiError `json:"error"`
		}
		if json.Unmarshal([]byte(procErr.stderr), &envelope) == nil {
			apiErr = envelope.Error
		}
	} else {
		_ = errors.As(err, &apiErr)
	}
	if apiErr != nil && (apiErr.Code == "agent_not_found" || apiErr.Code == "agent_not_running") {
		return nil
	}
	return err
}

func (c *Client) Workspaces(ctx context.Context, m Machine) ([]Workspace, error) {
	var result struct {
		Workspaces []Workspace `json:"workspaces"`
	}
	err := c.call(ctx, m, c.Timeout, &result, "workspace", "list")
	if err == nil && result.Workspaces == nil {
		err = fmt.Errorf("Herdr response has no workspace inventory")
	}
	return result.Workspaces, err
}

func (c *Client) CreateParent(ctx context.Context, m Machine, source, label string) (Created, error) {
	var result Created
	err := c.call(ctx, m, c.Timeout, &result, "workspace", "create", "--cwd", source, "--label", label, "--no-focus")
	return validateCreated(result, err)
}

// CloseWorkspace drops runtime state only; it never removes directory contents.
// Do not request group closure, which could close unrelated task workspaces.
func (c *Client) CloseWorkspace(ctx context.Context, m Machine, id string) error {
	var result struct {
		Type string `json:"type"`
	}
	err := c.call(ctx, m, c.Timeout, &result, "workspace", "close", id)
	if err == nil && result.Type != "ok" {
		err = fmt.Errorf("unexpected workspace close result; outcome may be uncertain")
	}
	return err
}

// Herdr resolves ordinary source workspaces here, even without .worktree metadata.
func (c *Client) Source(ctx context.Context, m Machine, path string) (Source, error) {
	var result struct {
		Source Source `json:"source"`
	}
	err := c.call(ctx, m, c.Timeout, &result, "worktree", "list", "--cwd", path)
	if err == nil && result.Source.CheckoutPath == "" {
		err = fmt.Errorf("Herdr response has no source checkout")
	}
	return result.Source, err
}

func (c *Client) RenameParent(ctx context.Context, m Machine, id, label string) error {
	return c.call(ctx, m, c.Timeout, nil, "workspace", "rename", id, label)
}

func (c *Client) CreateWorktree(ctx context.Context, m Machine, r WorktreeRequest) (Created, error) {
	var result Created
	err := c.call(ctx, m, c.Timeout, &result, "worktree", "create", "--workspace", r.Parent, "--branch", r.Branch, "--base", r.Base, "--path", r.Path, "--label", r.Label, "--no-focus")
	return validateCreated(result, err)
}

func validateCreated(r Created, err error) (Created, error) {
	if err == nil && (r.Workspace.ID == "" || r.RootPane.ID == "") {
		err = fmt.Errorf("creation response missing workspace/pane IDs; inspect Herdr before retrying")
	}
	return r, err
}

func (c *Client) StartAgent(ctx context.Context, m Machine, name, pane, title, model, thinking string) error {
	provider, id, ok := strings.Cut(model, "/")
	if !ok || provider == "" || id == "" || thinking == "" {
		return fmt.Errorf("model and thinking selections are required")
	}
	// Pi strips one provider prefix before matching, then prioritizes canonical
	// references over bare IDs. Preserve the exact catalogue reference for that
	// matcher, including IDs which themselves start with the provider name.
	return c.call(ctx, m, 125*time.Second, nil, "agent", "start", name, "--kind", "pi", "--pane", pane, "--timeout", "120000", "--", "--name", title, "--provider", provider, "--model", provider+"/"+model, "--thinking", thinking)
}

func (c *Client) Prompt(ctx context.Context, m Machine, name, prompt string) error {
	return c.call(ctx, m, c.Timeout, nil, "agent", "prompt", name, prompt)
}

func (c *Client) Focus(ctx context.Context, m Machine, name string) error {
	return c.call(ctx, m, c.Timeout, nil, "agent", "focus", name)
}

func (c *Client) RemoveWorktree(ctx context.Context, m Machine, workspace, path string) error {
	var result struct {
		Type        string `json:"type"`
		WorkspaceID string `json:"workspace_id"`
		Path        string `json:"path"`
		Forced      bool   `json:"forced"`
	}
	err := c.call(ctx, m, c.Timeout, &result, "worktree", "remove", "--workspace", workspace, "--force")
	if err == nil && (result.Type != "worktree_removed" || result.WorkspaceID != workspace || result.Path != path || !result.Forced) {
		err = fmt.Errorf("unexpected worktree removal result; outcome may be uncertain")
	}
	return err
}
