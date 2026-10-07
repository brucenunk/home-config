package tui

import (
	"strings"
	"testing"

	"github.com/brucenunk/home-config/go/herdsman/internal/app"
	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
	tea "github.com/charmbracelet/bubbletea"
)

func choiceConfig(t *testing.T) (app.Config, []herdr.Machine) {
	c := config(t)
	c.Machines["remote"] = app.MachineConfig{Repositories: map[string]app.RepositoryConfig{"owner/one": {Path: "/remote/one", DefaultBranch: "master"}}}
	c.Catalogue.Machines["remote"] = app.CatalogueMachine{Models: []app.ModelChoice{{Name: "other/vendor/model", ThinkingLevels: []string{"off"}}, {Name: "other/reasoner", ThinkingLevels: []string{"low", "high"}}}}
	return c, []herdr.Machine{{ID: "r", Label: "remote", Target: "ssh-alias", Enabled: true}}
}

func taskChoices(t *testing.T, task *app.Task) Model {
	c, profiles := choiceConfig(t)
	m := newModel(t, c, profiles)
	m.Request.Task = task
	m.repositories()
	return m
}

func TestRemoteHintsSkipRepositoryButConfirmLaunchChoices(t *testing.T) {
	task := &app.Task{Title: "Task", Repo: "owner/one", Machine: "remote", Model: "other/vendor/model", Thinking: "off"}
	m := taskChoices(t, task)
	m.beginTaskChoices()
	for _, want := range []stage{pickMachine, editBase, pickModel, pickThinking} {
		if m.stage != want || m.Ready {
			t.Fatal("skipped screen", m.stage, want)
		}
		if want == editBase && (m.base.Value() != "origin/master" || m.baseExplicit) {
			t.Fatal(m.base.Value())
		}
		m, _ = key(m, "enter")
	}
	if !m.Ready || m.Request.Machine.ID != "r" || m.Request.Model != task.Model || m.Request.Thinking != task.Thinking || m.Request.BaseRef != "origin/master" {
		t.Fatal(m.Request)
	}
	if *task != *m.Request.Task {
		t.Fatal("rewrote task")
	}
}

func TestLocalHintsSkipRepositoryAndMachineWithBackNavigation(t *testing.T) {
	task, err := app.ParseTask([]byte("---\ntitle: Task\nrepo: owner/one\nmachine: machine-a\nmodel: example/vendor/model\nthinking: high\nbase-ref: upstream/old-train\n---\nBody"))
	if err != nil {
		t.Fatal(err)
	}
	m := taskChoices(t, task)
	m.beginTaskChoices()
	if m.stage != editBase || !m.Request.Machine.IsLocal() || m.base.Value() != "origin/main" || m.baseExplicit || m.Ready {
		t.Fatal(m.stage, m.Request)
	}
	m, _ = key(m, "esc")
	if m.stage != pickMachine {
		t.Fatal("cannot revisit skipped machine", m.stage)
	}
	m, _ = key(m, "esc")
	if m.stage != pickRepo {
		t.Fatal("cannot revisit skipped repository", m.stage)
	}
	m, _ = key(m, "down")
	m, _ = key(m, "enter")
	if m.stage != editBase || m.Request.Repo != "owner/two" {
		t.Fatal("task hint overwrote user repository", m.stage, m.Request)
	}
	for _, want := range []stage{editBase, pickModel, pickThinking} {
		if m.stage != want || m.Ready {
			t.Fatal(m.stage, want)
		}
		m, _ = key(m, "enter")
	}
	if !m.Ready || m.Request.Thinking != "high" || task.Repo != "owner/one" {
		t.Fatal(m.Request)
	}
}

func TestMissingAndUnavailableStableHintsStillPrompt(t *testing.T) {
	for _, tc := range []struct {
		repo, machine string
		want          stage
	}{
		{"", "machine-a", pickRepo},
		{"missing/repo", "machine-a", pickRepo},
		{"owner/one", "", pickMachine},
		{"owner/one", "missing", pickMachine},
		{"owner/two", "remote", pickMachine},
	} {
		m := taskChoices(t, &app.Task{Title: "Task", Repo: tc.repo, Machine: tc.machine})
		m.beginTaskChoices()
		if m.stage != tc.want || m.Ready {
			t.Fatal(tc, m.stage)
		}
		if tc.machine == "missing" || tc.machine == "remote" || tc.repo == "missing/repo" {
			m, _ = key(m, "enter")
			if m.stage != tc.want || m.Ready {
				t.Fatal("silently replaced invalid hint", tc, m.stage)
			}
		}
	}
}

