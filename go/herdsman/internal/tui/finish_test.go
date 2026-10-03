package tui

import (
	"strings"
	"testing"

	"github.com/brucenunk/home-config/go/herdsman/internal/app"
	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
	tea "github.com/charmbracelet/bubbletea"
)

func finishKey(m FinishModel, s string) (FinishModel, tea.Cmd) {
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
	}
	next, cmd := m.Update(msg)
	return next.(FinishModel), cmd
}

func TestFinishPicker(t *testing.T) {
	targets := []app.FinishTarget{
		{Machine: herdr.Local(), Workspace: herdr.Workspace{ID: "one", Label: "First task"}},
		{Machine: herdr.Local(), Workspace: herdr.Workspace{ID: "two", Label: "Second task"}},
	}
	newPicker := func() FinishModel {
		m, err := NewFinish(config(t), targets, t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		return m
	}
	m := newPicker()
	if !strings.Contains(m.View(), "First task") || !strings.Contains(m.View(), "ctrl+n") {
		t.Fatal(m.View())
	}
	m, _ = finishKey(m, "ctrl+n")
	if m.picker.list.Index() != 1 || m.Ready {
		t.Fatal("navigation selected a session")
	}
	m, _ = finishKey(m, "ctrl+p")
	if m.picker.list.Index() != 0 {
		t.Fatal("up did not move")
	}
	m, cmd := finishKey(m, "enter")
	if !m.Ready || len(m.Targets) != 1 || m.Targets[0].Workspace.ID != "one" || cmd == nil || m.View() != "" {
		t.Fatal("Enter did not immediately select", m)
	}
	for _, s := range []string{"esc", "ctrl+c"} {
		m, cmd := finishKey(newPicker(), s)
		if m.Ready || cmd == nil {
			t.Fatal("cancel selected a session")
		}
	}
	m, _ = finishKey(newPicker(), "/")
	if m.picker.list.FilteringEnabled() || m.picker.list.SettingFilter() || m.Ready {
		t.Fatal("finish must not offer filtering")
	}
	m.picker.list.SetItems(nil)
	m, cmd = finishKey(m, "enter")
	if m.Ready || cmd != nil {
		t.Fatal("empty selection accepted")
	}
}

func TestFinishMultiSelection(t *testing.T) {
	targets := []app.FinishTarget{
		{Workspace: herdr.Workspace{ID: "one", Label: "Same"}},
		{Workspace: herdr.Workspace{ID: "two", Label: "Same"}},
		{Workspace: herdr.Workspace{ID: "three", Label: "Third"}},
	}
	m, err := NewFinish(config(t), targets, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	// Mark in reverse order; cleanup must still use displayed order.
	m, _ = finishKey(m, "ctrl+n")
	m, _ = finishKey(m, " ")
	m, _ = finishKey(m, "ctrl+p")
	m, _ = finishKey(m, "ctrl+p")
	m, _ = finishKey(m, " ")
	if m.Ready || m.marked != 2 || !strings.Contains(m.View(), "2 selected") || !strings.Contains(m.View(), "[✓]") {
		t.Fatal("marking submitted or did not update view", m.View())
	}
	for _, key := range []string{"esc", "ctrl+c"} {
		cancelled, cmd := finishKey(m, key)
		if cancelled.Ready || len(cancelled.Targets) != 0 || cmd == nil {
			t.Fatal("cancel submitted marked sessions")
		}
	}
	m, _ = finishKey(m, "ctrl+n")
	selected, cmd := finishKey(m, "enter")
	if !selected.Ready || cmd == nil || len(selected.Targets) != 2 || selected.Targets[0].Workspace.ID != "one" || selected.Targets[1].Workspace.ID != "two" {
		t.Fatal("wrong batch or order", selected.Targets)
	}
	// Quit is asynchronous; queued keys must not change or duplicate the batch.
	for _, key := range []string{"enter", " ", "ctrl+p", "enter", "esc"} {
		selected, cmd = finishKey(selected, key)
		if cmd != nil || !selected.Ready || len(selected.Targets) != 2 || selected.Targets[0].Workspace.ID != "one" || selected.Targets[1].Workspace.ID != "two" {
			t.Fatal("queued key changed submitted batch", key, selected.Targets)
		}
	}
	// Unmark everything; fallback must use the highlighted row.
	m, _ = finishKey(m, "ctrl+p")
	m, _ = finishKey(m, " ")
	m, _ = finishKey(m, "ctrl+p")
	m, _ = finishKey(m, "ctrl+p")
	m, _ = finishKey(m, " ")
	if m.marked != 0 || !strings.Contains(m.View(), "0 selected") {
		t.Fatal("unmarking did not update count")
	}
	m, _ = finishKey(m, "enter")
	if len(m.Targets) != 1 || m.Targets[0].Workspace.ID != "two" {
		t.Fatal("unmarked fallback selected wrong session", m.Targets)
	}
}

func TestFinishSpaceAdvancesWithoutWrapping(t *testing.T) {
	for _, count := range []int{0, 1, 12} {
		targets := make([]app.FinishTarget, count)
		for i := range targets {
			targets[i].Workspace.Label = "Task"
		}
		m, err := NewFinish(config(t), targets, t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		// Small height exercises advancing across page boundaries.
		next, _ := m.Update(tea.WindowSizeMsg{Width: 40, Height: 15})
		m = next.(FinishModel)
		if count == 0 {
			m, _ = finishKey(m, " ")
			if m.Ready || m.marked != 0 {
				t.Fatal("empty list accepted selection")
			}
			continue
		}
		for i := range targets {
			m, _ = finishKey(m, " ")
			if m.Ready || m.marked != i+1 || m.picker.list.Index() != min(i+1, count-1) || !m.picker.list.Items()[i].(finishItem).marked {
				t.Fatalf("count=%d row=%d: toggle did not advance correctly", count, i)
			}
		}
		// Deselecting the final row stays put; elsewhere it also advances.
		m, _ = finishKey(m, " ")
		if m.marked != count-1 || m.picker.list.Index() != count-1 {
			t.Fatal("final row wrapped on deselection")
		}
		if count > 1 {
			m.picker.list.Select(0)
			m, _ = finishKey(m, " ")
			if m.marked != count-2 || m.picker.list.Index() != 1 || m.picker.list.Items()[0].(finishItem).marked {
				t.Fatal("deselection did not advance")
			}
		}
	}
}

func TestFinishLabels(t *testing.T) {
	targets := []app.FinishTarget{
		{Machine: herdr.Local(), Agent: herdr.Agent{Name: "possum"}, Workspace: herdr.Workspace{Label: "Same"}},
		{Machine: herdr.Machine{ID: "remote", Label: "remote"}, Agent: herdr.Agent{Name: "helper"}, Workspace: herdr.Workspace{Label: "Same"}},
		{Machine: herdr.Local(), Workspace: herdr.Workspace{Label: "Unique\x1b[31m"}},
	}
	m, err := NewFinish(config(t), targets, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	items := m.picker.list.Items()
	if items[0].(finishItem).Title() != "[ ] possum · Local — Same" || items[1].(finishItem).Title() != "[ ] helper · remote — Same" {
		t.Fatal(items)
	}
	if strings.Contains(items[2].(finishItem).Title(), "\x1b") {
		t.Fatal("raw terminal controls in label")
	}
}

func TestLongDuplicateFinishLabels(t *testing.T) {
	label := strings.Repeat("A long task title ", 12)
	targets := []app.FinishTarget{
		{Machine: herdr.Local(), Agent: herdr.Agent{Name: "possum"}, Workspace: herdr.Workspace{Label: label}},
		{Machine: herdr.Machine{ID: "remote", Label: "remote"}, Agent: herdr.Agent{Name: "helper"}, Workspace: herdr.Workspace{Label: label}},
	}
	m, err := NewFinish(config(t), targets, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	next, _ := m.Update(tea.WindowSizeMsg{Width: 32, Height: 20})
	view := next.(FinishModel).View()
	if !strings.Contains(view, "possum") || !strings.Contains(view, "helper") {
		t.Fatal("truncation hid target identity", view)
	}
}
