package app

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
)

type fakeFinisher struct {
	agents     map[string][]herdr.Agent
	workspaces []herdr.Workspace
	calls      []string
	fail       string
	quit       bool
	keepAgent  bool
	after      []herdr.Agent
	changePath bool
	lateAgent  []herdr.Agent
	agentReads int
}

func (f *fakeFinisher) call(m herdr.Machine, op string) error {
	f.calls = append(f.calls, m.DisplayName()+":"+op)
	if f.fail == op || f.fail == m.DisplayName()+":"+op {
		return errors.New("injected error")
	}
	return nil
}

func (f *fakeFinisher) Agents(ctx context.Context, m herdr.Machine) ([]herdr.Agent, error) {
	err := f.call(m, "agents")
	if f.quit && !f.keepAgent {
		f.agentReads++
		if f.agentReads > 1 && f.lateAgent != nil {
			return f.lateAgent, err
		}
		return f.after, err
	}
	return f.agents[m.DisplayName()], err
}

func (f *fakeFinisher) Workspaces(ctx context.Context, m herdr.Machine) ([]herdr.Workspace, error) {
	if f.quit && f.changePath {
		return []herdr.Workspace{finishWorkspace("task", "Changed", "/replacement", true)}, f.call(m, "workspaces")
	}
	return f.workspaces, f.call(m, "workspaces")
}

func (f *fakeFinisher) Prompt(ctx context.Context, m herdr.Machine, name, prompt string) error {
	f.quit = true
	return f.call(m, "prompt:"+name+":"+prompt)
}

func (f *fakeFinisher) RemoveWorktree(ctx context.Context, m herdr.Machine, id, path string) error {
	return f.call(m, "remove:"+id+":"+path)
}

func finishWorkspace(id, label, path string, linked bool) herdr.Workspace {
	w := herdr.Workspace{ID: id, Label: label}
	// Reuse the JSON-shaped workspace metadata without introducing another API.
	w.Worktree = &struct {
		CheckoutPath string `json:"checkout_path"`
		Linked       bool   `json:"is_linked_worktree"`
	}{path, linked}
	return w
}

func finishFixture(m herdr.Machine) (*fakeFinisher, FinishTarget) {
	w := finishWorkspace("task", "Task title", "/repo/task", true)
	a := herdr.Agent{Name: "possum", Kind: "pi", Status: "idle", WorkspaceID: "task", PaneID: "pane", Session: &herdr.AgentSession{Agent: "pi", Kind: "path", Source: "herdr:pi", Value: "/sessions/original.jsonl"}}
	return &fakeFinisher{agents: map[string][]herdr.Agent{m.DisplayName(): {a}}, workspaces: []herdr.Workspace{w}}, FinishTarget{m, a, w}
}

func TestFinishLocalAndRemote(t *testing.T) {
	for _, m := range []herdr.Machine{herdr.Local(), {ID: "profile", Label: "remote", Enabled: true}} {
		f, target := finishFixture(m)
		if err := Finish(context.Background(), f, target); err != nil {
			t.Fatal(err)
		}
		want := []string{"agents", "workspaces", "prompt:possum:/quit", "agents", "workspaces", "agents", "remove:task:/repo/task"}
		for i := range want {
			want[i] = m.DisplayName() + ":" + want[i]
		}
		if !reflect.DeepEqual(f.calls, want) {
			t.Fatal(f.calls, want)
		}
	}
}

func TestFinishInventoryAndEligibility(t *testing.T) {
	for _, reason := range []string{"working", "not-pi", "primary", "shared", "duplicate-name", "missing-pane", "missing-workspace", "missing-session", "valid"} {
		t.Run(reason, func(t *testing.T) {
			f, _ := finishFixture(herdr.Local())
			a := &f.agents["Local"][0]
			switch reason {
			case "working":
				a.Status = "working"
			case "not-pi":
				a.Kind = "codex"
			case "primary":
				f.workspaces[0].Worktree.Linked = false
			case "shared":
				other := *a
				other.Name = "other"
				f.agents["Local"] = append(f.agents["Local"], other)
			case "duplicate-name":
				other := *a
				other.WorkspaceID = "elsewhere"
				f.agents["Local"] = append(f.agents["Local"], other)
			case "missing-pane":
				a.PaneID = ""
			case "missing-workspace":
				f.workspaces = nil
			case "missing-session":
				a.Session = nil
			}
			targets, err := FinishTargets(context.Background(), f, nil)
			if reason == "valid" {
				if err != nil || len(targets) != 1 || targets[0].Workspace.Label != "Task title" {
					t.Fatal(targets, err)
				}
			} else if len(targets) != 0 {
				t.Fatal("unsafe target offered", targets)
			}
		})
	}
	f, _ := finishFixture(herdr.Local())
	profiles := []herdr.Machine{{ID: "unconfigured", Label: "remote", Enabled: true}, {ID: "disabled", Label: "disabled"}}
	f.fail = "remote:agents"
	if _, err := FinishTargets(context.Background(), f, profiles); err == nil {
		t.Fatal("unreachable enabled server ignored")
	}
	if strings.Contains(strings.Join(f.calls, " "), "disabled:") {
		t.Fatal("inspected disabled server")
	}
}

