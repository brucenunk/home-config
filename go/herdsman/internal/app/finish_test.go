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
	waitErr    error
	snapshots  []herdr.Snapshot
	onSnapshot func()
}

func (f *fakeFinisher) call(m herdr.Machine, op string) error {
	f.calls = append(f.calls, m.DisplayName()+":"+op)
	if f.fail == op || f.fail == m.DisplayName()+":"+op {
		return errors.New("injected error")
	}
	return nil
}

func (f *fakeFinisher) Snapshot(ctx context.Context, m herdr.Machine) (herdr.Snapshot, error) {
	snapshot := herdr.Snapshot{Agents: f.agents[m.DisplayName()], Workspaces: f.workspaces}
	if f.quit && !f.keepAgent {
		snapshot.Agents = f.after
	}
	if f.quit && f.changePath {
		snapshot.Workspaces = []herdr.Workspace{finishWorkspace("task", "Changed", "/replacement", true)}
	}
	if f.quit && len(f.snapshots) > 0 {
		snapshot, f.snapshots = f.snapshots[0], f.snapshots[1:]
	}
	if f.quit && f.onSnapshot != nil {
		f.onSnapshot()
	}
	return snapshot, f.call(m, "snapshot")
}

func (f *fakeFinisher) WaitForQuit(ctx context.Context, m herdr.Machine, pane string) error {
	if err := f.call(m, "wait:"+pane); err != nil {
		return err
	}
	return f.waitErr
}

func (f *fakeFinisher) Prompt(ctx context.Context, m herdr.Machine, name, prompt string) error {
	f.quit = true
	return f.call(m, "prompt:"+name+":"+prompt)
}

func (f *fakeFinisher) RemoveWorktree(ctx context.Context, m herdr.Machine, id, path string) error {
	return f.call(m, "remove:"+id+":"+path)
}

