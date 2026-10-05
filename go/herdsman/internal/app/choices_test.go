package app

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
)

func TestOptionalTaskHints(t *testing.T) {
	for _, header := range []string{"", "repo: owner/repo\n", "machine: machine-a\nthinking: high\n", "repo: owner/repo\nmachine: machine-a\nmodel: example/vendor/model\nthinking: high\nbase-ref: upstream/train/one\n"} {
		task, err := ParseTask([]byte("---\ntitle: Task\n" + header + "---\nBody\n"))
		if err != nil || task.Prompt() != "Body\n" {
			t.Fatal(task, err)
		}
		if strings.Contains(header, "base-ref") && (task.BaseRef != "upstream/train/one" || task.Model != "example/vendor/model" || task.Machine != "machine-a" || task.Thinking != "high" || task.Repo != "owner/repo") {
			t.Fatal(task)
		}
	}
	// Unknown semantic hints are left available for correction; unsafe transport isn't.
	task, err := ParseTask([]byte("---\ntitle: Task\nrepo: unknown\nmodel: missing\nthinking: impossible\nbase-ref: origin/main~1\n---\nBody"))
	if err != nil || task.Model != "missing" {
		t.Fatal(task, err)
	}
	for _, field := range []string{"repo", "machine", "model", "thinking", "base-ref"} {
		if _, err := ParseTask([]byte("---\ntitle: Task\n" + field + ": \"bad\\u001bvalue\"\n---\n")); err == nil {
			t.Fatal("accepted control in", field)
		}
	}
}

func TestFinalChoicesValidationBeforeCommands(t *testing.T) {
	c := startConfig()
	good := StartRequest{Repo: "owner/repo", Machine: herdr.Local(), Description: "Research", Model: "example/vendor/model", Thinking: "high", BaseRef: "origin/main"}
	for _, bad := range []string{"model", "thinking", "base", "owner-base", "task-owner"} {
		req := good
		switch bad {
		case "model":
			req.Model = "unknown/model"
		case "thinking":
			req.Thinking = "max"
		case "base":
			req.BaseRef = "origin/main;touch"
		case "owner-base":
			req.Repo = "owner"
		case "task-owner":
			req.Repo, req.BaseRef, req.Task = "owner", "", &Task{Title: "Task"}
		}
		f := &fakeLauncher{}
		if _, err := Start(context.Background(), c, f, nil, req); err == nil || len(f.calls) != 0 {
			t.Fatal(bad, err, f.calls)
		}
	}
	// Task hints are never launch instructions after the user has replaced them.
	good.Task = &Task{Title: "Task", Repo: "unknown/repo", Machine: "missing", Model: "wrong/model", Thinking: "max", BaseRef: "wrong/ref"}
	for base, qualified := range map[string]string{"origin/main": "refs/remotes/origin/main", "upstream/train/next": "refs/remotes/upstream/train/next", "main": "refs/heads/main"} {
		good.BaseRef = base
		f := &fakeLauncher{}
		if _, err := Start(context.Background(), c, f, nil, good); err != nil {
			t.Fatal(err)
		}
		if f.worktree.Base != qualified || good.BaseRef != base || f.model != good.Model || f.thinking != good.Thinking {
			t.Fatal(f)
		}
	}
}

func TestBaseExistenceFailureStopsWithoutRetryOrCleanup(t *testing.T) {
	f := &fakeLauncher{fail: "worktree"}
	_, err := start(context.Background(), startConfig(), f, StartRequest{Repo: "owner/repo", Machine: herdr.Local(), BaseRef: "origin/missing"})
	if err == nil || !strings.Contains(err.Error(), "No automatic cleanup") || f.calls[len(f.calls)-1] != "local:worktree" || !slicesContain(f.calls, "local:parent") {
		t.Fatal(err, f.calls)
	}
	if f.worktree.Base != "refs/remotes/origin/missing" || slicesContain(f.calls, "local:start") {
		t.Fatal(f.worktree, f.calls)
	}
}

