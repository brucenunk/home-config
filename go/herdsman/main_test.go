package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/brucenunk/home-config/go/herdsman/internal/app"
	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
)

func TestDebugFlagAcceptedByAllEntryPoints(t *testing.T) {
	original := os.Args
	t.Cleanup(func() { os.Args = original })
	missingConfig := filepath.Join(t.TempDir(), "missing.toml")
	for _, command := range []string{"", "start", "finish"} {
		t.Run(command, func(t *testing.T) {
			os.Args = []string{"herdsman"}
			if command != "" {
				os.Args = append(os.Args, command)
			}
			os.Args = append(os.Args, "--debug", "--config", missingConfig)
			if err := run(); err == nil || !strings.Contains(err.Error(), missingConfig) {
				t.Fatalf("expected config load error after flag parsing, got %v", err)
			}
		})
	}
}

func TestBareCommandLoadsDefaultConfig(t *testing.T) {
	original := os.Args
	t.Cleanup(func() { os.Args = original })
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	os.Args = []string{"herdsman"}
	if err := run(); err == nil || !strings.Contains(err.Error(), "config.toml") {
		t.Fatalf("bare command should load configuration, not print help: %v", err)
	}
}

func TestInvalidCommandArguments(t *testing.T) {
	original := os.Args
	t.Cleanup(func() { os.Args = original })
	for _, test := range []struct {
		args []string
		want string
	}{
		{[]string{"unknown"}, "unknown command"},
		{[]string{"--unknown"}, "flag provided but not defined"},
		{[]string{"--debug", "extra"}, "takes no positional arguments"},
		{[]string{"start", "extra"}, "takes no positional arguments"},
		{[]string{"finish", "extra"}, "takes no positional arguments"},
	} {
		os.Args = append([]string{"herdsman"}, test.args...)
		if err := run(); err == nil || !strings.Contains(err.Error(), test.want) {
			t.Fatalf("%v: expected %q, got %v", test.args, test.want, err)
		}
	}
}

func TestHelpBypassesConfiguration(t *testing.T) {
	original := os.Args
	t.Cleanup(func() { os.Args = original })
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	for _, args := range [][]string{{"--help"}, {"-h"}, {"start", "--help"}, {"finish", "--help"}} {
		os.Args = append([]string{"herdsman"}, args...)
		if err := run(); err != nil {
			t.Fatalf("%v: %v", args, err)
		}
	}
}

type batchFinisher struct {
	snapshot herdr.Snapshot
	calls    []string
	fail     string
	current  string
	cancel   context.CancelFunc
}

func (f *batchFinisher) call(op string) error {
	f.calls = append(f.calls, op)
	if op == f.fail {
		return errors.New("test failure")
	}
	return nil
}

func (f *batchFinisher) Snapshot(context.Context, herdr.Machine) (herdr.Snapshot, error) {
	return f.snapshot, f.call("snapshot:" + f.current)
}

func (f *batchFinisher) Prompt(_ context.Context, _ herdr.Machine, name, prompt string) error {
	f.current = name
	if err := f.call("prompt:" + name + ":" + prompt); err != nil {
		return err
	}
	for i, agent := range f.snapshot.Agents {
		if agent.Name == name {
			f.snapshot.Agents = append(f.snapshot.Agents[:i], f.snapshot.Agents[i+1:]...)
			break
		}
	}
	return nil
}

func (f *batchFinisher) WaitForQuit(_ context.Context, _ herdr.Machine, pane string) error {
	return f.call("wait:" + pane)
}

func (f *batchFinisher) RemoveWorktree(_ context.Context, _ herdr.Machine, id, path string) error {
	err := f.call("remove:" + id + ":" + path)
	if f.cancel != nil {
		f.cancel()
	}
	return err
}

