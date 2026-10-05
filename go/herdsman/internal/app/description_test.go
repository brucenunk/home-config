package app

import (
	"context"
	"strings"
	"testing"

	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
)

func TestDescriptionValidationBeforeLaunch(t *testing.T) {
	for _, description := range []string{"", "   ", "two\nlines", "tab\there", "title\r", "title\x00", "\x1b[31m", "invalid\xff", strings.Repeat("x", maxAgentArgumentBytes+1)} {
		for _, repo := range []string{"owner", "owner/repo"} {
			f := &fakeLauncher{}
			_, err := Start(context.Background(), startConfig(), f, nil, StartRequest{Repo: repo, Machine: herdr.Local(), Description: description})
			if err == nil || len(f.calls) != 0 {
				t.Fatal("invalid description reached launch", repo, err, f.calls)
			}
		}
	}
	for _, repo := range []string{"owner", "owner/repo"} {
		f := &fakeLauncher{}
		r, err := start(context.Background(), startConfig(), f, StartRequest{Repo: repo, Machine: herdr.Local(), Description: "  Investigate déploiement 🐾  "})
		if err != nil || r.Title != "Investigate déploiement 🐾" || f.title != r.Title || f.prompt != "" {
			t.Fatal(r, err, f)
		}
	}
}

func TestDescriptionOwnerLabelTransportLimit(t *testing.T) {
	f := &fakeLauncher{}
	_, err := start(context.Background(), startConfig(), f, StartRequest{Repo: "owner", Machine: herdr.Local(), Description: strings.Repeat("x", maxAgentArgumentBytes)})
	if err == nil || len(f.calls) != 1 || f.calls[0] != "local:snapshot" {
		t.Fatal("oversized composite label reached mutation", err, f.calls)
	}
}

func TestDescribedOwnerLabelsAndLegacyCleanup(t *testing.T) {
	marker := ownerSessionLabel("owner", "possum")
	for _, label := range []string{marker, "Research · " + marker, "Research · with separators · " + marker, marker + " · " + marker} {
		f, target := ownerFinishFixture(herdr.Local())
		target.Workspace.Label = label
		f.workspaces[0] = target.Workspace
		targets, err := FinishTargets(context.Background(), f, nil)
		if err != nil || len(targets) != 1 || !targets[0].OwnerSession() {
			t.Fatal("label not recognized", label, targets, err)
		}
		if err := Finish(context.Background(), f, target); err != nil || f.calls[len(f.calls)-1] != "Local:close:task" {
			t.Fatal(label, err, f.calls)
		}
	}
	for _, label := range []string{"Research", " · " + marker, "Research · " + ownerSessionLabel("owner/repo", "possum"), "Research · " + ownerSessionLabel("owner", "quokka"), "Research · " + marker + " suffix"} {
		if _, ok := ownerFromSessionLabel(label, "possum"); ok {
			t.Fatal("recognized invalid marker", label)
		}
	}
}

func TestDescribedOwnerLeftoversReserveNames(t *testing.T) {
	c := startConfig()
	c.AgentNames = []string{"possum", "quokka"}
	f := &fakeLauncher{workspaces: []herdr.Workspace{{ID: "leftover", Label: "Previous research · " + ownerSessionLabel("owner", "possum")}}}
	r, err := start(context.Background(), c, f, StartRequest{Repo: "owner", Machine: herdr.Local(), Description: "New research"})
	if err != nil || r.AgentName != "quokka" || r.Title != "New research" {
		t.Fatal("reused described leftover marker", r, err)
	}
}
