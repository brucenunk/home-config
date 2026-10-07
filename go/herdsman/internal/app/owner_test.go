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

func TestContextInventoryAndDestinations(t *testing.T) {
	c := startConfig()
	c.Machines["local"] = MachineConfig{Repositories: map[string]RepositoryConfig{
		"owner/one": {Path: "/repos/one"}, "other/repo": {Path: "/repos/other"}, "owner/two": {Path: "/repos/two"},
	}}
	c.Machines["remote"] = MachineConfig{Repositories: map[string]RepositoryConfig{"owner/three": {Path: "/remote/three.git"}}}
	want := []string{"other", "other/repo", "owner", "owner/one", "owner/three", "owner/two"}
	if got := c.ContextNames(true); !reflect.DeepEqual(got, want) {
		t.Fatal(got, want)
	}
	if got := c.ContextNames(false); !reflect.DeepEqual(got, c.RepositoryNames()) {
		t.Fatal("task context includes owners", got)
	}
	remote := herdr.Machine{ID: "remote", Label: "remote", Enabled: true}
	profiles := []herdr.Machine{remote, {ID: "off", Label: "off"}}
	if got := c.Destinations("owner", profiles); !reflect.DeepEqual(got, []herdr.Machine{herdr.Local(), remote}) {
		t.Fatal(got)
	}
	if got := c.Destinations("other", profiles); !reflect.DeepEqual(got, []herdr.Machine{herdr.Local()}) {
		t.Fatal(got)
	}
	for _, name := range []string{"ow", "owner/three/extra", "..", "owner/../escape", "/owner", "missing"} {
		if got := c.Destinations(name, profiles); len(got) != 0 {
			t.Fatal("unexpected destination", name, got)
		}
	}
	profiles = append(profiles, herdr.Machine{ID: "duplicate", Label: "remote", Enabled: true})
	if got := c.Destinations("owner", profiles); !reflect.DeepEqual(got, []herdr.Machine{herdr.Local()}) {
		t.Fatal("ambiguous machine offered", got)
	}
}

func TestStartOwnerLocalAndRemote(t *testing.T) {
	remote := herdr.Machine{ID: "remote", Label: "remote", Enabled: true}
	for _, machine := range []herdr.Machine{herdr.Local(), remote} {
		f := &fakeLauncher{profiles: []herdr.Machine{remote}}
		r, err := start(context.Background(), startConfig(), f, StartRequest{Repo: "owner", Machine: machine})
		if err != nil || r.Path != "/home/test/work/owner" || r.Branch != "" || r.Parent != "" || r.Title != "Investigate deploy latency" || f.workspaceLabel != r.Title || f.prompt != "" || f.parentSource != r.Path {
			t.Fatal(r, err, f)
		}
		want := []string{"local:snapshot", "remote:snapshot", machine.Label + ":home", machine.Label + ":parent", machine.Label + ":start", machine.Label + ":focus"}
		if !reflect.DeepEqual(f.calls, want) {
			t.Fatal("extra calls or worktree operations", f.calls, want)
		}
		// Existing owner workspaces never become shared launch destinations.
		firstLabel := f.workspaceLabel
		f.workspaces = []herdr.Workspace{{ID: r.Workspace, Label: firstLabel, PaneCount: 1, TabCount: 1}}
		f.agents = map[string][]herdr.Agent{machine.Label: {{Name: r.AgentName}}}
		f.calls = nil
		second, err := start(context.Background(), startConfig(), f, StartRequest{Repo: "owner", Machine: machine})
		if err != nil || second.AgentName == r.AgentName || f.workspaceLabel != firstLabel || second.Title != r.Title || second.Path != r.Path || !reflect.DeepEqual(f.calls, want) {
			t.Fatal("did not create an independent session", second, err, f.calls)
		}
	}
}

func TestOwnerTaskAndLaunchFailureBoundaries(t *testing.T) {
	f := &fakeLauncher{}
	_, err := start(context.Background(), startConfig(), f, StartRequest{Repo: "owner", Machine: herdr.Local(), Task: &Task{Title: "Task"}})
	if err == nil || len(f.calls) != 0 {
		t.Fatal("accepted a task in an owner context", err, f.calls)
	}
	for _, failure := range []string{"snapshot", "home", "parent", "start", "focus"} {
		f = &fakeLauncher{fail: failure}
		_, err := start(context.Background(), startConfig(), f, StartRequest{Repo: "owner", Machine: herdr.Local()})
		if err == nil || f.calls[len(f.calls)-1] != "local:"+failure {
			t.Fatal(err, f.calls)
		}
		if (failure == "parent" || failure == "start" || failure == "focus") && !strings.Contains(err.Error(), "No automatic cleanup") {
			t.Fatal("missing recovery guidance", err)
		}
	}
}