func TestTaskReadAdvancesToBaseForLocalHints(t *testing.T) {
	m := newModel(t, config(t), nil)
	m.stage, m.taskLoading, m.readID = pickTask, true, 7
	task := &app.Task{Title: "Task", Repo: "owner/one", Machine: "machine-a"}
	next, cmd := m.Update(taskReadMsg{id: 7, task: task})
	m = next.(Model)
	if m.stage != editBase || m.taskLoading || cmd == nil || m.Ready || m.base.Value() != "origin/main" {
		t.Fatal(m.stage, m.Request)
	}
}

func TestRepositoryWithoutEligibleDestinationsDoesNotSkip(t *testing.T) {
	m := taskChoices(t, &app.Task{Title: "Task", Repo: "owner/one", Machine: "machine-a"})
	delete(m.config.Machines, "local")
	m.profiles = nil
	m.beginTaskChoices()
	if m.stage != pickRepo || m.Ready {
		t.Fatal(m.stage)
	}
	m, _ = key(m, "enter")
	if m.stage != pickRepo || !strings.Contains(m.message, "No enabled Herdr machines") {
		t.Fatal(m.stage, m.message)
	}
}

func TestInvalidHintsRequireDeliberateCorrection(t *testing.T) {
	m := taskChoices(t, &app.Task{Title: "Task", Repo: "missing/repo", Machine: "missing", Model: "missing/model", Thinking: "max"})
	for _, want := range []stage{pickRepo, pickMachine, editBase, pickModel, pickThinking} {
		if m.stage != want {
			t.Fatal(m.stage, want)
		}
		if want == editBase {
			m.base.SetValue("origin/main~1")
		}
		m, _ = key(m, "enter")
		if m.stage != want || m.Ready {
			t.Fatal("silently replaced hint", m.stage, want)
		}
		if want == editBase {
			if m.message == "" || m.base.Value() != "origin/main~1" {
				t.Fatal(m.message, m.base.Value())
			}
			m, _ = key(m, "ctrl+r")
		} else {
			if m.message == "" {
				t.Fatal("no correction diagnostic", want)
			}
			m, _ = key(m, "down")
		}
		m, _ = key(m, "enter")
	}
	if !m.Ready || m.Request.Repo != "owner/one" || !m.Request.Machine.IsLocal() || m.Request.Model != "example/vendor/model" || m.Request.Thinking != "off" || m.Request.BaseRef != "origin/main" {
		t.Fatal(m.Request)
	}
}

func TestThinkingOnlyHintAndModelSpecificDefaults(t *testing.T) {
	for _, thinkingHint := range []string{"", "high", "max"} {
		m := taskChoices(t, &app.Task{Title: "Task", Repo: "owner/one", Thinking: thinkingHint})
		for i := 0; i < 4; i++ {
			m, _ = key(m, "enter")
		}
		if m.stage != pickThinking {
			t.Fatal(m.stage)
		}
		if thinkingHint == "max" {
			if m.choiceSelected || !strings.Contains(m.View(), "max") {
				t.Fatal(m.View())
			}
		} else {
			want := thinkingHint
			if want == "" {
				want = "medium"
			}
			if !m.choiceSelected || m.list.SelectedItem().(item).Title() != want {
				t.Fatal(m.View())
			}
		}
	}
	m := taskChoices(t, &app.Task{Title: "Task", Repo: "owner/one", Machine: "remote"})
	for i := 0; i < 4; i++ {
		m, _ = key(m, "enter")
	}
	if m.stage != pickThinking || m.list.SelectedItem().(item).Title() != "off" || len(m.list.Items()) != 1 {
		t.Fatal(m.View())
	}
	m, _ = key(m, "esc")
	m, _ = key(m, "down")
	m, _ = key(m, "enter")
	if m.stage != pickThinking || m.choiceSelected || m.message == "" {
		t.Fatal("invented default for medium/off-less model", m.View())
	}
	m, _ = key(m, "down")
	m, cmd := key(m, "enter")
	if !m.Ready || cmd == nil || m.Request.Thinking != "low" {
		t.Fatal(m.Request)
	}
}

