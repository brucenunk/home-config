package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/brucenunk/home-config/go/herdsman/internal/app"
	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
)

func TestDebugFlagAcceptedByBothCommands(t *testing.T) {
	original := os.Args
	t.Cleanup(func() { os.Args = original })
	missingConfig := filepath.Join(t.TempDir(), "missing.toml")
	for _, command := range []string{"start", "finish"} {
		t.Run(command, func(t *testing.T) {
			os.Args = []string{"herdsman", command, "--debug", "--config", missingConfig}
			if err := run(); err == nil || !strings.Contains(err.Error(), missingConfig) {
				t.Fatalf("expected config load error after flag parsing, got %v", err)
			}
		})
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