func TestOwnerLaunchIgnoresAgentlessWorkspaceLabels(t *testing.T) {
	for _, remote := range []bool{false, true} {
		m := herdr.Local()
		if remote {
			m = herdr.Machine{ID: "remote", Label: "remote", Enabled: true}
		}
		c := startConfig()
		c.AgentNames = []string{"possum", "quokka"}
		f := &fakeLauncher{profiles: []herdr.Machine{{ID: "remote", Label: "remote", Enabled: true}}, workspacesByMachine: map[string][]herdr.Workspace{
			m.Label: {{ID: "leftover", Label: "Previous research · herdsman: possum · owner"}},
		}}
		r, err := start(context.Background(), c, f, StartRequest{Repo: "owner", Machine: m})
		if err != nil || len(f.calls) != 6 {
			t.Fatal("leftover label blocked launch or added requests", r, err, f.calls)
		}
		c.AgentNames = []string{"possum"}
		f.calls = nil
		r, err = start(context.Background(), c, f, StartRequest{Repo: "owner", Machine: m})
		if err != nil || r.AgentName != "possum" || len(f.calls) != 6 {
			t.Fatal("agentless workspace reserved an available name", r, err, f.calls)
		}
	}
}

func ownerFinishFixture(m herdr.Machine) (*fakeFinisher, FinishTarget) {
	f, target := finishFixture(m)
	target.Workspace = herdr.Workspace{ID: "task", Label: "Investigate deploy latency", PaneCount: 1, TabCount: 1}
	f.workspaces = []herdr.Workspace{target.Workspace}
	return f, target
}

func TestOwnerEndLocalRemoteAndIsolation(t *testing.T) {
	for _, m := range []herdr.Machine{herdr.Local(), {ID: "remote", Label: "remote", Enabled: true}} {
		f, target := ownerFinishFixture(m)
		other := target.Agent
		other.Name, other.WorkspaceID, other.PaneID = "quokka", "second", "second-pane"
		second := herdr.Workspace{ID: "second", Label: target.Workspace.Label, PaneCount: 1, TabCount: 1}
		f.workspaces = append(f.workspaces, second)
		f.agents[m.DisplayName()] = append(f.agents[m.DisplayName()], other)
		f.after = []herdr.Agent{other}
		targets, err := finishTargetsOn(context.Background(), f, m)
		if err != nil || len(targets) != 2 {
			t.Fatal(targets, err)
		}
		if err := Finish(context.Background(), f, target); err != nil {
			t.Fatal(err)
		}
		want := []string{"snapshot", "prompt:possum:/quit", "wait:pane", "snapshot", "close:task"}
		for i := range want {
			want[i] = m.DisplayName() + ":" + want[i]
		}
		if !reflect.DeepEqual(f.calls, want) || f.after[0] != other || f.workspaces[1] != second {
			t.Fatal("extra calls or touched other session", f.calls)
		}
	}
}

func TestOwnerEndEligibility(t *testing.T) {
	for _, reason := range []string{"valid", "renamed", "legacy-label", "extra-pane", "extra-tab", "missing-counts", "git-workspace", "shared", "duplicate-label", "duplicate-id", "duplicate-name", "missing-name", "missing-pane", "missing-session", "working", "not-pi"} {
		t.Run(reason, func(t *testing.T) {
			f, target := ownerFinishFixture(herdr.Local())
			w := &f.workspaces[0]
			switch reason {
			case "renamed":
				w.Label = "Research"
			case "legacy-label":
				w.Label = "Research · herdsman: possum · owner"
			case "extra-pane":
				w.PaneCount = 2
			case "extra-tab":
				w.TabCount = 2
			case "missing-counts":
				w.PaneCount, w.TabCount = 0, 0
			case "git-workspace":
				w.Worktree = finishWorkspace("", "", "/repo/main", false).Worktree
			case "shared":
				other := target.Agent
				other.Name, other.PaneID = "quokka", "second"
				f.agents["Local"] = append(f.agents["Local"], other)
			case "duplicate-label":
				f.workspaces = append(f.workspaces, herdr.Workspace{ID: "other", Label: w.Label})
			case "duplicate-id":
				f.workspaces = append(f.workspaces, *w)
			case "duplicate-name":
				other := target.Agent
				other.WorkspaceID, other.PaneID = "other", "other-pane"
				f.agents["Local"] = append(f.agents["Local"], other)
			case "missing-name":
				f.agents["Local"][0].Name = ""
			case "missing-pane":
				f.agents["Local"][0].PaneID = ""
			case "missing-session":
				f.agents["Local"][0].Session = nil
			case "working":
				f.agents["Local"][0].Status = "working"
			case "not-pi":
				f.agents["Local"][0].Kind = "codex"
			}
			targets, err := FinishTargets(context.Background(), f, nil)
			eligible := reason == "valid" || reason == "renamed" || reason == "legacy-label" || reason == "duplicate-label"
			if (err != nil && reason != "missing-pane") || (len(targets) == 1) != eligible {
				t.Fatal(reason, targets, err)
			}
			if len(f.calls) != 1 {
				t.Fatal("extra discovery request", f.calls)
			}
		})
	}
}