func TestBackNavigationRevalidatesDestinationModelAndExplicitThinking(t *testing.T) {
	m := taskChoices(t, &app.Task{Title: "Task", Repo: "owner/one", Model: "example/vendor/model", Thinking: "high"})
	for i := 0; i < 4; i++ {
		m, _ = key(m, "enter")
	}
	if m.stage != pickThinking {
		t.Fatal(m.stage)
	}
	for i := 0; i < 3; i++ {
		m, _ = key(m, "esc")
	}
	if m.stage != pickMachine {
		t.Fatal(m.stage)
	}
	m, _ = key(m, "down")
	m, _ = key(m, "enter")
	if m.base.Value() != "origin/master" || m.baseExplicit {
		t.Fatal("automatic base wasn't updated", m.base.Value())
	}
	m, _ = key(m, "enter")
	if m.stage != pickModel || m.choiceSelected || !strings.Contains(m.message, "example/vendor/model") {
		t.Fatal("silently replaced model", m.View())
	}
	m, _ = key(m, "down")
	m, _ = key(m, "enter")
	if m.stage != pickThinking || m.choiceSelected || !strings.Contains(m.message, "high") {
		t.Fatal("silently replaced thinking", m.View())
	}
	m, _ = key(m, "esc")
	m, _ = key(m, "down")
	m, _ = key(m, "enter")
	if !m.choiceSelected || m.list.SelectedItem().(item).Title() != "high" {
		t.Fatal("compatible explicit thinking lost", m.View())
	}
}

func TestBaseOverridesSurviveBackAndResetRecomputes(t *testing.T) {
	for _, override := range []string{"mybranch", "main", "upstream/train/next"} {
		m := taskChoices(t, &app.Task{Title: "Task", Repo: "owner/one"})
		m, _ = key(m, "enter")
		m, _ = key(m, "enter")
		// Edit the form using its normal input path, not task metadata.
		m.base.SetValue("")
		m, _ = key(m, override)
		if !m.baseExplicit || m.base.Value() != override {
			t.Fatal(m.base.Value())
		}
		m, _ = key(m, "esc")
		m, _ = key(m, "down")
		m, _ = key(m, "enter")
		if m.base.Value() != override {
			t.Fatal("explicit base changed with destination", m.base.Value())
		}
		m, _ = key(m, "ctrl+r")
		if m.baseExplicit || m.base.Value() != "origin/master" {
			t.Fatal(m.base.Value())
		}
		m, _ = key(m, "esc")
		m, _ = key(m, "up")
		m, _ = key(m, "enter")
		if m.base.Value() != "origin/main" {
			t.Fatal(m.base.Value())
		}
	}
}

func TestDestinationOnlyIncludesSelectedContextAndNamedLocalHint(t *testing.T) {
	m := taskChoices(t, &app.Task{Title: "Task", Repo: "owner/two", Machine: "machine-a"})
	m, _ = key(m, "enter")
	if m.stage != editBase || !m.Request.Machine.IsLocal() {
		t.Fatal(m.View())
	}
	// A destination configured for another repo is not silently substituted.
	m = taskChoices(t, &app.Task{Title: "Task", Repo: "owner/two", Machine: "remote"})
	m, _ = key(m, "enter")
	m, _ = key(m, "enter")
	if m.stage != pickMachine || m.choiceSelected || m.message == "" {
		t.Fatal(m.View())
	}
}

