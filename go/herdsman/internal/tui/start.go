// Package tui collects a request; launch side effects happen only after it exits.
package tui

import (
	"fmt"
	"strings"
	"time"

	"github.com/brucenunk/home-config/go/herdsman/internal/app"
	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
	"github.com/brucenunk/home-config/go/herdsman/internal/tui/themes"
	listkey "github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/list"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

type stage int

const (
	askTask stage = iota
	pickTask
	askEmpty
	askDescription
	pickRepo
	pickMachine
	editBase
	pickModel
	pickThinking
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
	styles           styles
	config           app.Config
	profiles         []herdr.Machine
	stage            stage
	yes              bool
	selector         taskSelector
	description      textinput.Model
	base             textinput.Model
	baseExplicit     bool
	thinkingExplicit bool
	machineName      string
	hintTask         *app.Task
	choiceSelected   bool
	indexLoading     bool
	taskLoading      bool
	readID           int
	list             list.Model
	repoSelected     bool
	destinations     []herdr.Machine
	width, height    int
	message          string
	inventoryNotice  string
	inventoryWarning bool
	inventoryStatus  func(time.Time) (string, bool)
	Request          app.StartRequest
	Ready            bool
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
	styles := newStyles(colors)
	description := textinput.New()
	description.Prompt = "> "
	description.Width = 76
	styles.input(&description)
	base := textinput.New()
	base.Prompt, base.Width, base.CharLimit = "> ", 76, 4096
	styles.input(&base)
	return Model{config: c, profiles: profiles, styles: styles, description: description, base: base, yes: true, width: 80, height: 22}, nil
}

func (m Model) Init() tea.Cmd {
	if m.inventoryStatus != nil {
		return inventoryTick()
	}
	return nil
}

type inventoryTickMsg time.Time

func inventoryTick() tea.Cmd {
	return tea.Tick(time.Second, func(now time.Time) tea.Msg { return inventoryTickMsg(now) })
}

func (m *Model) SetInventoryNotice(status func(time.Time) (string, bool)) {
	m.inventoryStatus = status
	m.inventoryNotice, m.inventoryWarning = status(time.Now())
}
func (m *Model) updateInventoryNotice(msg tea.Msg) (tea.Cmd, bool) {
	if now, ok := msg.(inventoryTickMsg); ok && m.inventoryStatus != nil {
		m.inventoryNotice, m.inventoryWarning = m.inventoryStatus(time.Time(now))
		return inventoryTick(), true
	}
	return nil, false
}
func (m Model) noticeHeight() int {
	if m.inventoryNotice != "" {
		return 3
	}
	return 0
}
func (m Model) noticeView() string {
	if m.inventoryNotice == "" {
		return ""
	}
	text := ansi.Truncate(displayText(m.inventoryNotice), max(1, m.width), "…")
	if m.inventoryWarning {
		return "\n" + m.styles.error.Render(text) + "\n"
	}
	return "\n" + m.styles.muted.Render(text) + "\n"
}

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
	m.selector = newTaskSelector(m.width, max(1, m.height-m.noticeHeight()))
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
	m.list = list.New(items, m.choiceDelegate(false), m.width, max(1, m.height-8-m.noticeHeight()))
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
	m.seedHints()
	title := "Select context"
	if m.Request.Task != nil {
		title = "Choose repository"
	}
	m.choices(title, m.config.ContextNames(m.Request.Task == nil))
	m.setRepositorySelection(false)
	if m.Request.Repo != "" {
		i := indexName(m.config.ContextNames(m.Request.Task == nil), m.Request.Repo)
		if i >= 0 {
			m.list.Select(i)
			m.setRepositorySelection(true)
		} else {
			m.message = "Repository hint is unavailable: " + m.Request.Repo + ". Choose a repository to replace it."
		}
	}
}

