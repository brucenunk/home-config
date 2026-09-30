package app

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
)

func load(t *testing.T, text string) (Config, error) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "config.toml")
	if err := os.WriteFile(p, []byte(text), 0600); err != nil {
		t.Fatal(err)
	}
	return LoadConfig(p)
}

func TestConfigDefaultsOverridesAndInventory(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	c, err := load(t, `agent_names = ["runner", "helper"]
[machines.local]
repositories = ["owner/one", "owner/two"]
[machines.remote]
repositories = ["owner/one", "owner/three"]
[repositories."owner/two"]
base = "master"
`)
	if err != nil {
		t.Fatal(err)
	}
	if c.DefaultBase != "main" || c.Base("owner/two") != "master" || c.Base("owner/one") != "main" {
		t.Fatal(c)
	}
	if !reflect.DeepEqual(c.AgentNames, []string{"runner", "helper"}) {
		t.Fatal(c.AgentNames)
	}
	if c.TasksDir != filepath.Join(os.Getenv("HOME"), "work/tasks") {
		t.Fatal(c.TasksDir)
	}
	if !reflect.DeepEqual(c.RepositoryNames(), []string{"owner/one", "owner/three", "owner/two"}) {
		t.Fatal(c.RepositoryNames())
	}
	profiles := []herdr.Machine{{ID: "r1", Label: "remote", Enabled: true}, {ID: "r2", Label: "disabled"}}
	d := c.Destinations("owner/one", profiles)
	if len(d) != 2 || d[0].Label != "local" || d[1].ID != "r1" {
		t.Fatal(d)
	}
	profiles[0].Enabled = false
	if len(c.Destinations("owner/three", profiles)) != 0 {
		t.Fatal("disabled remote offered")
	}
	profiles[0].Enabled = true
	profiles = append(profiles, herdr.Machine{ID: "r3", Label: "remote", Enabled: true})
	if len(c.Destinations("owner/three", profiles)) != 0 {
		t.Fatal("ambiguous label offered")
	}
}

func TestConfigRejectsUnsafePaths(t *testing.T) {
	for _, text := range []string{
		`[machines.local]
repositories = ["../escape"]`,
		`[machines.local]
repositories = ["owner/repo/extra"]`,
		`default_base = "../main"
[machines.local]
repositories = ["owner/repo"]`,
		`[machines.local]
repositories = []`,
	} {
		if _, err := load(t, "agent_names = [\"runner\"]\n"+text); err == nil {
			t.Errorf("accepted %s", text)
		}
	}
}

func TestConfigAndHomePaths(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", "")
	p, err := DefaultConfigPath()
	if err != nil || p != filepath.Join(home, ".config/herdsman/config.toml") {
		t.Fatal(p, err)
	}
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, "config"))
	p, _ = DefaultConfigPath()
	if p != filepath.Join(home, "config/herdsman/config.toml") {
		t.Fatal(p)
	}
	p, err = ExpandHome("~")
	if err != nil || p != home {
		t.Fatal(p, err)
	}
}

func TestRepositoryNamesAreNotBranchNames(t *testing.T) {
	c, err := load(t, `agent_names = ["runner"]
[machines.local]
repositories = ["owner/.github", "owner/repo.lock", "owner/repo..suffix"]`)
	if err != nil || len(c.RepositoryNames()) != 3 {
		t.Fatal(c, err)
	}
	for _, repo := range []string{"owner/..", "./repo", "../repo", "owner/.", "owner/repo/extra"} {
		if validRepo(repo) {
			t.Fatalf("accepted unsafe slug %q", repo)
		}
	}
	for _, base := range []string{".github", "repo.lock", "repo..suffix"} {
		if validComponent(base) {
			t.Fatalf("accepted invalid base %q", base)
		}
	}
}

func TestConfigRequiresValidUniqueAgentNames(t *testing.T) {
	for _, field := range []string{
		"", `agent_names = []`, `agent_names = ["runner", "runner"]`,
		`agent_names = ["Runner"]`, `agent_names = ["-runner"]`,
		`agent_names = ["a/b"]`, `agent_names = ["bad name"]`, `agent_names = [""]`,
	} {
		if _, err := load(t, field+"\n[machines.local]\nrepositories = [\"owner/repo\"]"); err == nil {
			t.Fatalf("accepted %s", field)
		}
	}
	if err := validateAgentNames([]string{"runner", "helper_1", "helper-2", strings.Repeat("a", 32)}); err != nil {
		t.Fatal(err)
	}
	if err := validateAgentNames([]string{strings.Repeat("a", 33)}); err == nil {
		t.Fatal("accepted overlong agent name")
	}
}