func TestOwnerModelsWithoutBaseAndEmptyModelsBlock(t *testing.T) {
	c, profiles := choiceConfig(t)
	m, _ := key(newModel(t, c, profiles), "n")
	m = describeSession(m)
	m, _ = key(m, "down")
	m, _ = key(m, "enter")
	m, _ = key(m, "enter")
	if m.stage != pickModel {
		t.Fatal("owner has base screen", m.stage)
	}
	m = confirmOptions(m)
	if !m.Ready || m.Request.BaseRef != "" {
		t.Fatal(m.Request)
	}
	c.Catalogue.Machines[c.LocalMachineName] = app.CatalogueMachine{}
	m = taskChoices(t, &app.Task{Title: "Task", Repo: "owner/one"})
	m.config = c
	for i := 0; i < 3; i++ {
		m, _ = key(m, "enter")
	}
	if m.stage != pickModel || m.choiceSelected || !strings.Contains(m.View(), "No configured models") {
		t.Fatal(m.View())
	}
	m, _ = key(m, "enter")
	if m.Ready || m.stage != pickModel {
		t.Fatal(m.stage)
	}
}

func TestNewScreensResizeFilterAndCancel(t *testing.T) {
	m := taskChoices(t, &app.Task{Title: "Task", Repo: "owner/one"})
	m, _ = key(m, "enter")
	m, _ = key(m, "enter")
	for _, want := range []stage{editBase, pickModel, pickThinking} {
		if m.stage != want {
			t.Fatal(m.stage)
		}
		next, _ := m.Update(tea.WindowSizeMsg{Width: 24, Height: 10})
		m = next.(Model)
		_ = m.View()
		cancelled, cmd := key(m, "ctrl+c")
		if cancelled.Ready || cmd == nil {
			t.Fatal("cancel")
		}
		if want != editBase {
			m, _ = key(m, "/")
			m, _ = key(m, "enter")
			if m.stage != want || m.Ready {
				t.Fatal("filter Enter advanced")
			}
			m, _ = key(m, "esc")
			m, _ = key(m, "down")
		}
		m, _ = key(m, "enter")
	}
	if !m.Ready {
		t.Fatal(m.View())
	}
}

func TestThinkingNavigationSurvivesBackAndModelRevalidation(t *testing.T) {
	for _, target := range []int{0, 1, 2} {
		m := taskChoices(t, &app.Task{Title: "Task", Repo: "owner/one"})
		local := m.config.Catalogue.Machines[m.config.LocalMachineName]
		local.Models = append(local.Models, app.ModelChoice{Name: "example/other-reasoner", ThinkingLevels: []string{"low", "high"}}, app.ModelChoice{Name: "example/no-thinking", ThinkingLevels: []string{"off"}})
		m.config.Catalogue.Machines[m.config.LocalMachineName] = local
		for i := 0; i < 4; i++ {
			m, _ = key(m, "enter")
		}
		if m.stage != pickThinking || m.list.SelectedItem().(item) != "medium" {
			t.Fatal(m.View())
		}
		m, _ = key(m, "down")
		if m.Request.Thinking != "high" || !m.thinkingExplicit || m.Ready {
			t.Fatal("navigation not remembered", m.Request)
		}
		m, _ = key(m, "esc")
		for i := 0; i < target; i++ {
			m, _ = key(m, "down")
		}
		m, _ = key(m, "enter")
		if m.stage != pickThinking || m.Request.Thinking != "high" {
			t.Fatal("thinking lost on back", m.View())
		}
		if target < 2 {
			if !m.choiceSelected || m.list.SelectedItem().(item) != "high" {
				t.Fatal("compatible choice not preserved", m.View())
			}
		} else if m.choiceSelected || !strings.Contains(m.message, "high") {
			t.Fatal("incompatible choice silently replaced", m.View())
		}
	}
}