func TestCatalogueAndExplicitLocalIdentity(t *testing.T) {
	c := startConfig()
	for label, machine := range c.Machines {
		name := label
		if label == "local" {
			name = c.LocalMachineName
		}
		projected := c.Catalogue.Machines[name]
		for slug := range machine.Repositories {
			projected.Repositories = append(projected.Repositories, slug)
		}
		c.Catalogue.Machines[name] = projected
	}
	if err := c.ValidateCatalogue(); err != nil {
		t.Fatal(err)
	}
	if c.MachineName(herdr.Local()) != "machine-a" || c.MachineName(herdr.Machine{ID: "r", Label: "remote"}) != "remote" {
		t.Fatal(c)
	}
	for _, mutate := range []func(*Config){
		func(c *Config) { c.LocalMachineName = "" },
		func(c *Config) { c.LocalMachineName = "remote" },
		func(c *Config) { c.Catalogue.Machines["remote"] = CatalogueMachine{} },
		func(c *Config) {
			c.Catalogue.Machines["remote"] = CatalogueMachine{Repositories: []string{"owner/repo"}, Models: []ModelChoice{{Name: "missing-slash"}}}
		},
		func(c *Config) {
			c.Catalogue.Machines["remote"] = CatalogueMachine{Repositories: []string{"owner/repo"}, Models: []ModelChoice{{Name: "example/model", ThinkingLevels: []string{"huge"}}}}
		},
		func(c *Config) {
			c.Catalogue.Machines["remote"] = CatalogueMachine{Repositories: []string{"owner/repo"}, Models: []ModelChoice{{Name: "example/model"}, {Name: "example/model"}}}
		},
	} {
		data, _ := json.Marshal(c)
		var broken Config
		_ = json.Unmarshal(data, &broken)
		mutate(&broken)
		if err := broken.ValidateCatalogue(); err == nil {
			t.Fatal("accepted invalid catalogue", broken)
		}
	}
}

