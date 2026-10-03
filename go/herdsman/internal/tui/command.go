package tui

import (
	"fmt"

	"github.com/brucenunk/home-config/go/herdsman/internal/app"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"
)

// CommandModel selects a workflow without performing any Herdr operations.
type CommandModel struct {
	styles  styles
	start   bool
	Command string
}

func NewCommand(c app.Config, themeDir string) (CommandModel, error) {
	m, err := New(c, nil, themeDir)
	if err != nil {
		return CommandModel{}, err
	}
	return CommandModel{styles: m.styles, start: true}, nil
}

func (m CommandModel) Init() tea.Cmd { return nil }

func (m CommandModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if key, ok := msg.(tea.KeyMsg); ok {
		switch key.String() {
		case "esc", "q", "ctrl+c":
			return m, tea.Quit
		case "left", "right", "up", "down", "tab", "h", "l":
			m.start = !m.start
		case "enter", "s", "f":
			if key.String() == "s" {
				m.start = true
			} else if key.String() == "f" {
				m.start = false
			}
			m.Command = "finish"
			if m.start {
				m.Command = "start"
			}
			return m, tea.Quit
		}
	}
	return m, nil
}

func (m CommandModel) View() string {
	if m.Command != "" {
		return ""
	}
	return fmt.Sprintf("\n%s\n\n%s\n\n%s\n\n%s\n\n%s\n",
		m.styles.title.Render("herdsman"),
		m.styles.title.Render("Start or finish a task?"),
		m.styles.binaryChoices("Start", "Finish", m.start),
		m.styles.muted.Render("←/→ choose · enter confirm · s/f · esc cancel"),
		m.styles.muted.Render("ctrl+c cancels"))
}

// binaryChoices is shared with the initial task-file prompt, including its
// bracketed fallback when the terminal cannot render a selection background.
func (s styles) binaryChoices(first, second string, selectFirst bool) string {
	if s.selected.GetBackground() != (lipgloss.NoColor{}) && lipgloss.ColorProfile() != termenv.Ascii {
		firstStyle, secondStyle := s.text, s.selected
		if selectFirst {
			firstStyle, secondStyle = secondStyle, firstStyle
		}
		width := max(lipgloss.Width(first), lipgloss.Width(second)) + 4
		return firstStyle.Padding(0, 1).Width(width).Align(lipgloss.Center).Render(first) + "  " +
			secondStyle.Padding(0, 1).Width(width).Align(lipgloss.Center).Render(second)
	}
	if selectFirst {
		return " " + s.selected.Render("["+first+"]") + s.text.Render("    "+second)
	}
	return s.text.Render("  "+first+"    ") + s.selected.Render("["+second+"]")
}