func TestMachineDefaultModelPreselectionAndPrecedence(t *testing.T) {
	for _, tc := range []struct{ hint, machine, configured, want string }{
		{configured: "example/preferred", want: "example/preferred"},
		{hint: "example/vendor/model", configured: "example/preferred", want: "example/vendor/model"},
		{machine: "remote", configured: "other/reasoner", want: "other/reasoner"},
		{want: "example/vendor/model"},
	} {
		c, profiles := choiceConfig(t)
		local := c.Catalogue.Machines[c.LocalMachineName]
		local.Models = append(local.Models, app.ModelChoice{Name: "example/preferred", ThinkingLevels: []string{"off"}})
		c.Catalogue.Machines[c.LocalMachineName] = local
		label := "local"
		if tc.machine != "" {
			label = tc.machine
		}
		machine := c.Machines[label]
		machine.DefaultModel = tc.configured
		c.Machines[label] = machine
		m := newModel(t, c, profiles)
		m.Request.Task = &app.Task{Title: "Task", Repo: "owner/one", Model: tc.hint, Machine: tc.machine}
		m.repositories()
		for i := 0; i < 3; i++ {
			m, _ = key(m, "enter")
		}
		if m.stage != pickModel || !m.choiceSelected || m.list.SelectedItem().(item).Title() != tc.want || m.Ready {
			t.Fatal(tc, m.View())
		}
		m, _ = key(m, "enter")
		if m.Request.Model != tc.want {
			t.Fatal(tc, m.Request)
		}
		if tc.want == "example/preferred" && m.list.SelectedItem().(item) != "off" {
			t.Fatal("thinking didn't follow default model", m.View())
		}
		if tc.want == "other/reasoner" && m.choiceSelected {
			t.Fatal("invented thinking default", m.View())
		}
		m, _ = key(m, "esc")
		if m.stage != pickModel || m.list.SelectedItem().(item).Title() != tc.want {
			t.Fatal("back lost chosen default", m.View())
		}
	}
}

func TestTaskAndUserChoicesAreNotReplacedByMachineDefault(t *testing.T) {
	m := taskChoices(t, &app.Task{Title: "Task", Repo: "owner/one", Model: "unknown/model"})
	machine := m.config.Machines["local"]
	machine.DefaultModel = "example/vendor/model"
	m.config.Machines["local"] = machine
	for i := 0; i < 3; i++ {
		m, _ = key(m, "enter")
	}
	m, _ = key(m, "enter")
	if m.stage != pickModel || m.choiceSelected || !strings.Contains(m.message, "unknown/model") {
		t.Fatal("default replaced incompatible hint", m.View())
	}

	m = taskChoices(t, &app.Task{Title: "Task", Repo: "owner/one"})
	local := m.config.Catalogue.Machines[m.config.LocalMachineName]
	local.Models = append(local.Models, app.ModelChoice{Name: "example/preferred", ThinkingLevels: []string{"off"}})
	m.config.Catalogue.Machines[m.config.LocalMachineName] = local
	machine = m.config.Machines["local"]
	machine.DefaultModel = "example/preferred"
	m.config.Machines["local"] = machine
	for i := 0; i < 3; i++ {
		m, _ = key(m, "enter")
	}
	m, _ = key(m, "up")
	m, _ = key(m, "enter")
	m, _ = key(m, "esc")
	if m.Request.Model != "example/vendor/model" || m.list.SelectedItem().(item) != "example/vendor/model" {
		t.Fatal("default replaced final user choice", m.View())
	}
}

func TestOwnerSessionUsesMachineDefaultModel(t *testing.T) {
	c := config(t)
	machine := c.Machines["local"]
	machine.DefaultModel = "example/preferred"
	c.Machines["local"] = machine
	local := c.Catalogue.Machines[c.LocalMachineName]
	local.Models = append(local.Models, app.ModelChoice{Name: "example/preferred", ThinkingLevels: []string{"off"}})
	c.Catalogue.Machines[c.LocalMachineName] = local
	m, _ := key(newModel(t, c, nil), "n")
	m = describeSession(m)
	m, _ = key(m, "down")
	m, _ = key(m, "enter")
	m, _ = key(m, "enter")
	if m.stage != pickModel || m.list.SelectedItem().(item) != "example/preferred" {
		t.Fatal(m.View())
	}
	m = confirmOptions(m)
	if !m.Ready || m.Request.Task != nil || m.Request.Model != "example/preferred" || m.Request.BaseRef != "" {
		t.Fatal(m.Request)
	}
}

func TestBaseFormUsesExistingRefsWithoutFetching(t *testing.T) {
	m := taskChoices(t, &app.Task{Title: "Task", Repo: "owner/one"})
	m, _ = key(m, "enter")
	m, _ = key(m, "enter")
	if m.stage != editBase || !strings.Contains(m.View(), "Remote-tracking ref: fetches the selected branch before creating the worktree.") {
		t.Fatal(m.View())
	}
	m.base.SetValue("main")
	if !strings.Contains(m.View(), "Local branch: uses the existing branch without fetching.") {
		t.Fatal(m.View())
	}
}
