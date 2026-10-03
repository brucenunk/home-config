package herdr

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The test binary is also a fake CLI, so tests need neither a shell nor a server.
func TestMain(m *testing.M) {
	if os.Getenv("HERDSMAN_FAKE_CLI") == "1" {
		data, _ := json.Marshal(os.Args[1:])
		if err := os.WriteFile(os.Getenv("HERDSMAN_ARGS"), data, 0600); err != nil {
			panic(err)
		}
		if os.Getenv("HERDSMAN_CHILD_MODE") == "1" {
			file, err := os.OpenFile(os.Getenv("HERDSMAN_HEARTBEAT"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
			if err != nil {
				panic(err)
			}
			for {
				_, _ = file.Write([]byte("x"))
				time.Sleep(5 * time.Millisecond)
			}
		}
		if os.Getenv("HERDSMAN_SPAWN_CHILD") == "1" {
			child := exec.Command(os.Args[0])
			child.Env = append(os.Environ(), "HERDSMAN_CHILD_MODE=1")
			child.Stdout, child.Stderr = os.Stdout, os.Stderr
			if err := child.Start(); err != nil {
				panic(err)
			}
			if err := os.WriteFile(os.Getenv("HERDSMAN_CHILD_PID"), []byte(strconv.Itoa(child.Process.Pid)), 0600); err != nil {
				panic(err)
			}
			time.Sleep(time.Minute)
		}
		if os.Getenv("HERDSMAN_SLEEP") == "1" {
			time.Sleep(time.Minute)
		}
		if e := os.Getenv("HERDSMAN_STDERR"); e != "" {
			fmt.Fprint(os.Stderr, e)
			os.Exit(1)
		}
		fmt.Print(os.Getenv("HERDSMAN_RESPONSE"))
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func fakeCLI(t *testing.T, response string) (*Client, string) {
	t.Helper()
	bin, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	args := filepath.Join(t.TempDir(), "args.json")
	t.Setenv("HERDSMAN_FAKE_CLI", "1")
	t.Setenv("HERDSMAN_RESPONSE", response)
	t.Setenv("HERDSMAN_ARGS", args)
	return &Client{Binary: bin, SSH: bin, Timeout: 5 * time.Second}, args
}

func checkArgs(t *testing.T, path string, want []string) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var args []string
	if err = json.Unmarshal(data, &args); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(args, want) {
		t.Fatalf("args=%q want=%q", args, want)
	}
}

func TestInventorySchemas(t *testing.T) {
	c, path := fakeCLI(t, `[{"id":"profile","label":"remote","target":"ssh-alias","enabled":true,"session":"default"}]`)
	ms, err := c.Machines(context.Background())
	if err != nil || len(ms) != 1 || ms[0].Target != "ssh-alias" {
		t.Fatal(ms, err)
	}
	checkArgs(t, path, []string{"machine", "list", "--json"})
	t.Setenv("HERDSMAN_RESPONSE", `{"result":{"agents":[{"name":"possum","agent":"pi"}]}}`)
	as, err := c.Agents(context.Background(), ms[0])
	if err != nil || len(as) != 1 || as[0].Name != "possum" {
		t.Fatal(as, err)
	}
	checkArgs(t, path, []string{"--machine", "profile", "agent", "list"})
	t.Setenv("HERDSMAN_RESPONSE", `{"result":{"workspaces":[{"workspace_id":"opaque","label":"owner/repo","worktree":{"checkout_path":"/home/james/work/owner/repo/main","is_linked_worktree":false}}]}}`)
	ws, err := c.Workspaces(context.Background(), Local())
	if err != nil || ws[0].Worktree.CheckoutPath != "/home/james/work/owner/repo/main" {
		t.Fatal(ws, err)
	}
}

func TestCreateAndAgentArgumentBoundaries(t *testing.T) {
	c, path := fakeCLI(t, `{"result":{"workspace":{"workspace_id":"opaque-id"},"root_pane":{"pane_id":"opaque-pane"}}}`)
	m := Machine{ID: "remote-id", Label: "remote"}
	r, err := c.CreateParent(context.Background(), m, "/home/person/work/owner/repo/main", "owner/repo")
	if err != nil || r.Workspace.ID != "opaque-id" || r.RootPane.ID != "opaque-pane" {
		t.Fatal(r, err)
	}
	checkArgs(t, path, []string{"--machine", "remote-id", "workspace", "create", "--cwd", "/home/person/work/owner/repo/main", "--label", "owner/repo", "--no-focus"})
	if err = c.RenameParent(context.Background(), m, "opaque-id", "owner/repo"); err != nil {
		t.Fatal(err)
	}
	checkArgs(t, path, []string{"--machine", "remote-id", "workspace", "rename", "opaque-id", "owner/repo"})
	_, err = c.CreateWorktree(context.Background(), m, WorktreeRequest{Parent: "opaque-id", Branch: "jamesl/stamp", Base: "main", Path: "/home/person/work/owner/repo/stamp", Label: "Title; $(not a shell)"})
	if err != nil {
		t.Fatal(err)
	}
	checkArgs(t, path, []string{"--machine", "remote-id", "worktree", "create", "--workspace", "opaque-id", "--branch", "jamesl/stamp", "--base", "main", "--path", "/home/person/work/owner/repo/stamp", "--label", "Title; $(not a shell)", "--no-focus"})
	if err = c.StartAgent(context.Background(), m, "possum", "opaque-pane", "A title; 'quoted'"); err != nil {
		t.Fatal(err)
	}
	checkArgs(t, path, []string{"--machine", "remote-id", "agent", "start", "possum", "--kind", "pi", "--pane", "opaque-pane", "--timeout", "120000", "--", "--name", "A title; 'quoted'"})
	prompt := "multiline\n$(do not execute)\n'quote'"
	if err = c.Prompt(context.Background(), m, "possum", prompt); err != nil {
		t.Fatal(err)
	}
	checkArgs(t, path, []string{"--machine", "remote-id", "agent", "prompt", "possum", prompt})
}

func TestRemoteHomeAndReservedLabelRouting(t *testing.T) {
	c, path := fakeCLI(t, "/home/remote user")
	m := Machine{ID: "remote-id", Label: "local", Target: "ssh-alias"}
	home, err := c.Home(context.Background(), m)
	if err != nil || home != "/home/remote user" {
		t.Fatal(home, err)
	}
	checkArgs(t, path, []string{"-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--", "ssh-alias", `printf '%s' "$HOME"`})
	t.Setenv("HERDSMAN_RESPONSE", `{"result":{"agents":[]}}`)
	if _, err = c.Agents(context.Background(), m); err != nil {
		t.Fatal(err)
	}
	checkArgs(t, path, []string{"--machine", "remote-id", "agent", "list"})
}

func TestOrdinarySourceInventory(t *testing.T) {
	c, path := fakeCLI(t, `{"result":{"source":{"source_checkout_path":"/home/person/work/owner/repo/main","source_workspace_id":"ordinary-workspace"},"worktrees":[]}}`)
	source, err := c.Source(context.Background(), Local(), "/home/person/work/owner/repo/main")
	if err != nil || source.WorkspaceID != "ordinary-workspace" || source.CheckoutPath != "/home/person/work/owner/repo/main" {
		t.Fatal(source, err)
	}
	checkArgs(t, path, []string{"worktree", "list", "--cwd", "/home/person/work/owner/repo/main"})
}

func TestBareSourceInventory(t *testing.T) {
	c, path := fakeCLI(t, `{"result":{"source":{"repo_root":"/home/person/work/Canva/k8s/master.git","source_checkout_path":"/home/person/work/Canva/k8s/master.git","source_workspace_id":"bare-workspace"},"worktrees":[{"path":"/home/person/work/Canva/k8s/master.git","is_bare":true}]}}`)
	m := Machine{ID: "devbox-id", Label: "devbox"}
	source, err := c.Source(context.Background(), m, "/home/person/work/Canva/k8s/master.git")
	if err != nil || source.WorkspaceID != "bare-workspace" || source.CheckoutPath != "/home/person/work/Canva/k8s/master.git" {
		t.Fatal(source, err)
	}
	checkArgs(t, path, []string{"--machine", "devbox-id", "worktree", "list", "--cwd", "/home/person/work/Canva/k8s/master.git"})
}

func TestMalformedResponsesAndErrors(t *testing.T) {
	for _, response := range []string{"not json", `{}`, `{"result":null}`, `{"result":{}}`, `{"error":{"message":"blocked"}}`} {
		t.Run(response, func(t *testing.T) {
			c, _ := fakeCLI(t, response)
			if _, err := c.CreateParent(context.Background(), Local(), "/source", "repo"); err == nil {
				t.Fatal("accepted bad response")
			}
		})
	}
	c, _ := fakeCLI(t, "")
	t.Setenv("HERDSMAN_STDERR", `{"error":{"code":"agent_not_ready"}}`)
	if err := c.StartAgent(context.Background(), Local(), "possum", "pane", "title"); err == nil || !strings.Contains(err.Error(), "agent_not_ready") {
		t.Fatal(err)
	}
	if err := c.Prompt(context.Background(), Local(), "possum", "sensitive prompt"); err == nil || strings.Contains(err.Error(), "sensitive prompt") {
		t.Fatal(err)
	}
	t.Setenv("HERDSMAN_STDERR", "")
	t.Setenv("HERDSMAN_SLEEP", "1")
	c.Timeout = 30 * time.Millisecond
	if _, err := c.Workspaces(context.Background(), Local()); err == nil || !strings.Contains(err.Error(), "deadline exceeded") {
		t.Fatal(err)
	}
}

func TestTimeoutStopsOwnedDescendant(t *testing.T) {
	c, _ := fakeCLI(t, "")
	dir := t.TempDir()
	pidPath, heartbeat := filepath.Join(dir, "child.pid"), filepath.Join(dir, "heartbeat")
	t.Setenv("HERDSMAN_SPAWN_CHILD", "1")
	t.Setenv("HERDSMAN_CHILD_PID", pidPath)
	t.Setenv("HERDSMAN_HEARTBEAT", heartbeat)
	t.Cleanup(func() {
		data, _ := os.ReadFile(pidPath)
		if pid, err := strconv.Atoi(string(data)); err == nil {
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
	})
	c.Timeout = 500 * time.Millisecond
	if _, err := c.Workspaces(context.Background(), Local()); err == nil || !strings.Contains(err.Error(), "deadline exceeded") {
		t.Fatal(err)
	}
	before, err := os.ReadFile(heartbeat)
	if err != nil || len(before) == 0 {
		t.Fatal("descendant did not start", err)
	}
	time.Sleep(150 * time.Millisecond)
	after, err := os.ReadFile(heartbeat)
	if err != nil || len(after) != len(before) {
		t.Fatal("descendant survived timeout", err, len(before), len(after))
	}
}

func TestFinishOperations(t *testing.T) {
	c, path := fakeCLI(t, `{"result":{"type":"worktree_removed","workspace_id":"task","path":"/repo/task","forced":true}}`)
	m := Machine{ID: "remote-id", Label: "remote"}
	if err := c.RemoveWorktree(context.Background(), m, "task", "/repo/task"); err != nil {
		t.Fatal(err)
	}
	checkArgs(t, path, []string{"--machine", "remote-id", "worktree", "remove", "--workspace", "task", "--force"})
	for _, response := range []string{`{"result":{}}`, `{"result":{"type":"worktree_removed","workspace_id":"other","path":"/repo/task","forced":true}}`, `{"result":{"type":"worktree_removed","workspace_id":"task","path":"/repo/task","forced":false}}`} {
		t.Setenv("HERDSMAN_RESPONSE", response)
		if err := c.RemoveWorktree(context.Background(), m, "task", "/repo/task"); err == nil {
			t.Fatal("accepted unexpected removal", response)
		}
	}
}

func TestDebugCallCoverage(t *testing.T) {
	ctx := context.Background()
	for _, machine := range []Machine{Local(), {ID: "profile", Label: "remote\x1b", Target: "ssh-alias"}} {
		t.Run(machine.DisplayName(), func(t *testing.T) {
			cases := []struct {
				name, response, operation string
				call                      func(*Client) error
			}{
				{"machines", `[]`, `"machine" "list" "--json"`, func(c *Client) error { _, err := c.Machines(ctx); return err }},
				{"agents", `{"result":{"agents":[]}}`, `"agent" "list"`, func(c *Client) error { _, err := c.Agents(ctx, machine); return err }},
				{"snapshot", `{"result":{"snapshot":{"agents":[],"workspaces":[]}}}`, `"api" "snapshot"`, func(c *Client) error { _, err := c.Snapshot(ctx, machine); return err }},
				{"wait", `{"result":{"agent":{"pane_id":"p","agent_status":"unknown"}}}`, `"agent" "wait" "p"`, func(c *Client) error { return c.WaitForQuit(ctx, machine, "p") }},
				{"workspaces", `{"result":{"workspaces":[]}}`, `"workspace" "list"`, func(c *Client) error { _, err := c.Workspaces(ctx, machine); return err }},
				{"parent", `{"result":{"workspace":{"workspace_id":"w"},"root_pane":{"pane_id":"p"}}}`, `"workspace" "create"`, func(c *Client) error { _, err := c.CreateParent(ctx, machine, "/repo/main", "repo"); return err }},
				{"source", `{"result":{"source":{"source_checkout_path":"/repo/main"}}}`, `"worktree" "list"`, func(c *Client) error { _, err := c.Source(ctx, machine, "/repo/main"); return err }},
				{"rename", `{"result":{}}`, `"workspace" "rename"`, func(c *Client) error { return c.RenameParent(ctx, machine, "w", "repo") }},
				{"worktree", `{"result":{"workspace":{"workspace_id":"w"},"root_pane":{"pane_id":"p"}}}`, `"worktree" "create"`, func(c *Client) error {
					_, err := c.CreateWorktree(ctx, machine, WorktreeRequest{Parent: "w", Branch: "task", Base: "main", Path: "/repo/task", Label: "task"})
					return err
				}},
				{"start", `{"result":{}}`, `"agent" "start"`, func(c *Client) error { return c.StartAgent(ctx, machine, "possum", "p", "title") }},
				{"prompt", `{"result":{}}`, `"agent" "prompt" "possum" "<redacted>"`, func(c *Client) error { return c.Prompt(ctx, machine, "possum", "secret task\nbody") }},
				{"quit", `{"result":{}}`, `"agent" "prompt" "possum" "/quit"`, func(c *Client) error { return c.Prompt(ctx, machine, "possum", "/quit") }},
				{"focus", `{"result":{}}`, `"agent" "focus"`, func(c *Client) error { return c.Focus(ctx, machine, "possum") }},
				{"remove", `{"result":{"type":"worktree_removed","workspace_id":"w","path":"/repo/task","forced":true}}`, `"worktree" "remove"`, func(c *Client) error { return c.RemoveWorktree(ctx, machine, "w", "/repo/task") }},
			}
			for _, tc := range cases {
				t.Run(tc.name, func(t *testing.T) {
					c, _ := fakeCLI(t, tc.response)
					var output bytes.Buffer
					c.Debug = log.New(&output, "debug: ", 0)
					if err := tc.call(c); err != nil {
						t.Fatal(err)
					}
					text := output.String()
					lines := strings.Split(strings.TrimSpace(text), "\n")
					if len(lines) != 1 || !strings.Contains(lines[0], "machine=") || !strings.Contains(lines[0], "status=ok") || !strings.Contains(text, tc.operation) {
						t.Fatal("expected one completion entry", text)
					}
					elapsed := strings.Split(strings.Split(lines[0], "elapsed=")[1], " ")[0]
					if d, err := time.ParseDuration(elapsed); err != nil || d <= 0 {
						t.Fatal("invalid duration", elapsed, err)
					}
					if strings.Contains(text, "secret task") || strings.Contains(text, tc.response) || strings.ContainsRune(text, '\x1b') {
						t.Fatal("leaked payload or controls", text)
					}
					if !machine.IsLocal() && tc.name != "machines" && (!strings.Contains(text, `"--machine" "profile"`) || !strings.Contains(text, `machine="remote\x1b"`)) {
						t.Fatal("missing routing", text)
					}
				})
			}
		})
	}
}

func TestDebugSSH(t *testing.T) {
	c, _ := fakeCLI(t, "/home/secret-home")
	var output bytes.Buffer
	c.Debug = log.New(&output, "", 0)
	if _, err := c.Home(context.Background(), Machine{ID: "profile", Label: "remote", Target: "ssh-alias"}); err != nil {
		t.Fatal(err)
	}
	if text := output.String(); strings.Count(text, "tool=ssh") != 1 || strings.Count(text, "\n") != 1 || !strings.Contains(text, `"ssh-alias"`) || strings.Contains(text, "secret-home") {
		t.Fatal(text)
	}
	output.Reset()
	if _, err := c.Home(context.Background(), Local()); err != nil {
		t.Fatal(err)
	}
	if output.Len() != 0 {
		t.Fatal("local HOME should not invoke a subprocess", output.String())
	}
}

func TestDebugFailureAndDisabled(t *testing.T) {
	for _, mode := range []string{"exit", "timeout", "cancel"} {
		t.Run(mode, func(t *testing.T) {
			c, path := fakeCLI(t, "")
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			switch mode {
			case "exit":
				t.Setenv("HERDSMAN_STDERR", "secret task and response")
			case "timeout":
				t.Setenv("HERDSMAN_SLEEP", "1")
				c.Timeout = 30 * time.Millisecond
			case "cancel":
				cancel()
			}
			var output bytes.Buffer
			c.Debug = log.New(&output, "", 0)
			if err := c.Prompt(ctx, Local(), "possum", "secret task"); err == nil {
				t.Fatal("expected failure")
			}
			if text := output.String(); strings.Count(text, "\n") != 1 || !strings.Contains(text, "status=error") || !strings.Contains(text, "elapsed=") || strings.Contains(text, "secret task") || strings.Contains(text, "response") {
				t.Fatal(text)
			}
			if mode == "exit" {
				checkArgs(t, path, []string{"agent", "prompt", "possum", "secret task"})
			}
			output.Reset()
			c.Debug = nil
			_ = c.Prompt(ctx, Local(), "possum", "secret task")
			if output.Len() != 0 {
				t.Fatal("debug disabled", output.String())
			}
		})
	}
}

func TestSnapshotSchema(t *testing.T) {
	for _, response := range []string{`{}`, `{"snapshot":null}`, `{"snapshot":{}}`, `{"snapshot":{"agents":[],"workspaces":null}}`, `{"snapshot":{"agents":null,"workspaces":[]}}`} {
		c, _ := fakeCLI(t, `{"result":`+response+`}`)
		if _, err := c.Snapshot(context.Background(), Local()); err == nil {
			t.Fatal("accepted incomplete snapshot", response)
		}
	}
	c, path := fakeCLI(t, `{"result":{"snapshot":{"agents":[{"name":"possum","pane_id":"p","agent_status":"idle"}],"workspaces":[{"workspace_id":"w","worktree":{"checkout_path":"/repo/task","is_linked_worktree":true}}]}}}`)
	snapshot, err := c.Snapshot(context.Background(), Machine{ID: "profile", Label: "remote"})
	if err != nil || len(snapshot.Agents) != 1 || len(snapshot.Workspaces) != 1 || snapshot.Workspaces[0].Worktree.CheckoutPath != "/repo/task" {
		t.Fatal(snapshot, err)
	}
	checkArgs(t, path, []string{"--machine", "profile", "api", "snapshot"})
}

func TestWaitForQuitResults(t *testing.T) {
	for _, machine := range []Machine{Local(), {ID: "profile", Label: "remote"}} {
		for _, tc := range []struct {
			name, response, stderr string
			wantError              bool
		}{
			{"unknown", `{"result":{"agent":{"pane_id":"pane","agent_status":"unknown"}}}`, "", false},
			{"already-gone", "", `{"error":{"code":"agent_not_found","message":"gone"}}`, false},
			{"released", "", `{"error":{"code":"agent_not_running","message":"gone"}}`, false},
			{"stdout-error", `{"error":{"code":"agent_not_running","message":"gone"}}`, "", false},
			{"wrong-pane", `{"result":{"agent":{"pane_id":"replacement","agent_status":"unknown"}}}`, "", true},
			{"wrong-status", `{"result":{"agent":{"pane_id":"pane","agent_status":"done"}}}`, "", true},
			{"empty-result", `{"result":{}}`, "", true},
			{"malformed", "bad json", "", true},
			{"timeout", "", `{"error":{"code":"timeout","message":"timeout"}}`, true},
			{"transport", "", "SSH failure: agent_not_found", true},
			{"ambiguous", "", `{"error":{"code":"agent_target_ambiguous","message":"ambiguous"}}`, true},
			{"malformed-stderr", "", `not-json {"error":{"code":"agent_not_found"}}`, true},
		} {
			t.Run(machine.DisplayName()+"/"+tc.name, func(t *testing.T) {
				c, path := fakeCLI(t, tc.response)
				t.Setenv("HERDSMAN_STDERR", tc.stderr)
				err := c.WaitForQuit(context.Background(), machine, "pane")
				if (err != nil) != tc.wantError {
					t.Fatal("unexpected wait outcome", err)
				}
				args := []string{"agent", "wait", "pane", "--until", "unknown", "--timeout", "30000"}
				if !machine.IsLocal() {
					args = append([]string{"--machine", machine.ID}, args...)
				}
				checkArgs(t, path, args)
			})
		}
	}
}

func TestWaitForQuitCancellation(t *testing.T) {
	c, _ := fakeCLI(t, "")
	t.Setenv("HERDSMAN_SLEEP", "1")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	if err := c.WaitForQuit(ctx, Local(), "pane"); err == nil || !strings.Contains(err.Error(), "deadline exceeded") {
		t.Fatal("wait ignored caller deadline", err)
	}
}
