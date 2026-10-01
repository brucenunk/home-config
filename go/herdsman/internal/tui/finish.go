package tui

import (
	"fmt"
	"strconv"

	"github.com/brucenunk/home-config/go/herdsman/internal/app"
	"github.com/charmbracelet/bubbles/list"
	tea "github.com/charmbracelet/bubbletea"
)

type finishItem struct {
	label  string
	target app.FinishTarget
}

func (i finishItem) Title() string       { return i.label }
func (i finishItem) Description() string { return "" }
func (i finishItem) FilterValue() string { return i.label }

// Display labels as text, never as terminal control sequences.
func displayLabel(s string) string {
	return displayText(s)
}

type FinishModel struct {
	picker Model
	Target app.FinishTarget
	Ready  bool
}

func NewFinish(c app.Config, targets []app.FinishTarget, themeDir string) (FinishModel, error) {
	picker, err := New(c, nil, themeDir)
	if err != nil {
		return FinishModel{}, err
	}
	counts := map[string]int{}
	for _, t := range targets {
		counts[displayLabel(t.Workspace.Label)]++
	}
	items := make([]list.Item, len(targets))
	labels := make([]string, len(targets))
	for i, t := range targets {
		label := displayLabel(t.Workspace.Label)
		if counts[label] > 1 {
			label = fmt.Sprintf("%s · %s — %s", displayLabel(t.Agent.Name), displayLabel(t.Machine.DisplayName()), label)
		}
		labels[i] = label
		items[i] = finishItem{label, t}
	}
	// Profile labels can also collide; keep every final row distinguishable.
	counts = map[string]int{}
	for _, label := range labels {
		counts[label]++
	}
	for i, item := range items {
		row := item.(finishItem)
		if counts[row.label] > 1 {
			row.label = "[" + strconv.Itoa(i+1) + "] " + row.label
			items[i] = row
		}
	}
	picker.choices("Choose session to finish", labels, "")
	picker.list.SetFilteringEnabled(false)
	picker.list.SetItems(items)
	return FinishModel{picker: picker}, nil
}

func (m FinishModel) Init() tea.Cmd { return nil }

func (m FinishModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if size, ok := msg.(tea.WindowSizeMsg); ok {
		m.picker.list.SetSize(size.Width, max(8, size.Height-5))
	}
	if key, ok := msg.(tea.KeyMsg); ok {
		switch key.String() {
		case "ctrl+c", "esc":
			return m, tea.Quit
		case "enter":
			if selected, ok := m.picker.list.SelectedItem().(finishItem); ok {
				m.Target, m.Ready = selected.target, true
				return m, tea.Quit
			}
			return m, nil
		}
	}
	var cmd tea.Cmd
	m.picker.list, cmd = m.picker.list.Update(msg)
	return m, cmd
}

func (m FinishModel) View() string {
	if m.Ready {
		return ""
	}
	return fmt.Sprintf("\n%s\n\n%s\n\n%s\n", m.picker.styles.title.Render("herdsman finish"), m.picker.list.View(), m.picker.styles.muted.Render("enter finishes · esc/ctrl+c cancels"))
}
