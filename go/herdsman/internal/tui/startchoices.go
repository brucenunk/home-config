package tui

import (
	"fmt"
	"slices"

	listkey "github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/list"
	tea "github.com/charmbracelet/bubbletea"
)

func indexName(names []string, name string) int { return slices.Index(names, name) }

func (m *Model) seedHints() {
	if m.Request.Task == m.hintTask {
		return
	}
	m.hintTask = m.Request.Task
	m.Request.Repo, m.Request.Model, m.Request.Thinking, m.Request.BaseRef = "", "", "", ""
	m.machineName, m.baseExplicit, m.thinkingExplicit = "", false, false
	m.base.SetValue("")
	if task := m.Request.Task; task != nil {
		m.Request.Repo, m.Request.Model, m.Request.Thinking, m.Request.BaseRef = task.Repo, task.Model, task.Thinking, task.BaseRef
		m.machineName, m.baseExplicit, m.thinkingExplicit = task.Machine, task.BaseRef != "", task.Thinking != ""
		m.base.SetValue(task.BaseRef)
	}
}

// An incompatible explicit value leaves the list unselected. Only navigation
// can replace it; Enter must not accidentally accept Bubbles' first row.
func (m *Model) selectChoice(names []string, value, kind string) {
	i := indexName(names, value)
	m.choiceSelected = i >= 0
	if i >= 0 {
		m.list.Select(i)
	} else {
		m.message = fmt.Sprintf("%s %q is unavailable or incompatible. Navigate to choose a replacement.", kind, value)
	}
	m.list.SetDelegate(m.choiceDelegate(!m.choiceSelected))
}

func (m *Model) machines() {
	m.destinations = m.config.Destinations(m.Request.Repo, m.profiles)
	m.stage, m.message = pickMachine, ""
	names := make([]string, len(m.destinations))
	labels := make([]string, len(m.destinations))
	items := make([]list.Item, len(m.destinations))
	initial := ""
	for i, d := range m.destinations {
		names[i], labels[i], items[i] = d.DisplayName(), m.config.MachineName(d), machineItem{machine: d}
		if initial == "" || d.IsLocal() {
			initial = labels[i]
		}
	}
	m.choices("Choose machine", names)
	m.list.SetItems(items)
	value := m.machineName
	if value == "" {
		value = initial
	}
	m.selectChoice(labels, value, "Machine")
}

func (m Model) defaultBase() string {
	if refs := m.config.Catalogue.Machines[m.config.MachineName(m.Request.Machine)].DefaultBaseRefs; refs != nil {
		return refs[m.Request.Repo]
	}
	return m.config.Machines[m.Request.Machine.Label].Repositories[m.Request.Repo].BaseRef()
}
func (m *Model) beginBase() tea.Cmd {
	m.stage, m.message = editBase, ""
	if !m.baseExplicit {
		m.Request.BaseRef = m.defaultBase()
	} else {
		m.Request.BaseRef = m.base.Value()
	}
	m.base.SetValue(m.Request.BaseRef)
	m.base.CursorEnd()
	return m.base.Focus()
}
func (m *Model) models() {
	m.stage, m.message = pickModel, ""
	var names []string
	for _, model := range m.config.Models(m.Request.Machine) {
		names = append(names, model.Name)
	}
	m.choices("Choose model", names)
	value := m.Request.Model
	if value == "" {
		value = m.config.Catalogue.Machines[m.config.MachineName(m.Request.Machine)].DefaultModel
	}
	if value == "" {
		value = m.config.Machines[m.Request.Machine.Label].DefaultModel
	}
	if value == "" && len(names) > 0 {
		value = names[0]
	}
	m.selectChoice(names, value, "Model")
	if len(names) == 0 {
		m.message = "No configured models for this destination. Go back or update configuration and restart the daemon."
	}
}
func (m *Model) thinking() {
	m.stage, m.message = pickThinking, ""
	model, _ := m.config.Model(m.Request.Machine, m.Request.Model)
	m.choices("Choose thinking · "+model.Name, model.ThinkingLevels)
	value := m.Request.Thinking
	if !m.thinkingExplicit {
		value = model.DefaultThinking()
	}
	m.selectChoice(model.ThinkingLevels, value, "Thinking")
	if value == "" {
		m.message = "Choose a supported thinking level for this model."
	}
	if len(model.ThinkingLevels) == 0 {
		m.message = "This configured model has no supported thinking levels. Choose another model or update configuration."
	}
}

func (m *Model) updateChoiceList(msg tea.Msg) tea.Cmd {
	selected := m.choiceSelected
	navigated := false
	filterState := m.list.FilterState()
	if k, ok := msg.(tea.KeyMsg); ok && filterState != list.Filtering {
		bindings := m.list.KeyMap
		if listkey.Matches(k, bindings.CursorUp, bindings.CursorDown, bindings.PrevPage, bindings.NextPage, bindings.GoToStart, bindings.GoToEnd) {
			navigated = true
			if !selected {
				m.list.Select(0)
				if listkey.Matches(k, bindings.CursorUp, bindings.CursorDown) {
					m.choiceSelected = m.list.SelectedItem() != nil
					m.list.SetDelegate(m.choiceDelegate(!m.choiceSelected))
					m.rememberThinkingSelection()
					return nil
				}
			}
			selected = true
		}
	}
	var cmd tea.Cmd
	m.list, cmd = m.list.Update(msg)
	_, matchesUpdated := msg.(list.FilterMatchesMsg)
	if matchesUpdated || filterState == list.Filtering || filterState != m.list.FilterState() {
		selected = false
	}
	m.choiceSelected = selected && m.list.SelectedItem() != nil
	m.list.SetDelegate(m.choiceDelegate(!m.choiceSelected))
	if navigated {
		m.rememberThinkingSelection()
	}
	return cmd
}

// Thinking confirmation launches immediately, so deliberate navigation must
// also be retained when the user backs out to reconsider the model/destination.
func (m *Model) rememberThinkingSelection() {
	if m.stage == pickThinking && m.choiceSelected {
		m.Request.Thinking = m.list.SelectedItem().(item).Title()
		m.thinkingExplicit = true
	}
}
