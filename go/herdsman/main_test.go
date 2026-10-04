package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/brucenunk/home-config/go/herdsman/internal/daemon"
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