func TestOrdinarySessionRevalidation(t *testing.T) {
	for _, reason := range []string{"valid", "done", "duplicate-description", "renamed", "name", "pane", "workspace", "session", "working", "extra-pane", "extra-tab", "worktree", "shared", "duplicate-name", "duplicate-id"} {
		t.Run(reason, func(t *testing.T) {
			f, target := ownerFinishFixture(herdr.Local())
			a := &f.agents["Local"][0]
			w := &f.workspaces[0]
			switch reason {
			case "done":
				a.Status = "done"
			case "duplicate-description":
				other := *a
				other.Name, other.PaneID, other.WorkspaceID = "quokka", "other-pane", "other"
				f.agents["Local"] = append(f.agents["Local"], other)
				second := *w
				second.ID = "other"
				f.workspaces = append(f.workspaces, second)
			case "renamed":
				w.Label = "Renamed"
			case "name":
				a.Name = "quokka"
			case "pane":
				a.PaneID = "replacement"
			case "workspace":
				a.WorkspaceID = "replacement"
			case "session":
				a.Session = &herdr.AgentSession{Kind: "path", Value: "/sessions/replacement.jsonl"}
			case "working":
				a.Status = "working"
			case "extra-pane":
				w.PaneCount = 2
			case "extra-tab":
				w.TabCount = 2
			case "worktree":
				w.Worktree = finishWorkspace("", "", "/repo/task", true).Worktree
			case "shared", "duplicate-name":
				other := *a
				other.PaneID = "other-pane"
				if reason == "shared" {
					other.Name = "quokka"
				} else {
					other.WorkspaceID = "other"
				}
				f.agents["Local"] = append(f.agents["Local"], other)
			case "duplicate-id":
				f.workspaces = append(f.workspaces, *w)
			}
			err := RevalidateFinish(context.Background(), f, target)
			valid := reason == "valid" || reason == "done" || reason == "duplicate-description"
			if (err == nil) != valid || !reflect.DeepEqual(f.calls, []string{"Local:snapshot"}) {
				t.Fatal("incorrect pre-quit revalidation or unexpected mutation", reason, err, f.calls)
			}
		})
	}
}

func TestOwnerEndSafetyAndFailureBoundaries(t *testing.T) {
	for _, reason := range []string{"renamed", "extra-pane", "extra-tab", "worktree-added", "missing-workspace", "duplicate-id", "new-occupant", "identity-change", "snapshot-error", "wait-error", "quit-error", "close-error", "still-present"} {
		t.Run(reason, func(t *testing.T) {
			f, target := ownerFinishFixture(herdr.Local())
			snapshot := herdr.Snapshot{Workspaces: []herdr.Workspace{target.Workspace}}
			ctx := context.Background()
			switch reason {
			case "renamed":
				snapshot.Workspaces[0].Label = "Research"
			case "extra-pane":
				snapshot.Workspaces[0].PaneCount = 2
			case "extra-tab":
				snapshot.Workspaces[0].TabCount = 2
			case "worktree-added":
				snapshot.Workspaces[0].Worktree = finishWorkspace("", "", "/repo/task", true).Worktree
			case "missing-workspace":
				snapshot.Workspaces = nil
			case "duplicate-id":
				snapshot.Workspaces = append(snapshot.Workspaces, target.Workspace)
			case "new-occupant":
				other := target.Agent
				other.Name, other.PaneID = "quokka", "new-pane"
				snapshot.Agents = []herdr.Agent{other}
			case "identity-change":
				other := target.Agent
				other.Session = &herdr.AgentSession{Kind: "path", Value: "replacement"}
				snapshot.Agents = []herdr.Agent{other}
			case "snapshot-error":
				f.fail = "snapshot"
			case "wait-error":
				f.waitErr = context.DeadlineExceeded
			case "quit-error":
				f.fail = "prompt:possum:/quit"
			case "close-error":
				f.fail = "close:task"
			case "still-present":
				snapshot.Agents = []herdr.Agent{target.Agent}
				f.keepAgent = true
				var cancel context.CancelFunc
				ctx, cancel = context.WithTimeout(ctx, 20*time.Millisecond)
				defer cancel()
			}
			f.snapshots = []herdr.Snapshot{snapshot}
			err := Finish(ctx, f, target)
			if err == nil {
				t.Fatal("unsafe cleanup succeeded", reason, f.calls)
			}
			if reason == "still-present" && !errors.Is(err, context.DeadlineExceeded) {
				t.Fatal(err)
			}
			closes := 0
			for _, call := range f.calls {
				if strings.Contains(call, ":remove:") {
					t.Fatal("attempted directory deletion", f.calls)
				}
				if strings.Contains(call, ":close:") {
					closes++
				}
			}
			if closes > 1 || (closes == 1) != (reason == "close-error") {
				t.Fatal("unexpected/retried close", f.calls)
			}
		})
	}
}