func TestFinishSortedInventoryIncludesCurrentSession(t *testing.T) {
	t.Setenv("HERDR_ENV", "1")
	t.Setenv("HERDR_WORKSPACE_ID", "task")
	f, _ := finishFixture(herdr.Local())
	f.workspaces[0].Label = "Zebra task"
	f.workspaces = append(f.workspaces, finishWorkspace("remote-task", "Alpha task", "/remote/task", true))
	remoteAgent := f.agents["Local"][0]
	remoteAgent.WorkspaceID = "remote-task"
	remoteAgent.Status = "done"
	f.agents["remote"] = []herdr.Agent{remoteAgent}
	profiles := []herdr.Machine{{ID: "profile", Label: "remote", Enabled: true}}
	targets, err := FinishTargets(context.Background(), f, profiles)
	if err != nil || len(targets) != 2 || targets[0].Workspace.Label != "Alpha task" || targets[1].Workspace.ID != "task" {
		t.Fatal("inventory not sorted or current session excluded", targets, err)
	}
	if len(f.calls) != 4 {
		t.Fatal("status check should not add calls", f.calls)
	}
}

func TestFinishRejectsSharedCheckout(t *testing.T) {
	for _, late := range []bool{false, true} {
		f, target := finishFixture(herdr.Local())
		f.workspaces = append(f.workspaces, finishWorkspace("other-workspace", "Other task", "/repo/task", true))
		other := target.Agent
		other.Name, other.PaneID, other.WorkspaceID = "other", "other-pane", "other-workspace"
		other.Status = "working"
		if late {
			f.lateAgent = []herdr.Agent{other}
		} else {
			f.agents["Local"] = append(f.agents["Local"], other)
			targets, err := FinishTargets(context.Background(), f, nil)
			if err != nil || len(targets) != 0 {
				t.Fatal("offered shared checkout", targets, err)
			}
		}
		if err := Finish(context.Background(), f, target); err == nil {
			t.Fatal("removed shared checkout")
		}
		for _, call := range f.calls {
			if strings.Contains(call, ":remove:") {
				t.Fatal("attempted shared checkout removal", f.calls)
			}
		}
	}
}

func TestFinishFailureBoundaries(t *testing.T) {
	for _, failure := range []string{"agents", "workspaces", "prompt:possum:/quit", "remove:task:/repo/task", "stale", "restarted-session", "path-changed", "new-agent", "bad-inventory", "timeout"} {
		t.Run(failure, func(t *testing.T) {
			f, target := finishFixture(herdr.Local())
			f.fail = failure
			ctx := context.Background()
			switch failure {
			case "stale":
				f.agents["Local"][0].PaneID = "replacement"
			case "restarted-session":
				session := *target.Agent.Session
				session.Value = "/sessions/replacement.jsonl"
				f.agents["Local"][0].Session = &session
			case "path-changed":
				f.changePath = true
			case "new-agent":
				f.after = []herdr.Agent{{Name: "new", WorkspaceID: "task", PaneID: "new-pane", Status: "working"}}
			case "bad-inventory":
				f.after = []herdr.Agent{{}}
			case "timeout":
				f.keepAgent = true
				var cancel context.CancelFunc
				ctx, cancel = context.WithTimeout(ctx, 10*time.Millisecond)
				defer cancel()
			}
			if err := Finish(ctx, f, target); err == nil {
				t.Fatal("expected failure")
			}
			removals, prompts := 0, 0
			for _, call := range f.calls {
				if strings.Contains(call, ":remove:") {
					removals++
				}
				if strings.Contains(call, ":prompt:") {
					prompts++
				}
			}
			if prompts > 1 || removals > 1 || (failure != "remove:task:/repo/task" && removals != 0) {
				t.Fatal("retried or removed after uncertainty", f.calls)
			}
			if (failure == "stale" || failure == "restarted-session") && prompts != 0 {
				t.Fatal("prompted a replacement session", f.calls)
			}
		})
	}
}
