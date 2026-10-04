package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/brucenunk/home-config/go/herdsman/internal/daemon"
	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
)

func TestCLIParsing(t *testing.T) {
	original := os.Args
	t.Cleanup(func() { os.Args = original })
	missing := filepath.Join(t.TempDir(), "missing.toml")
	for _, test := range []struct {
		args []string
		want string
	}{
		{[]string{"--config", missing}, missing},
		{[]string{"daemon", "--debug", "--config", missing}, missing},
		{[]string{"start"}, "unknown command"},
		{[]string{"finish"}, "unknown command"},
		{[]string{"--debug"}, "flag provided but not defined"},
		{[]string{"daemon", "extra"}, "takes no positional arguments"},
	} {
		os.Args = append([]string{"herdsman"}, test.args...)
		if err := run(); err == nil || !strings.Contains(err.Error(), test.want) {
			t.Fatalf("%v: %v", test.args, err)
		}
	}
}
func TestHelpBypassesConfig(t *testing.T) {
	original := os.Args
	t.Cleanup(func() { os.Args = original })
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	for _, args := range [][]string{{"--help"}, {"-h"}, {"daemon", "--help"}} {
		os.Args = append([]string{"herdsman"}, args...)
		if err := run(); err != nil {
			t.Fatal(err)
		}
	}
}
func TestInventoryWarnings(t *testing.T) {
	now := time.Now()
	i := daemon.Inventory{ProfilesUpdated: now, Machines: []daemon.MachineState{{Machine: herdr.Local(), Updated: now}}}
	if warnings := inventoryWarnings(i, now, 30*time.Second); len(warnings) != 0 {
		t.Fatal(warnings)
	}
	i.Machines = append(i.Machines, daemon.MachineState{Machine: herdr.Machine{ID: "r", Label: "remote\x1b"}, Error: "failure\x1b"})
	warnings := strings.Join(inventoryWarnings(i, now, 30*time.Second), "\n")
	if !strings.Contains(warnings, "no successful refresh") || strings.ContainsRune(warnings, '\x1b') {
		t.Fatal(warnings)
	}
	i.Machines[1].Updated = now.Add(-time.Minute)
	if warnings := strings.Join(inventoryWarnings(i, now, 30*time.Second), " "); !strings.Contains(warnings, "stale") {
		t.Fatal(warnings)
	}
}

func TestSubmissionErrorsDistinguishRejection(t *testing.T) {
	rejected := submissionError(&daemon.Rejection{Status: 409, Reason: "queue full"})
	if !strings.Contains(rejected.Error(), "nothing queued") || strings.Contains(rejected.Error(), "may have been accepted") {
		t.Fatal(rejected)
	}
	uncertain := submissionError(errors.New("connection lost"))
	if !strings.Contains(uncertain.Error(), "may have been accepted") {
		t.Fatal(uncertain)
	}
}