func TestLoadCatalogueAlongsideCustomConfig(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "custom.toml")
	if err := os.WriteFile(path, []byte("local_machine_name = \"machine-z\"\nagent_names = [\"runner\"]\n[machines.local.repositories.\"owner/repo\"]\npath = \"/repo\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	if _, err := LoadConfig(path); err == nil || !strings.Contains(err.Error(), "catalogue.json") {
		t.Fatal(err)
	}
	cat := `{"machines":{"machine-z":{"repositories":["owner/repo"],"models":[{"name":"example/vendor/model","thinkingLevels":["off","medium"]}]}}}`
	if err := os.WriteFile(filepath.Join(dir, "catalogue.json"), []byte(cat), 0600); err != nil {
		t.Fatal(err)
	}
	c, err := LoadConfig(path)
	if err != nil || len(c.Models(herdr.Local())) != 1 {
		t.Fatal(c, err)
	}
	for _, bad := range []string{cat + " {}", strings.Replace(cat, `"models":`, `"unexpected":true,"models":`, 1), strings.Replace(cat, "machine-z", "other", 1)} {
		if err := os.WriteFile(filepath.Join(dir, "catalogue.json"), []byte(bad), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadConfig(path); err == nil {
			t.Fatal("accepted", bad)
		}
	}
}

func TestCatalogueRejectsPiResolverAmbiguity(t *testing.T) {
	for _, names := range [][]string{
		{"example/foo", "example/Foo", "example/example/foo"},
		{"example/foo", "Example/bar"},
		{"example/foo", "example/foo "},
		{" example/foo"},
		{"example /foo"},
		{"example/ foo"},
	} {
		c := Config{LocalMachineName: "machine-a", Machines: map[string]MachineConfig{"local": {Repositories: map[string]RepositoryConfig{"owner/repo": {Path: "/repo"}}}}, Catalogue: Catalogue{Machines: map[string]CatalogueMachine{}}}
		machine := CatalogueMachine{Repositories: []string{"owner/repo"}}
		for _, name := range names {
			machine.Models = append(machine.Models, ModelChoice{Name: name, ThinkingLevels: []string{"off"}})
		}
		c.Catalogue.Machines["machine-a"] = machine
		if err := c.ValidateCatalogue(); err == nil {
			t.Fatal("accepted references Pi cannot distinguish", names)
		}
	}
}

func TestMachineDefaultModelConfiguration(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.toml")
	catalogue := `{"machines":{"machine-a":{"repositories":["owner/repo"],"models":[{"name":"example/first","thinkingLevels":["off"]},{"name":"example/vendor/model","thinkingLevels":["medium","high"]}]}}}`
	if err := os.WriteFile(filepath.Join(dir, "catalogue.json"), []byte(catalogue), 0600); err != nil {
		t.Fatal(err)
	}
	for _, value := range []string{"", "example/vendor/model", "example/missing", "other/vendor/model"} {
		text := "local_machine_name = \"machine-a\"\nagent_names = [\"runner\"]\n[machines.local]\ndefault_model = \"" + value + "\"\n[machines.local.repositories.\"owner/repo\"]\npath = \"/repo\"\n"
		if err := os.WriteFile(path, []byte(text), 0600); err != nil {
			t.Fatal(err)
		}
		c, err := LoadConfig(path)
		if value == "" || value == "example/vendor/model" {
			if err != nil || c.Machines["local"].DefaultModel != value {
				t.Fatal(value, c, err)
			}
		} else if err == nil || !strings.Contains(err.Error(), "default_model") {
			t.Fatal("accepted incompatible default", value, err)
		}
	}
}

func TestBaseRefFormsAndThinkingDefaults(t *testing.T) {
	for _, ref := range []string{"main", "origin/main", "upstream/train/next"} {
		if !ValidBaseRef(ref) {
			t.Fatal(ref)
		}
	}
	for _, ref := range []string{"", "-branch", "origin/", "/main", "refs/heads/main", "refs/remotes/origin/main", "origin/main~1", "../main", "main:other", "main\nother"} {
		if ValidBaseRef(ref) {
			t.Fatal(ref)
		}
	}
	for _, tc := range []struct {
		levels []string
		want   string
	}{{[]string{"off", "medium", "high"}, "medium"}, {[]string{"off"}, "off"}, {[]string{"low", "high"}, ""}, {nil, ""}} {
		if got := (ModelChoice{ThinkingLevels: tc.levels}).DefaultThinking(); got != tc.want {
			t.Fatal(got, tc.want)
		}
	}
}

func TestProjectedCaptureDefaults(t *testing.T) {
	c := startConfig()
	c.Catalogue.LocalMachine = c.LocalMachineName
	for label, operational := range c.Machines {
		name := label
		if label == "local" {
			name = c.LocalMachineName
		}
		machine := c.Catalogue.Machines[name]
		machine.DefaultBaseRefs = map[string]string{}
		for slug, repository := range operational.Repositories {
			machine.Repositories = append(machine.Repositories, slug)
			machine.DefaultBaseRefs[slug] = repository.BaseRef()
		}
		machine.DefaultModel = machine.Models[0].Name
		for i := range machine.Models {
			machine.Models[i].ThinkingDefault = machine.Models[i].DefaultThinking()
		}
		c.Catalogue.Machines[name] = machine
	}
	if err := c.ValidateCatalogue(); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(c.Catalogue)
	if err != nil {
		t.Fatal(err)
	}
	for _, mutate := range []func(*Catalogue){
		func(cat *Catalogue) { cat.LocalMachine = "other" },
		func(cat *Catalogue) {
			machine := cat.Machines[c.LocalMachineName]
			machine.DefaultBaseRefs["owner/repo"] = "upstream/train/next"
			cat.Machines[c.LocalMachineName] = machine
		},
		func(cat *Catalogue) {
			machine := cat.Machines[c.LocalMachineName]
			machine.DefaultBaseRefs = nil
			cat.Machines[c.LocalMachineName] = machine
		},
		func(cat *Catalogue) {
			machine := cat.Machines[c.LocalMachineName]
			machine.DefaultModel = ""
			cat.Machines[c.LocalMachineName] = machine
		},
		func(cat *Catalogue) {
			machine := cat.Machines[c.LocalMachineName]
			machine.Models[0].ThinkingDefault = "high"
			cat.Machines[c.LocalMachineName] = machine
		},
	} {
		broken := c
		broken.Catalogue = Catalogue{}
		if err := json.Unmarshal(data, &broken.Catalogue); err != nil {
			t.Fatal(err)
		}
		mutate(&broken.Catalogue)
		if err := broken.ValidateCatalogue(); err == nil {
			t.Fatal("accepted mismatched projected defaults", broken.Catalogue)
		}
	}
}
