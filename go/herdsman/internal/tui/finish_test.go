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
	if !m.Ready || m.Target.Workspace.ID != "one" || cmd == nil || m.View() != "" {
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
	if items[0].(finishItem).Title() != "possum · Local — Same" || items[1].(finishItem).Title() != "helper · remote — Same" {
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
