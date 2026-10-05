package tui

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/list"
	"github.com/charmbracelet/x/ansi"
)

// The trail describes screens, not request values or daemon execution. Derive it
// from the current route so back-navigation cannot leave stale progress behind.
func (m Model) breadcrumb() string {
	first := "Task"
	if m.stage == askDescription || (m.stage >= pickRepo && m.Request.Task == nil) {
		first = "Description"
	}
	labels := []string{first, "Context", "Machine"}
	context := ""
	if m.stage == pickRepo && m.repoSelected && m.list.FilterState() != list.Filtering {
		if selected, ok := m.list.SelectedItem().(item); ok {
			context = selected.Title()
		}
	} else if m.stage > pickRepo {
		context = m.Request.Repo
	}
	if context == "" || strings.Contains(context, "/") {
		labels = append(labels, "Base ref")
	}
	labels = append(labels, "Model", "Thinking")
	current := 0
	switch m.stage {
	case pickRepo:
		current = 1
	case pickMachine:
		current = 2
	case editBase, pickModel, pickThinking:
		label := "Base ref"
		if m.stage == pickModel {
			label = "Model"
		} else if m.stage == pickThinking {
			label = "Thinking"
		}
		current = indexName(labels, label)
	}
	parts := []string{m.styles.text.Render("Start")}
	for i, label := range labels {
		style := m.styles.muted
		if i < current {
			style = m.styles.text
		} else if i == current {
			style = m.styles.title
			label = "[" + label + "]"
		}
		parts = append(parts, style.Render(label))
	}
	trail := strings.Join(parts, m.styles.muted.Render(" › "))
	if ansi.StringWidth(trail) <= m.width {
		return trail
	}
	compact := m.styles.text.Render(fmt.Sprintf("Start · %d/%d · ", current+1, len(labels))) +
		m.styles.title.Render("["+labels[current]+"]")
	if ansi.StringWidth(compact) <= m.width {
		return compact
	}
	// On extremely narrow terminals keep the current label ahead of the count.
	return ansi.Truncate(m.styles.title.Render("["+labels[current]+"]"), max(0, m.width), "…")
}