func (m *Model) beginDescription() tea.Cmd {
	m.stage, m.message = askDescription, ""
	m.Request.Task = nil
	return m.description.Focus()
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
	if cmd, ok := m.updateInventoryNotice(msg); ok {
		return m, cmd
	}
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
		m.description.Width = max(1, size.Width-4)
		if m.stage == pickTask {
			m.selector.resize(size.Width, max(1, size.Height-m.noticeHeight()))
		}
		m.base.Width = max(1, size.Width-4)
		if m.stage == pickRepo || m.stage == pickMachine || m.stage == pickModel || m.stage == pickThinking {
			m.list.SetSize(size.Width, max(1, size.Height-8-m.noticeHeight()))
		}
	}
	if key, ok := msg.(tea.KeyMsg); ok {
		if key.String() == "ctrl+c" {
			return m, tea.Quit
		}
		if m.stage == editBase {
			switch key.String() {
			case "esc":
				m.base.Blur()
				m.machines()
				return m, nil
			case "ctrl+r":
				m.baseExplicit = false
				m.Request.BaseRef = m.defaultBase()
				m.base.SetValue(m.Request.BaseRef)
				m.message = ""
				return m, nil
			case "enter":
				if !app.ValidBaseRef(m.base.Value()) {
					m.message = "Use remote/ref or a plain local branch name; revision expressions and refs/ forms are not supported."
					return m, nil
				}
				m.Request.BaseRef = m.base.Value()
				m.base.Blur()
				m.models()
				return m, nil
			}
		}
		if m.stage == askDescription {
			switch key.String() {
			case "esc":
				m.description.Blur()
				m.stage, m.yes, m.message = askTask, true, ""
				return m, nil
			case "enter":
				description := strings.TrimSpace(m.description.Value())
				if err := app.ValidateSessionDescription(description); err != nil {
					m.message = err.Error()
					return m, nil
				}
				m.Request.Description = description
				m.description.Blur()
				m.repositories()
				return m, nil
			default:
				m.message = ""
			}
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
					cmd := m.beginDescription()
					return m, cmd
				} else if m.yes {
					m.stage, m.message = pickTask, ""
					cmd := m.beginTasks()
					return m, cmd
				} else {
					cmd := m.beginDescription()
					return m, cmd
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
				if m.Request.Task == nil {
					cmd := m.beginDescription()
					return m, cmd
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
			case pickModel:
				if m.list.FilterState() != list.Unfiltered {
					break
				}
				if strings.Contains(m.Request.Repo, "/") {
					return m, m.beginBase()
				}
				m.machines()
				return m, nil
			case pickThinking:
				if m.list.FilterState() != list.Unfiltered {
					break
				}
				m.models()
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
		if key.String() == "enter" && (m.stage == pickRepo || m.stage == pickMachine || m.stage == pickModel || m.stage == pickThinking) && m.list.FilterState() != list.Filtering {
			if m.stage == pickRepo && !m.repoSelected {
				return m, nil
			}
			if m.stage != pickRepo && !m.choiceSelected {
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
					m.message = "No enabled Herdr machines configured for this context."
					return m, nil
				}
				m.machines()
			} else if m.stage == pickMachine {
				m.Request.Machine = selected.(machineItem).machine
				m.machineName = m.config.MachineName(m.Request.Machine)
				if strings.Contains(m.Request.Repo, "/") {
					return m, m.beginBase()
				}
				m.Request.BaseRef = ""
				m.models()
			} else if m.stage == pickModel {
				m.Request.Model = selected.(item).Title()
				m.thinking()
			} else {
				m.Request.Thinking = selected.(item).Title()
				m.thinkingExplicit = true
				if err := m.config.ValidateChoices(m.Request); err != nil {
					m.message = err.Error()
					return m, nil
				}
				m.Ready = true
				return m, tea.Quit
			}
			return m, nil
		}
	}
	var cmd tea.Cmd
	switch m.stage {
	case askDescription:
		m.description, cmd = m.description.Update(msg)
	case editBase:
		before := m.base.Value()
		m.base, cmd = m.base.Update(msg)
		if m.base.Value() != before {
			m.baseExplicit = true
			m.Request.BaseRef = m.base.Value()
			m.message = ""
		}
	case pickTask:
		cmd = m.selector.update(msg)
	case pickRepo:
		cmd = m.updateRepositoryList(msg)
	case pickMachine, pickModel, pickThinking:
		cmd = m.updateChoiceList(msg)
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
			question = "Start without a task file instead? (No cancels)"
		}
		choices := m.styles.binaryChoices("Yes", "No", m.yes)
		body = m.styles.title.Render(question) + "\n\n" + choices + "\n\n" + m.styles.muted.Render("←/→ choose · enter confirm · y/n · esc cancel")
	case askDescription:
		body = m.styles.title.Render("Session description") + "\n\n" + m.description.View() + "\n\n" + m.styles.muted.Render("enter continue · esc back")
	case pickTask:
		body = m.styles.title.Render("Choose task file") + "\n" + m.selector.view(m.indexLoading, m.taskLoading) + "\n" + m.styles.muted.Render("type to find · ↑/↓ or ctrl+p/ctrl+n choose · enter select · esc empty-session/cancel")
	case editBase:
		kind := "Repository default (ctrl+r resets)"
		if m.baseExplicit {
			kind = "Explicit override (ctrl+r resets to repository default)"
		}
		route := "Remote-tracking ref: uses the existing ref without fetching."
		if !strings.Contains(m.base.Value(), "/") {
			route = "Local branch: uses the existing branch without fetching."
		}
		body = m.styles.title.Render("Base ref") + "\n\n" + m.base.View() + "\n\n" + m.styles.muted.Render(kind+"\n"+route+"\nenter continue · esc back")
	case pickRepo, pickMachine, pickModel, pickThinking:
		body = m.list.View() + "\n" + m.styles.muted.Render("esc back")
		if m.stage == pickRepo {
			body += "\n" + m.styles.muted.Render("Navigate to select a context before pressing Enter.")
		}
	}
	if m.message != "" {
		body += "\n\n" + m.styles.error.Render(displayText(m.message))
	}
	return fmt.Sprintf("\n%s\n\n%s\n%s\n%s\n", m.styles.title.Render("herdsman · start session"), strings.TrimRight(body, "\n"), m.noticeView(), m.styles.muted.Render("ctrl+c cancels"))
}