func batchFixture() *batchFinisher {
	f := &batchFinisher{}
	for _, name := range []string{"one", "two", "three"} {
		f.snapshot.Agents = append(f.snapshot.Agents, herdr.Agent{
			Name: name, Kind: "pi", Status: "idle", WorkspaceID: name, PaneID: "pane-" + name,
			Session: &herdr.AgentSession{Kind: "pi", Value: name},
		})
		f.snapshot.Workspaces = append(f.snapshot.Workspaces, herdr.Workspace{
			ID: name, Label: name, Worktree: &struct {
				CheckoutPath string `json:"checkout_path"`
				Linked       bool   `json:"is_linked_worktree"`
			}{"/repo/" + name, true},
		})
	}
	return f
}

func TestFinishSelectedSharesDiscoveryAndFinishesSequentially(t *testing.T) {
	f := batchFixture()
	targets, err := app.FinishTargets(context.Background(), f, nil)
	if err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := finishSelected(context.Background(), f, targets, &out); err != nil {
		t.Fatal(err)
	}
	want := []string{"snapshot:"}
	for _, target := range targets {
		name := target.Agent.Name
		want = append(want, "prompt:"+name+":/quit", "wait:pane-"+name, "snapshot:"+name, "remove:"+name+":/repo/"+name)
	}
	if !reflect.DeepEqual(f.calls, want) || strings.Count(out.String(), "Finished ") != 3 {
		t.Fatalf("calls=%v, output=%s", f.calls, out.String())
	}
}

func TestFinishSelectedStopsAtFirstFailure(t *testing.T) {
	for _, failure := range []string{"prompt:three:/quit", "wait:pane-three", "snapshot:three", "remove:three:/repo/three"} {
		t.Run(failure, func(t *testing.T) {
			f := batchFixture()
			targets, err := app.FinishTargets(context.Background(), f, nil)
			if err != nil {
				t.Fatal(err)
			}
			// Displayed order is one, three, two. Fail the second task.
			f.fail = failure
			var out bytes.Buffer
			err = finishSelected(context.Background(), f, targets, &out)
			if err == nil || !strings.Contains(err.Error(), `finish "three" on "Local" failed`) || !strings.Contains(err.Error(), "1 completed") || !strings.Contains(err.Error(), `Not attempted: "two" on "Local"`) {
				t.Fatalf("wrong failure report: %v", err)
			}
			if strings.Count(out.String(), "Finished ") != 1 || !strings.Contains(out.String(), `Finished "one"`) || f.calls[len(f.calls)-1] != failure {
				t.Fatalf("continued after failure: %v, %s", f.calls, out.String())
			}
		})
	}
}

func TestFinishSelectedCancellation(t *testing.T) {
	for _, before := range []bool{true, false} {
		f := batchFixture()
		targets, err := app.FinishTargets(context.Background(), f, nil)
		if err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithCancel(context.Background())
		if before {
			cancel()
		} else {
			f.cancel = cancel
		}
		var out bytes.Buffer
		err = finishSelected(ctx, f, targets, &out)
		cancel()
		completed, calls := 1, 5
		if before {
			completed, calls = 0, 1
		}
		if !errors.Is(err, context.Canceled) || len(f.calls) != calls || strings.Count(out.String(), "Finished ") != completed || !strings.Contains(err.Error(), `"two" on "Local"`) {
			t.Fatalf("before=%v calls=%v output=%s err=%v", before, f.calls, out.String(), err)
		}
	}
}

func TestFinishSummaryEscapesControls(t *testing.T) {
	target := app.FinishTarget{
		Machine:   herdr.Machine{ID: "remote", Label: "remote\x1b[31m"},
		Agent:     herdr.Agent{Name: "possum\x07"},
		Workspace: herdr.Workspace{Label: "Task\x1b[2J"},
	}
	target.Workspace.Worktree = &struct {
		CheckoutPath string `json:"checkout_path"`
		Linked       bool   `json:"is_linked_worktree"`
	}{"/repo/task\r\n", true}
	summary := finishSummary(target)
	if strings.ContainsAny(summary, "\x1b\x07\r") || strings.Count(summary, "\n") != 2 || !strings.Contains(summary, `Task\x1b[2J`) || !strings.Contains(summary, `/repo/task\r\n`) {
		t.Fatal("unsafe finish output", summary)
	}
}
