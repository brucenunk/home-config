package tui

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

func commandKey(m CommandModel, key string) (CommandModel, tea.Cmd) {
	msg := tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(key)}
	switch key {
	case "enter":
		msg.Type = tea.KeyEnter
	case "esc":
		msg.Type = tea.KeyEsc
	case "ctrl+c":
		msg.Type = tea.KeyCtrlC
	case "left":
		msg.Type = tea.KeyLeft
	case "right":
		msg.Type = tea.KeyRight
	case "up":
		msg.Type = tea.KeyUp
	case "down":
		msg.Type = tea.KeyDown
	case "tab":
		msg.Type = tea.KeyTab
	}
	next, cmd := m.Update(msg)
	return next.(CommandModel), cmd
}

func TestCommandSelection(t *testing.T) {
	for _, test := range []struct {
		name string
		keys []string
		want string
	}{
		{"default", []string{"enter"}, "start"},
		{"start shortcut", []string{"right", "s"}, "start"},
		{"finish shortcut", []string{"f"}, "finish"},
		{"toggle back", []string{"right", "left", "enter"}, "start"},
		{"ignore other input", []string{"x", "enter"}, "start"},
	} {
		t.Run(test.name, func(t *testing.T) {
			m, err := NewCommand(config(t), t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			if m.Init() != nil || m.Command != "" {
				t.Fatal("selection must not begin a workflow")
			}
			var cmd tea.Cmd
			for _, key := range test.keys {
				m, cmd = commandKey(m, key)
			}
			if m.Command != test.want || cmd == nil || cmd() != tea.Quit() || m.View() != "" {
				t.Fatalf("selection: %q, expected %q", m.Command, test.want)
			}
		})
	}
}

func TestCommandNavigationAndCancellation(t *testing.T) {
	for _, key := range []string{"left", "right", "up", "down", "tab", "h", "l"} {
		m := CommandModel{styles: newStyles(testColors("light")), start: true}
		m, cmd := commandKey(m, key)
		if m.start || m.Command != "" || cmd != nil {
			t.Fatalf("%s should only toggle selection", key)
		}
		m, cmd = commandKey(m, "enter")
		if m.Command != "finish" || cmd == nil {
			t.Fatalf("%s did not select finish", key)
		}
	}
	for _, key := range []string{"esc", "q", "ctrl+c"} {
		m := CommandModel{start: false}
		m, cmd := commandKey(m, key)
		if m.Command != "" || cmd == nil || cmd() != tea.Quit() {
			t.Fatalf("%s should cancel without selecting a workflow", key)
		}
	}
}

func TestCommandPromptStyles(t *testing.T) {
	for _, mode := range []string{"light", "dark", "none"} {
		c := config(t)
		c.Theme.Mode = "light"
		var base Model
		if mode == "none" {
			base = newModel(t, c, nil)
		} else {
			c.Theme.Mode = mode
			base = themedModel(t, c)
		}
		m := CommandModel{styles: base.styles, start: true}
		for _, first := range []bool{true, false} {
			m.start = first
			view := ansi.Strip(m.View())
			for _, text := range []string{"herdsman", "Start or finish a task?", "Start", "Finish", "s/f", "esc cancel"} {
				if !strings.Contains(view, text) {
					t.Fatalf("%s prompt missing %q: %q", mode, text, view)
				}
			}
		}
		if mode == "none" && !m.styles.selected.GetReverse() {
			t.Fatal("neutral prompt lost selection emphasis")
		}
	}
}
