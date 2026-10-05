package app

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
	"github.com/brucenunk/home-config/go/herdsman/internal/tui/themes"
)

func load(t *testing.T, text string) (Config, error) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "config.toml")
	if err := os.WriteFile(p, []byte(text), 0600); err != nil {
		t.Fatal(err)
	}
	return LoadConfig(p)
}

func TestMachineRepositoriesAndDefaults(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	c, err := load(t, `agent_names = ["runner", "helper"]
[machines.local.repositories."owner/one"]
path = "/checkouts/one/main"
[machines.local.repositories."owner/two"]
path = "/storage/two.git"
default_branch = "master"
[machines.remote.repositories."owner/one"]
path = "/remote/checkouts/one"
default_branch = "release/stable"
[machines.remote.repositories."owner/three"]
path = "/remote/three.git"
`)
	if err != nil {
		t.Fatal(err)
	}
	one := c.Machines["local"].Repositories["owner/one"]
	two := c.Machines["local"].Repositories["owner/two"]
	remote := c.Machines["remote"].Repositories["owner/one"]
	if one.DefaultBranch != "main" || one.BaseRef() != "origin/main" || two.BaseRef() != "origin/master" || remote.BaseRef() != "origin/release/stable" || remote.Path != "/remote/checkouts/one" {
		t.Fatal(c)
	}
	if !reflect.DeepEqual(c.AgentNames, []string{"runner", "helper"}) {
		t.Fatal(c.AgentNames)
	}
	if c.Theme != (themes.Config{Mode: "auto", Light: "doric-marble", Dark: "doric-obsidian"}) {
		t.Fatal(c.Theme)
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

func TestThemeConfig(t *testing.T) {
	base := "agent_names = [\"runner\"]\n[machines.local.repositories.\"owner/repo\"]\npath = \"/repos/repo.git\"\n[theme]\n"
	c, err := load(t, base+"mode = \"light\"\nlight = \"doric-obsidian\"\ndark = \"doric-marble\"\n")
	if err != nil || c.Theme != (themes.Config{Mode: "light", Light: "doric-obsidian", Dark: "doric-marble"}) {
		t.Fatal(c, err)
	}
	for _, field := range []string{`mode = "invalid"`, `light = "../escape"`, `dark = "/absolute"`, `mode = 1`} {
		if _, err := load(t, base+field); err == nil {
			t.Fatalf("accepted %s", field)
		}
	}
	if _, err := load(t, base+`light = "custom"`); err != nil {
		t.Fatal("custom or missing palettes must be accepted", err)
	}
}

func TestRepositoryPathAndBranchValidation(t *testing.T) {
	for _, branch := range []string{"main", "master", "release/stable"} {
		if !validBranch(branch) {
			t.Fatalf("rejected branch %q", branch)
		}
	}
	for _, branch := range []string{"../main", "/main", "-main", "main..other", "main.lock", "main~1", "main branch", "main\nother"} {
		if validBranch(branch) {
			t.Fatalf("accepted invalid branch %q", branch)
		}
		if _, err := load(t, fmt.Sprintf("agent_names = [\"runner\"]\n[machines.local.repositories.\"owner/repo\"]\npath = \"/repos/repo.git\"\ndefault_branch = %q", branch)); err == nil {
			t.Fatalf("accepted default_branch %q", branch)
		}
	}
	for _, path := range []string{"", "relative/repo", "~/repo", "../repo"} {
		if _, err := load(t, fmt.Sprintf("agent_names = [\"runner\"]\n[machines.local.repositories.\"owner/repo\"]\npath = %q", path)); err == nil {
			t.Fatalf("accepted repository path %q", path)
		}
	}
	for _, text := range []string{
		`[machines.local.repositories."../escape"]
path = "/repos/repo"`,
		`[machines.local.repositories."owner/repo/extra"]
path = "/repos/repo"`,
		`[machines.local]
repositories = {}`,
		`default_base = "origin/main"
[machines.local.repositories."owner/repo"]
path = "/repos/repo"`,
	} {
		if _, err := load(t, "agent_names = [\"runner\"]\n"+text); err == nil {
			t.Fatalf("accepted invalid or retired configuration %s", text)
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
[machines.local.repositories."owner/.github"]
path = "/repos/one"
[machines.local.repositories."owner/repo.lock"]
path = "/repos/two"
[machines.local.repositories."owner/repo..suffix"]
path = "/repos/three"`)
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
		if _, err := load(t, field+"\n[machines.local.repositories.\"owner/repo\"]\npath = \"/repos/repo.git\""); err == nil {
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

func TestDaemonConfig(t *testing.T) {
	base := `agent_names = ["runner"]
[machines.local.repositories."owner/repo"]
path = "/repos/repo.git"
`
	c, err := load(t, base)
	if err != nil || c.Daemon != DefaultDaemonConfig() {
		t.Fatal(c.Daemon, err)
	}
	c, err = load(t, base+`[daemon]
refresh_interval = "500ms"
queue_capacity = 7
refresh_concurrency = 2
`)
	if err != nil {
		t.Fatal(err)
	}
	interval, err := c.Daemon.RefreshEvery()
	if err != nil || interval != 500*time.Millisecond || c.Daemon.QueueCapacity != 7 || c.Daemon.RefreshConcurrency != 2 {
		t.Fatal(c.Daemon, interval, err)
	}
	c, err = load(t, base+`[daemon]
refresh_interval = "1m"
`)
	if err != nil || c.Daemon.QueueCapacity != 32 || c.Daemon.RefreshConcurrency != 4 {
		t.Fatal(c.Daemon, err)
	}
	for _, field := range []string{
		`refresh_interval = ""`, `refresh_interval = "30"`, `refresh_interval = "0s"`, `refresh_interval = "-1s"`, `refresh_interval = "999999999h"`, `refresh_interval = "1500000h"`,
		`queue_capacity = 0`, `queue_capacity = -1`, `queue_capacity = 1025`, `refresh_concurrency = 0`, `refresh_concurrency = 65`,
	} {
		if _, err := load(t, base+"[daemon]\n"+field+"\n"); err == nil {
			t.Fatalf("accepted %s", field)
		}
	}
}
