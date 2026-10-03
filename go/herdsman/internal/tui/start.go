// Package tui collects a request; launch side effects happen only after it exits.
package tui

import (
	"fmt"
	"strings"

	"github.com/brucenunk/home-config/go/herdsman/internal/app"
	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
	"github.com/brucenunk/home-config/go/herdsman/internal/tui/themes"
	listkey "github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/list"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type stage int

const (
	askTask stage = iota
	pickTask
	askEmpty
	pickRepo
	pickMachine
)

type item string

func (i item) Title() string       { return string(i) }
func (i item) Description() string { return "" }
func (i item) FilterValue() string { return string(i) }

type machineItem struct{ machine herdr.Machine }

func (i machineItem) Title() string       { return i.machine.DisplayName() }
func (i machineItem) Description() string { return "" }
func (i machineItem) FilterValue() string { return i.Title() }

type Model struct {
	styles        styles
	config        app.Config
	profiles      []herdr.Machine
	stage         stage
	yes           bool
	selector      taskSelector
	indexLoading  bool
	taskLoading   bool
	readID        int
	list          list.Model
	repoSelected  bool
	destinations  []herdr.Machine
	width, height int
	message       string
	Request       app.StartRequest
	Ready         bool
}

func New(c app.Config, profiles []herdr.Machine, themeDir string) (Model, error) {
	// Configuration is validated before constructing the UI. Detect once, before
	// Bubble Tea starts reading terminal input, rather than during rendering.
	theme := c.Theme.WithDefaults()
	if theme.Mode != "auto" {
		// Bubbles renders adaptive colors during construction, even though we
		// replace them. Prevent it from querying the terminal inside Update.
		lipgloss.SetHasDarkBackground(theme.Mode == "dark")
	}
	colors, err := themes.Load(themeDir, theme.Name(lipgloss.HasDarkBackground))
	if err != nil {
		return Model{}, err
	}
	return Model{config: c, profiles: profiles, styles: newStyles(colors), yes: true, width: 80, height: 22}, nil
}

func (m Model) Init() tea.Cmd { return nil }

type tasksIndexedMsg struct {
	id    int
	files []taskFile
	err   error
}

type taskReadMsg struct {
	id   int
	task *app.Task
	err  error
}

func (m *Model) readTask(path string) tea.Cmd {
	m.readID++
	m.taskLoading = true
	id := m.readID
	return func() tea.Msg {
		task, err := app.ReadTask(path)
		return taskReadMsg{id: id, task: task, err: err}
	}
}

func (m *Model) beginTasks() tea.Cmd {
	m.selector = newTaskSelector(m.width, m.height)
	m.selector.applyStyles(m.styles)
	m.readID++
	m.indexLoading, m.taskLoading = true, false
	id, root := m.readID, m.config.TasksDir
	return func() tea.Msg {
		files, err := discoverTasks(root)
		return tasksIndexedMsg{id: id, files: files, err: err}
	}
}

func (m *Model) choices(title string, names []string) {
	items := make([]list.Item, len(names))
	for i, n := range names {
		items[i] = item(n)
	}
	m.list = list.New(items, m.choiceDelegate(false), m.width, max(8, m.height-5))
	m.list.KeyMap.CursorUp.SetKeys(append(m.list.KeyMap.CursorUp.Keys(), "ctrl+p")...)
	m.list.KeyMap.CursorUp.SetHelp("↑/k/ctrl+p", "up")
	m.list.KeyMap.CursorDown.SetKeys(append(m.list.KeyMap.CursorDown.Keys(), "ctrl+n")...)
	m.list.KeyMap.CursorDown.SetHelp("↓/j/ctrl+n", "down")
	m.styles.list(&m.list)
	m.list.Title = title
	m.list.SetShowStatusBar(false)
	m.list.DisableQuitKeybindings()
}

func (m *Model) repositories() {
	m.stage, m.message = pickRepo, ""
	m.Request.Repo = ""
	m.choices("Choose repository", m.config.RepositoryNames())
	m.setRepositorySelection(false)
}

func (m Model) choiceDelegate(unselected bool) choiceDelegate {
	d := list.NewDefaultDelegate()
	d.ShowDescription = false
	d.SetSpacing(0)
	d.Styles = m.styles.items()
	return choiceDelegate{DefaultDelegate: d, unselected: unselected}
}

func (m *Model) setRepositorySelection(selected bool) {
	m.repoSelected = selected
	m.list.SetDelegate(m.choiceDelegate(!selected))
}

// Bubbles selects the first row by default and can reset its cursor while
// filtering or resizing. Only explicit navigation may select a repository.
func (m *Model) updateRepositoryList(msg tea.Msg) tea.Cmd {
	selected := m.repoSelected
	filterState := m.list.FilterState()
	if k, ok := msg.(tea.KeyMsg); ok && filterState != list.Filtering {
		bindings := m.list.KeyMap
		if listkey.Matches(k, bindings.CursorUp, bindings.CursorDown, bindings.PrevPage,
			bindings.NextPage, bindings.GoToStart, bindings.GoToEnd) {
			if !selected {
				m.list.Select(0)
				if listkey.Matches(k, bindings.CursorUp, bindings.CursorDown) {
					m.setRepositorySelection(m.list.SelectedItem() != nil)
					return nil
				}
			}
			selected = true
		}
	}
	var cmd tea.Cmd
	m.list, cmd = m.list.Update(msg)
	_, matchesUpdated := msg.(list.FilterMatchesMsg)
	if !selected || matchesUpdated || filterState == list.Filtering || filterState != m.list.FilterState() {
		selected = false
	}
	m.setRepositorySelection(selected && m.list.SelectedItem() != nil)
	return cmd
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if result, ok := msg.(taskReadMsg); ok {
		if m.stage != pickTask || result.id != m.readID {
			return m, nil
		}
		m.taskLoading = false
		if result.err != nil {
			m.message = result.err.Error()
		} else {
			m.Request.Task = result.task
			m.repositories()
		}
		return m, nil
	}
	if result, ok := msg.(tasksIndexedMsg); ok {
		if m.stage != pickTask || result.id != m.readID {
			return m, nil
		}
		m.indexLoading = false
		if result.err != nil {
			m.stage, m.yes, m.message = askEmpty, true, result.err.Error()
			return m, nil
		}
		m.selector.setFiles(result.files)
		return m, nil
	}
	if size, ok := msg.(tea.WindowSizeMsg); ok {
		m.width, m.height = size.Width, size.Height
		if m.stage == pickTask {
			m.selector.resize(size.Width, size.Height)
		}
		if m.stage == pickRepo || m.stage == pickMachine {
			m.list.SetSize(size.Width, max(8, size.Height-5))
		}
	}
	if key, ok := msg.(tea.KeyMsg); ok {
		if key.String() == "ctrl+c" {
			return m, tea.Quit
		}
		if m.stage == askTask || m.stage == askEmpty {
			submit := false
			switch key.String() {
			case "esc", "q":
				return m, tea.Quit
			case "left", "right", "up", "down", "tab", "h", "l":
				m.yes = !m.yes
			case "y":
				m.yes, submit = true, true
			case "n":
				m.yes, submit = false, true
			case "enter":
				submit = true
			}
			if submit {
				if m.stage == askEmpty {
					if !m.yes {
						return m, tea.Quit
					}
					m.Request.Task = nil
					m.repositories()
				} else if m.yes {
					m.stage, m.message = pickTask, ""
					cmd := m.beginTasks()
					return m, cmd
				} else {
					m.repositories()
				}
			}
			return m, nil
		}
		if key.String() == "esc" {
			switch m.stage {
			case pickTask:
				m.stage, m.yes, m.message = askEmpty, true, ""
			case pickRepo:
				if m.list.FilterState() != list.Unfiltered {
					break
				}
				m.stage, m.yes, m.message = askTask, true, ""
				m.Request.Task = nil
				return m, nil
			case pickMachine:
				if m.list.FilterState() != list.Unfiltered {
					break
				}
				m.repositories()
				return m, nil
			}
			if m.stage == askEmpty {
				return m, nil
			}
		}
		if m.stage == pickTask {
			if m.taskLoading {
				return m, nil
			}
			if key.String() == "enter" {
				if !m.indexLoading {
					if path := m.selector.selectedPath(); path != "" {
						m.message = ""
						cmd := m.readTask(path)
						return m, cmd
					}
				}
				return m, nil
			}
		}
		if key.String() == "enter" && (m.stage == pickRepo || m.stage == pickMachine) && m.list.FilterState() != list.Filtering {
			if m.stage == pickRepo && !m.repoSelected {
				return m, nil
			}
			selected := m.list.SelectedItem()
			if selected == nil {
				return m, nil
			}
			if m.stage == pickRepo {
				name := selected.(item).Title()
				m.Request.Repo = name
				m.destinations = m.config.Destinations(name, m.profiles)
				if len(m.destinations) == 0 {
					m.message = "No enabled Herdr machines configured for this repository."
					return m, nil
				}
				names := make([]string, len(m.destinations))
				items := make([]list.Item, len(m.destinations))
				localIndex := 0
				for i, d := range m.destinations {
					names[i] = d.DisplayName()
					items[i] = machineItem{machine: d}
					if d.IsLocal() {
						localIndex = i
					}
				}
				m.stage, m.message = pickMachine, ""
				m.choices("Choose machine", names)
				m.list.SetItems(items)
				m.list.Select(localIndex)
			} else {
				m.Request.Machine = selected.(machineItem).machine
				m.Ready = true
				return m, tea.Quit
			}
			return m, nil
		}
	}
	var cmd tea.Cmd
	switch m.stage {
	case pickTask:
		cmd = m.selector.update(msg)
	case pickRepo:
		cmd = m.updateRepositoryList(msg)
	case pickMachine:
		m.list, cmd = m.list.Update(msg)
	}
	return m, cmd
}

func (m Model) View() string {
	if m.Ready {
		return ""
	}
	var body string
	switch m.stage {
	case askTask, askEmpty:
		question := "Start from a task file?"
		if m.stage == askEmpty {
			question = "Start an empty session instead? (No cancels)"
		}
		choices := m.styles.binaryChoices("Yes", "No", m.yes)
		body = m.styles.title.Render(question) + "\n\n" + choices + "\n\n" + m.styles.muted.Render("←/→ choose · enter confirm · y/n · esc cancel")
	case pickTask:
		body = m.styles.title.Render("Choose task file") + "\n" + m.selector.view(m.indexLoading, m.taskLoading) + "\n" + m.styles.muted.Render("type to find · ↑/↓ or ctrl+p/ctrl+n choose · enter select · esc empty-session/cancel")
	case pickRepo, pickMachine:
		body = m.list.View() + "\n" + m.styles.muted.Render("esc back")
		if m.stage == pickRepo {
			body += "\n" + m.styles.muted.Render("Navigate to select a repository before pressing Enter.")
		}
	}
	if m.message != "" {
		body += "\n\n" + m.styles.error.Render(displayText(m.message))
	}
	return fmt.Sprintf("\n%s\n\n%s\n\n%s\n", m.styles.title.Render("herdsman start"), strings.TrimRight(body, "\n"), m.styles.muted.Render("ctrl+c cancels"))
}