func (f *fakeFinisher) CloseWorkspace(ctx context.Context, m herdr.Machine, id string) error {
	return f.call(m, "close:"+id)
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
		want := []string{"prompt:possum:/quit", "wait:pane", "snapshot", "remove:task:/repo/task"}
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
	f.fail = "remote:snapshot"
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
	if len(f.calls) != 2 {
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
			f.after = []herdr.Agent{other}
		} else {
			f.agents["Local"] = append(f.agents["Local"], other)
			targets, err := FinishTargets(context.Background(), f, nil)
			if err != nil || len(targets) != 0 {
				t.Fatal("offered shared checkout", targets, err)
			}
			f.after = []herdr.Agent{other}
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
	for _, failure := range []string{"snapshot", "wait:pane", "prompt:possum:/quit", "remove:task:/repo/task", "still-present", "path-changed", "new-agent", "reused-name", "bad-inventory", "timeout", "cancelled"} {
		t.Run(failure, func(t *testing.T) {
			f, target := finishFixture(herdr.Local())
			f.fail = failure
			ctx := context.Background()
			switch failure {
			case "still-present":
				f.keepAgent = true
				var cancel context.CancelFunc
				ctx, cancel = context.WithTimeout(ctx, 20*time.Millisecond)
				defer cancel()
			case "path-changed":
				f.changePath = true
			case "new-agent":
				f.after = []herdr.Agent{{Name: "new", WorkspaceID: "task", PaneID: "new-pane", Status: "working"}}
			case "reused-name":
				f.after = []herdr.Agent{{Name: "possum", WorkspaceID: "other", PaneID: "new-pane", Status: "working"}}
			case "bad-inventory":
				f.after = []herdr.Agent{{}}
			case "timeout":
				f.waitErr = context.DeadlineExceeded
			case "cancelled":
				f.waitErr = context.Canceled
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
		})
	}
}

func TestFinishSelectionAuthorizesQuitWithoutRecheck(t *testing.T) {
	f, target := finishFixture(herdr.Local())
	// Inventory has changed since selection. The selected name is deliberately
	// prompted without inspecting it again; final inspection still gates removal.
	f.agents["Local"][0].PaneID = "replacement"
	f.agents["Local"][0].Status = "working"
	if err := Finish(context.Background(), f, target); err != nil {
		t.Fatal(err)
	}
	if len(f.calls) != 4 || f.calls[0] != "Local:prompt:possum:/quit" {
		t.Fatal("unexpected pre-quit check", f.calls)
	}
}

func TestFinishWaitsForInventoryDisappearance(t *testing.T) {
	for _, m := range []herdr.Machine{herdr.Local(), {ID: "profile", Label: "remote", Enabled: true}} {
		f, target := finishFixture(m)
		original := target.Agent
		original.Status = "unknown" // Status changes do not make a new session.
		f.snapshots = []herdr.Snapshot{{Agents: []herdr.Agent{original}, Workspaces: f.workspaces}}
		if err := Finish(context.Background(), f, target); err != nil {
			t.Fatal("failed to tolerate release-before-exit", err)
		}
		want := []string{"prompt:possum:/quit", "wait:pane", "snapshot", "snapshot", "remove:task:/repo/task"}
		for i := range want {
			want[i] = m.DisplayName() + ":" + want[i]
		}
		if !reflect.DeepEqual(f.calls, want) {
			t.Fatal(f.calls, want)
		}
	}
}

func TestFinishStopsOnChangesDuringRetry(t *testing.T) {
	for _, change := range []string{"pane", "session", "missing-session", "name", "kind", "missing-kind", "workspace", "additional-agent", "checkout"} {
		t.Run(change, func(t *testing.T) {
			f, target := finishFixture(herdr.Local())
			first := herdr.Snapshot{Agents: []herdr.Agent{target.Agent}, Workspaces: f.workspaces}
			second := herdr.Snapshot{Agents: []herdr.Agent{target.Agent}, Workspaces: f.workspaces}
			a := &second.Agents[0]
			switch change {
			case "pane":
				a.PaneID = "replacement"
			case "session":
				session := *a.Session
				session.Value = "/sessions/replacement.jsonl"
				a.Session = &session
			case "missing-session":
				a.Session = nil
			case "name":
				a.Name = "replacement"
			case "kind":
				a.Kind = "codex"
			case "missing-kind":
				a.Kind = ""
			case "workspace":
				a.WorkspaceID = "elsewhere"
			case "additional-agent":
				other := *a
				other.Name, other.PaneID = "other", "other-pane"
				second.Agents = append(second.Agents, other)
			case "checkout":
				second.Workspaces = []herdr.Workspace{finishWorkspace("task", "Changed", "/replacement", true)}
			}
			f.snapshots = []herdr.Snapshot{first, second}
			err := Finish(context.Background(), f, target)
			if err == nil || !strings.Contains(err.Error(), "no removal attempted") || len(f.calls) != 4 || f.calls[3] != "Local:snapshot" {
				t.Fatal("did not stop immediately on changed inventory", err, f.calls)
			}
		})
	}
}

func TestFinishCancellationDuringSnapshotRetry(t *testing.T) {
	f, target := finishFixture(herdr.Local())
	f.keepAgent = true
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	f.onSnapshot = cancel
	err := Finish(ctx, f, target)
	if !errors.Is(err, context.Canceled) || len(f.calls) != 3 {
		t.Fatal("retry ignored cancellation or attempted removal", err, f.calls)
	}
}

func TestFinishExitConfirmationHasOneDeadline(t *testing.T) {
	f, target := finishFixture(herdr.Local())
	f.keepAgent = true
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	err := Finish(ctx, f, target)
	if !errors.Is(err, context.DeadlineExceeded) || !strings.Contains(err.Error(), "selected agent still present") || len(f.calls) != 3 {
		t.Fatal("retry reset deadline or attempted removal", err, f.calls)
	}
}

func TestFinishInspectionErrorDuringRetry(t *testing.T) {
	f, target := finishFixture(herdr.Local())
	f.keepAgent = true
	reads := 0
	f.onSnapshot = func() {
		reads++
		if reads == 2 {
			f.fail = "snapshot"
		}
	}
	err := Finish(context.Background(), f, target)
	if err == nil || !strings.Contains(err.Error(), "recheck workspace and agents") || reads != 2 || len(f.calls) != 4 {
		t.Fatal("retried inspection error or attempted removal", err, f.calls)
	}
}

func TestFinishRetriesCapturedDrainingRecord(t *testing.T) {
	for _, m := range []herdr.Machine{herdr.Local(), {ID: "profile", Label: "remote", Enabled: true}} {
		f, target := finishFixture(m)
		// Captured from a live Pi shutdown: the original name and handles remain,
		// but the agent kind is empty and agent_session is null for a short time.
		draining := herdr.Agent{Name: "possum", WorkspaceID: "task", PaneID: "pane", Status: "idle"}
		f.snapshots = []herdr.Snapshot{{Agents: []herdr.Agent{draining}, Workspaces: f.workspaces}}
		if err := Finish(context.Background(), f, target); err != nil {
			t.Fatal("rejected captured shutdown transition", err)
		}
		want := []string{"prompt:possum:/quit", "wait:pane", "snapshot", "snapshot", "remove:task:/repo/task"}
		for i := range want {
			want[i] = m.DisplayName() + ":" + want[i]
		}
		if !reflect.DeepEqual(f.calls, want) {
			t.Fatal(f.calls, want)
		}
	}
}

func TestFinishNeverRemovesDrainingOccupant(t *testing.T) {
	for _, variant := range []string{"lingering", "renamed", "moved-pane", "moved-workspace", "additional"} {
		t.Run(variant, func(t *testing.T) {
			f, target := finishFixture(herdr.Local())
			draining := herdr.Agent{Name: "possum", WorkspaceID: "task", PaneID: "pane", Status: "idle"}
			switch variant {
			case "renamed":
				draining.Name = "other"
			case "moved-pane":
				draining.PaneID = "other-pane"
			case "moved-workspace":
				draining.WorkspaceID = "other-workspace"
			}
			f.after = []herdr.Agent{draining}
			if variant == "additional" {
				other := draining
				other.Name, other.PaneID = "other", "other-pane"
				f.after = append(f.after, other)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
			defer cancel()
			err := Finish(ctx, f, target)
			if err == nil || len(f.calls) != 3 {
				t.Fatal("removed or retried changed occupant", err, f.calls)
			}
			if variant == "lingering" && (!errors.Is(err, context.DeadlineExceeded) || !strings.Contains(err.Error(), "selected agent still present")) {
				t.Fatal("did not wait boundedly for draining occupant", err)
			}
			if variant != "lingering" && errors.Is(err, context.DeadlineExceeded) {
				t.Fatal("did not reject changed occupant immediately", err)
			}
		})
	}
}
