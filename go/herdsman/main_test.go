package main

import (
	"os"
	"path/filepath"
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
