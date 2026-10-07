package tui

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/brucenunk/home-config/go/herdsman/internal/app"
	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
	"github.com/charmbracelet/bubbles/list"
	tea "github.com/charmbracelet/bubbletea"
)

func config(t *testing.T) app.Config {
	return app.Config{LocalMachineName: "machine-a", Catalogue: app.Catalogue{Machines: map[string]app.CatalogueMachine{"machine-a": {Models: []app.ModelChoice{{Name: "example/vendor/model", ThinkingLevels: []string{"off", "medium", "high"}}}}}}, AgentNames: []string{"runner"}, TasksDir: t.TempDir(), Machines: map[string]app.MachineConfig{"local": {Repositories: map[string]app.RepositoryConfig{"owner/one": {Path: "/repos/owner/one"}, "owner/two": {Path: "/repos/owner/two"}}}}}
}

func newModel(t *testing.T, c app.Config, profiles []herdr.Machine) Model {
	t.Helper()
	m, err := New(c, profiles, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func key(m Model, s string) (Model, tea.Cmd) {
	msg := tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(s)}
	switch s {
	case "enter":
		msg.Type = tea.KeyEnter
	case "esc":
		msg.Type = tea.KeyEsc
	case "ctrl+c":
		msg.Type = tea.KeyCtrlC
	case "ctrl+n":
		msg.Type = tea.KeyCtrlN
	case "ctrl+p":
		msg.Type = tea.KeyCtrlP
	case "up":
		msg.Type = tea.KeyUp
	case "down":
		msg.Type = tea.KeyDown
	}
	next, cmd := m.Update(msg)
	return next.(Model), cmd
}

// Existing picker tests enter through the description screen, rather than
// bypassing the new promptless launch flow.
func describeSession(m Model) Model {
	m, _ = key(m, "Investigate deploy latency")
	m, _ = key(m, "enter")
	return m
}

// Confirm the new launch options, without bypassing any screen.
func confirmOptions(m Model) Model {
	for _, screen := range []stage{editBase, pickModel, pickThinking} {
		if m.stage == screen {
			m, _ = key(m, "enter")
		}
	}
	return m
}

func TestEmptySelectionAndCancellation(t *testing.T) {
	m := newModel(t, config(t), nil)
	m, _ = key(m, "n")
	m = describeSession(m)
	if m.stage != pickRepo || m.Ready {
		t.Fatal(m.stage, m.Ready)
	}
	m, _ = key(m, "enter")
	if m.stage != pickRepo || m.repoSelected || m.Request.Repo != "" {
		t.Fatal("Enter accepted an implicit repository", m.stage, m.Request)
	}
	m, _ = key(m, "down")
	m, _ = key(m, "enter")
	if m.stage != pickMachine {
		t.Fatal(m.stage)
	}
	m, cmd := key(m, "enter")
	m = confirmOptions(m)
	if !m.Ready || m.Request.Task != nil || m.Request.Repo != "owner" || !m.Request.Machine.IsLocal() {
		t.Fatal(m.Request, m.Ready)
	}
	for _, s := range []string{"esc", "ctrl+c", "q"} {
		m, cmd = key(newModel(t, config(t), nil), s)
		if m.Ready || cmd == nil {
			t.Fatal("cancel did not exit")
		}
	}
}

func TestSingleColumnContextsAndTaskRepositories(t *testing.T) {
	for _, withTask := range []bool{false, true} {
		m := newModel(t, config(t), nil)
		if withTask {
			m.Request.Task = &app.Task{Title: "Task"}
			m.repositories()
		} else {
			m, _ = key(m, "n")
			m = describeSession(m)
		}
		want := []string{"owner", "owner/one", "owner/two"}
		if withTask {
			want = want[1:]
		}
		if len(m.list.Items()) != len(want) || m.repoSelected {
			t.Fatal(m.list.Items(), m.repoSelected)
		}
		for i, row := range m.list.Items() {
			if row.(item).Title() != want[i] || row.(item).Description() != "" {
				t.Fatal("unexpected columns or ordering", row)
			}
		}
		m, _ = key(m, "down")
		if !withTask {
			m, _ = key(m, "down") // Choose a repository despite having no task file.
		}
		m, _ = key(m, "enter")
		m, _ = key(m, "enter")
		m = confirmOptions(m)
		if !m.Ready || m.Request.Repo != "owner/one" || (m.Request.Task != nil) != withTask {
			t.Fatal(m.Request)
		}
	}
}

func TestChoiceNavigationBindings(t *testing.T) {
	for _, picker := range []stage{pickRepo, pickMachine} {
		for _, bindings := range [][2]string{{"ctrl+n", "ctrl+p"}, {"down", "up"}, {"j", "k"}} {
			t.Run(fmt.Sprintf("%d/%s/%s", picker, bindings[0], bindings[1]), func(t *testing.T) {
				c := config(t)
				c.Machines["remote"] = app.MachineConfig{Repositories: map[string]app.RepositoryConfig{"owner/one": {Path: "/repos/owner/one"}}}
				profiles := []herdr.Machine{{ID: "remote-profile", Label: "remote", Enabled: true}}
				m, _ := key(newModel(t, c, profiles), "n")
				m = describeSession(m)
				m, _ = key(m, bindings[0]) // Explicitly select the first repository.
				if picker == pickMachine {
					m, _ = key(m, "enter")
				}
				if m.stage != picker || m.list.Index() != 0 {
					t.Fatal("unexpected initial selection", m.stage, m.list.Index())
				}
				m, _ = key(m, bindings[0])
				if m.stage != picker || m.list.Index() != 1 || m.Ready {
					t.Fatal("down did not move without choosing", m.stage, m.list.Index(), m.Ready)
				}
				m, _ = key(m, bindings[1])
				if m.stage != picker || m.list.Index() != 0 || m.Ready {
					t.Fatal("up did not move without choosing", m.stage, m.list.Index(), m.Ready)
				}
				if !strings.Contains(m.View(), "ctrl+p") || !strings.Contains(m.View(), "ctrl+n") {
					t.Fatal("navigation help omits Emacs bindings", m.View())
				}
			})
		}
	}
}

func TestDescriptionFormRequiredBeforeContextAndPreservedOnBack(t *testing.T) {
	m, _ := key(newModel(t, config(t), nil), "n")
	if m.stage != askDescription || !m.description.Focused() || m.description.Value() != "" || !strings.Contains(m.View(), "Session description") || !strings.Contains(m.View(), "enter continue · esc back") {
		t.Fatal(m.stage, m.View())
	}
	m, _ = key(m, "enter")
	if m.stage != askDescription || m.message == "" || m.Ready {
		t.Fatal("empty description advanced", m.stage, m.message)
	}
	m, _ = key(m, "   ")
	m, _ = key(m, "enter")
	if m.stage != askDescription || m.Ready {
		t.Fatal("whitespace advanced")
	}
	m.description.SetValue("")
	m, _ = key(m, "Investigate déploiement 🐾")
	m, _ = key(m, "enter")
	if m.stage != pickRepo || m.description.Focused() || m.Request.Description != "Investigate déploiement 🐾" || m.repoSelected {
		t.Fatal(m.stage, m.Request)
	}
	m, _ = key(m, "esc")
	if m.stage != askDescription || !m.description.Focused() || m.description.Value() != "Investigate déploiement 🐾" {
		t.Fatal("context back lost description", m.stage, m.description.Value())
	}
	m, _ = key(m, "esc")
	if m.stage != askTask || m.description.Focused() {
		t.Fatal("description escape did not go back")
	}
	m, _ = key(m, "n")
	m, _ = key(m, "enter")
	if m.stage != pickRepo || m.Request.Description != "Investigate déploiement 🐾" {
		t.Fatal(m.Request)
	}
	m, _ = key(m, "down")
	m, _ = key(m, "enter")
	if m.stage != pickMachine {
		t.Fatal(m.stage)
	}
	m, _ = key(m, "esc")
	m, _ = key(m, "esc")
	if m.stage != askDescription || m.description.Value() != "Investigate déploiement 🐾" {
		t.Fatal("machine back lost description")
	}
}

func TestDescriptionInputResizeAndCancellation(t *testing.T) {
	m, _ := key(newModel(t, config(t), nil), "n")
	for _, width := range []int{1, 20, 100} {
		next, _ := m.Update(tea.WindowSizeMsg{Width: width, Height: 20})
		m = next.(Model)
		if m.description.Width != max(1, width-4) {
			t.Fatal(m.description.Width)
		}
		_ = m.View()
	}
	m, _ = key(m, "q") // q is description text, not a quit shortcut here.
	if m.description.Value() != "q" {
		t.Fatal(m.description.Value())
	}
	m, cmd := key(m, "ctrl+c")
	if cmd == nil || m.Ready {
		t.Fatal("description cancellation did not exit")
	}
}

func TestLocalDisplayDoesNotChangeMachineIdentity(t *testing.T) {
	c := config(t)
	c.Machines["Local"] = app.MachineConfig{Repositories: map[string]app.RepositoryConfig{"owner/one": {Path: "/repos/owner/one"}}}
	profiles := []herdr.Machine{{ID: "remote-profile", Label: "Local", Target: "ssh-alias", Enabled: true}}
	m, _ := key(newModel(t, c, profiles), "n")
	m = describeSession(m)
	m, _ = key(m, "down")
	m, _ = key(m, "enter")
	if selected := m.list.SelectedItem().(machineItem); selected.Title() != "Local" || !selected.machine.IsLocal() {
		t.Fatal(selected)
	}
	local := m
	local, _ = key(local, "enter")
	if !local.Request.Machine.IsLocal() || local.Request.Machine.Label != "local" {
		t.Fatal(local.Request.Machine)
	}
	next, _ := m.Update(tea.KeyMsg{Type: tea.KeyUp})
	m = next.(Model)
	m, _ = key(m, "enter")
	if m.Request.Machine.IsLocal() || m.Request.Machine.ID != "remote-profile" {
		t.Fatal("display label retargeted remote selection", m.Request.Machine)
	}
}

func TestLeavingTaskPickerOffersEmptyOrCancel(t *testing.T) {
	for _, answer := range []string{"y", "n"} {
		m := newModel(t, config(t), nil)
		m, _ = key(m, "y")
		if m.stage != pickTask {
			t.Fatal(m.stage)
		}
		m, _ = key(m, "esc")
		if m.stage != askEmpty || m.Ready {
			t.Fatal(m.stage)
		}
		m, cmd := key(m, answer)
		if answer == "y" {
			if m.stage != askDescription || m.Request.Task != nil {
				t.Fatal(m.stage)
			}
		} else if cmd == nil || m.Ready {
			t.Fatal("No must cancel")
		}
	}
}

func TestTaskFileSelectionUsesRepoHint(t *testing.T) {
	c := config(t)
	p := filepath.Join(c.TasksDir, "20260930T193614==todo--task.md")
	if err := os.WriteFile(p, []byte("---\ntitle: Task\nrepo: owner/two\n---\nTask body\n"), 0600); err != nil {
		t.Fatal(err)
	}
	m := newModel(t, c, nil)
	m, cmd := key(m, "y")
	// Filename indexing runs as a command; deliver its result as Tea would.
	next, _ := m.Update(cmd())
	m = next.(Model)
	m, cmd = key(m, "enter")
	if m.stage != pickTask || !m.taskLoading || cmd == nil {
		t.Fatal("task load must be asynchronous")
	}
	next, _ = m.Update(cmd())
	m = next.(Model)
	if m.stage != pickMachine || m.Request.Task == nil || m.Request.Repo != "owner/two" {
		t.Fatalf("stage=%v task=%+v", m.stage, m.Request.Task)
	}
	m, _ = key(m, "enter")
	m = confirmOptions(m)
	if !m.Ready || m.Request.Repo != "owner/two" || m.Request.Task.Title != "Task" {
		t.Fatal(m.Request)
	}
}

func TestUnavailableMachineAndBackNavigation(t *testing.T) {
	c := config(t)
	c.Machines = map[string]app.MachineConfig{"missing": {Repositories: map[string]app.RepositoryConfig{"owner/one": {Path: "/repos/owner/one"}}}}
	m := newModel(t, c, nil)
	m, _ = key(m, "n")
	m = describeSession(m)
	m, _ = key(m, "down")
	m, _ = key(m, "enter")
	if m.stage != pickRepo || m.message == "" || m.Ready {
		t.Fatal(m.stage, m.message)
	}
	m = newModel(t, config(t), nil)
	m, _ = key(m, "n")
	m = describeSession(m)
	m, _ = key(m, "down")
	m, _ = key(m, "enter")
	m, _ = key(m, "esc")
	if m.stage != pickRepo || !m.repoSelected || m.Request.Repo != "owner" {
		t.Fatal(m.stage, m.Request)
	}
	m, _ = key(m, "enter")
	if m.stage != pickMachine {
		t.Fatal("back navigation lost repository selection")
	}
	m, _ = key(m, "esc")
	m, _ = key(m, "esc")
	if m.stage != askDescription {
		t.Fatal(m.stage)
	}
}

func TestFilteringEnterDoesNotChoosePrematurely(t *testing.T) {
	m := newModel(t, config(t), nil)
	m, _ = key(m, "n")
	m = describeSession(m)
	m, _ = key(m, "/")
	if m.list.FilterState() != list.Filtering {
		t.Fatal(m.list.FilterState())
	}
	m, _ = key(m, "enter")
	if m.stage != pickRepo || m.Ready {
		t.Fatal("filter enter selected repository")
	}
}

func TestRepositorySelectionSurvivesResizeButNotFiltering(t *testing.T) {
	m, _ := key(newModel(t, config(t), nil), "n")
	m = describeSession(m)
	resize := func() {
		next, _ := m.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
		m = next.(Model)
	}
	resize()
	if m.repoSelected || !strings.Contains(m.View(), "Navigate to select") {
		t.Fatal("resize created an initial selection", m.list.Index())
	}
	m, _ = key(m, "down")
	resize()
	if !m.repoSelected || m.list.SelectedItem().(item) != "owner" {
		t.Fatal("resize lost explicit selection")
	}
	m, _ = key(m, "/")
	m, filterCmd := key(m, "two")
	// Deliver actual asynchronous filter results, ignoring input blink messages.
	var deliverFilter func(tea.Cmd)
	deliverFilter = func(cmd tea.Cmd) {
		if cmd == nil {
			return
		}
		switch msg := cmd().(type) {
		case tea.BatchMsg:
			for _, child := range msg {
				deliverFilter(child)
			}
		case list.FilterMatchesMsg:
			next, _ := m.Update(msg)
			m = next.(Model)
		}
	}
	deliverFilter(filterCmd)
	m, _ = key(m, "enter") // Accept the filter, not a repository.
	if m.list.FilterState() != list.FilterApplied || len(m.list.VisibleItems()) != 1 || m.repoSelected {
		t.Fatal("filter created a selection", m.list.FilterState(), m.list.Index())
	}
	m, _ = key(m, "enter")
	if m.stage != pickRepo || m.Request.Repo != "" {
		t.Fatal("Enter accepted the first filtered result", m.Request)
	}
	m, _ = key(m, "down")
	if !m.repoSelected || m.list.SelectedItem().(item) != "owner/two" {
		t.Fatal("navigation did not select the filtered result")
	}
	m, _ = key(m, "esc") // Clearing the filter also clears selection.
	if m.stage != pickRepo || m.repoSelected {
		t.Fatal("clearing the filter retained selection")
	}
	m, _ = key(m, "down")
	m, _ = key(m, "enter")
	if m.stage != pickMachine || m.Request.Repo != "owner" {
		t.Fatal("explicit selection did not advance", m.Request)
	}
}

func TestSingleRepositoryStillRequiresSelection(t *testing.T) {
	c := config(t)
	c.Machines["local"] = app.MachineConfig{Repositories: map[string]app.RepositoryConfig{"owner/one": {Path: "/repos/owner/one"}}}
	m, _ := key(newModel(t, c, nil), "n")
	m = describeSession(m)
	for i := 0; i < 2; i++ {
		m, _ = key(m, "enter")
		if m.stage != pickRepo || m.repoSelected || m.Ready {
			t.Fatal("single repository was implicitly selected")
		}
	}
	m, _ = key(m, "up")
	m, _ = key(m, "enter")
	if m.stage != pickMachine || m.Request.Repo != "owner" {
		t.Fatal("explicit selection did not advance")
	}
}

func TestRepositorySelectionKeepsFrameHeightStable(t *testing.T) {
	m, _ := key(newModel(t, config(t), nil), "n")
	m = describeSession(m)
	initialHeight := strings.Count(m.View(), "\n")
	for _, navigation := range []string{"down", "down", "up"} {
		m, _ = key(m, navigation)
		view := m.View()
		if !m.repoSelected || strings.Count(view, "\n") != initialHeight {
			t.Fatal("repository selection changed the frame height")
		}
		if !strings.Contains(view, "Navigate to select") {
			t.Fatal("repository navigation hint disappeared")
		}
	}
}

func TestInitialAndLaterWindowSizes(t *testing.T) {
	m := newModel(t, config(t), nil)
	resize := func() {
		next, _ := m.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
		m = next.(Model)
		if m.width != 100 || m.height != 30 {
			t.Fatal(m.width, m.height)
		}
	}
	resize() // Tea sends this before a list has been initialized.
	m, _ = key(m, "y")
	resize()
	m, _ = key(m, "esc")
	resize()
	m, _ = key(m, "y")
	resize()
	m, _ = key(m, "enter")
	resize()
}

func TestUnselectedRepositoryRendersWithOneRowPagination(t *testing.T) {
	m, _ := key(newModel(t, config(t), nil), "n")
	m = describeSession(m)
	for _, size := range []tea.WindowSizeMsg{
		{Width: 20, Height: 1}, {Width: 80, Height: 8}, {Width: 100, Height: 30},
	} {
		next, _ := m.Update(size)
		m = next.(Model)
		for i := 0; i < 2; i++ {
			m, _ = key(m, "?")
			_ = m.View()
			m, _ = key(m, "enter")
			if m.stage != pickRepo || m.repoSelected || m.list.Paginator.Page < 0 {
				t.Fatal("resize/help created a selection or invalid page")
			}
		}
	}
	m.list.SetHeight(1)
	if m.list.Paginator.PerPage != 1 {
		t.Fatal("test requires one-row pagination")
	}
	_ = m.View()
	m, _ = key(m, "down")
	_ = m.View()
	m, _ = key(m, "enter")
	if m.stage != pickMachine || m.Request.Repo != "owner" {
		t.Fatal("small-terminal selection did not advance")
	}
}

func TestMissingTaskDirectoryOffersEmptyOrCancel(t *testing.T) {
	c := config(t)
	c.TasksDir = filepath.Join(c.TasksDir, "missing")
	m, cmd := key(newModel(t, c, nil), "y")
	next, _ := m.Update(cmd())
	m = next.(Model)
	if m.stage != askEmpty || m.Ready || !strings.Contains(m.View(), "cannot read task directory") {
		t.Fatal(m.stage, m.View())
	}
	m, cmd = key(m, "n")
	if cmd == nil || m.Ready {
		t.Fatal("No must cancel")
	}
}

func TestUnreadableEpicReportsIndexError(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can read mode-000 directories")
	}
	c := config(t)
	blocked := filepath.Join(c.TasksDir, "blocked")
	if err := os.Mkdir(blocked, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(c.TasksDir, "stale.md"), []byte("task"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(blocked, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(blocked, 0700) })
	m, cmd := key(newModel(t, c, nil), "y")
	next, _ := m.Update(cmd())
	m = next.(Model)
	if m.stage != askEmpty || !strings.Contains(m.message, blocked) || strings.Contains(m.View(), "stale.md") {
		t.Fatal(m.View())
	}
}

func TestLatePickerReadCannotReopenCancelledSelection(t *testing.T) {
	m, cmd := key(newModel(t, config(t), nil), "y")
	m, _ = key(m, "esc")
	next, _ := m.Update(cmd())
	m = next.(Model)
	if m.stage != askEmpty || m.Ready {
		t.Fatal(m.stage)
	}
}

func TestTaskReadResultCannotUndoCancellation(t *testing.T) {
	c := config(t)
	path := filepath.Join(c.TasksDir, "20260930T193614==todo--task.md")
	if err := os.WriteFile(path, []byte("---\ntitle: Task\nskill: review\n---\nBody"), 0600); err != nil {
		t.Fatal(err)
	}
	m, cmd := key(newModel(t, c, nil), "y")
	next, _ := m.Update(cmd())
	m = next.(Model)
	m, cmd = key(m, "enter")
	if !m.taskLoading {
		t.Fatal("task load is synchronous")
	}
	m, _ = key(m, "esc")
	next, _ = m.Update(cmd())
	m = next.(Model)
	if m.stage != askEmpty || m.Request.Task != nil || m.Ready {
		t.Fatal("task result undid cancellation")
	}
}

func TestDisappearingTaskDoesNotCrashOrLaunch(t *testing.T) {
	c := config(t)
	path := filepath.Join(c.TasksDir, "20260930T193614==todo--task.md")
	if err := os.WriteFile(path, []byte("task"), 0600); err != nil {
		t.Fatal(err)
	}
	m, cmd := key(newModel(t, c, nil), "y")
	next, _ := m.Update(cmd())
	m = next.(Model)
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	_ = m.View() // Cached filenames render safely after deletion.
	m, cmd = key(m, "enter")
	next, _ = m.Update(cmd())
	m = next.(Model)
	if m.message == "" || m.stage != pickTask || m.Ready || m.Request.Task != nil {
		t.Fatal(m.stage, m.message)
	}
}

func TestQueryBeforeIndexCompletesAndOneEnterSelection(t *testing.T) {
	c := config(t)
	dir := filepath.Join(c.TasksDir, "network")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "20260930T193614==todo--network-share.md"), []byte("---\ntitle: Share\nskill: review\n---\nBody"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(c.TasksDir, "20260930T193615==todo--other.md"), []byte("invalid"), 0600); err != nil {
		t.Fatal(err)
	}
	m, indexCmd := key(newModel(t, c, nil), "y")
	m, _ = key(m, "netshare")
	next, _ := m.Update(indexCmd())
	m = next.(Model)
	if m.selector.query.Value() != "netshare" || len(m.selector.list.Items()) != 1 {
		t.Fatal(m.selector.query.Value(), m.selector.list.Items())
	}
	m, cmd := key(m, "enter")
	if !m.taskLoading || cmd == nil {
		t.Fatal("Enter did not select directly")
	}
	next, _ = m.Update(cmd())
	m = next.(Model)
	if m.stage != pickRepo || m.Request.Task == nil || m.Request.Task.Title != "Share" {
		t.Fatal(m.stage, m.Request.Task)
	}
}
