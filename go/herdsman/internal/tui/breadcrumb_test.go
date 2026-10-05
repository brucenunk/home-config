package tui

import (
	"strings"
	"testing"

	"github.com/brucenunk/home-config/go/herdsman/internal/app"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"
)

func TestBreadcrumbStages(t *testing.T) {
	for _, tc := range []struct {
		stage stage
		want  string
	}{
		{askTask, "Start › [Task] › Context › Machine › Base ref › Model › Thinking"},
		{pickTask, "Start › [Task] › Context › Machine › Base ref › Model › Thinking"},
		{askEmpty, "Start › [Task] › Context › Machine › Base ref › Model › Thinking"},
		{askDescription, "Start › [Description] › Context › Machine › Base ref › Model › Thinking"},
		{pickRepo, "Start › Task › [Context] › Machine › Base ref › Model › Thinking"},
		{pickMachine, "Start › Task › Context › [Machine] › Base ref › Model › Thinking"},
		{editBase, "Start › Task › Context › Machine › [Base ref] › Model › Thinking"},
		{pickModel, "Start › Task › Context › Machine › Base ref › [Model] › Thinking"},
		{pickThinking, "Start › Task › Context › Machine › Base ref › Model › [Thinking]"},
	} {
		m := newModel(t, config(t), nil)
		m.stage, m.Request.Task, m.Request.Repo = tc.stage, &app.Task{}, "owner/one"
		if got := ansi.Strip(m.breadcrumb()); got != tc.want {
			t.Errorf("stage %d: got %q, want %q", tc.stage, got, tc.want)
		}
		if first := strings.SplitN(ansi.Strip(m.View()), "\n", 2)[0]; first != tc.want {
			t.Errorf("stage %d: trail is not the first row: %q", tc.stage, first)
		}
	}
}

func TestBreadcrumbRouteAndBackNavigation(t *testing.T) {
	m := newModel(t, config(t), nil)
	m, _ = key(m, "n")
	m = describeSession(m)
	m, _ = key(m, "down") // Select owner.
	if got := ansi.Strip(m.breadcrumb()); got != "Start › Description › [Context] › Machine › Model › Thinking" {
		t.Fatal(got)
	}
	m, _ = key(m, "down") // Select repository instead.
	if !strings.Contains(m.breadcrumb(), "Base ref") {
		t.Fatal("repository route omits base ref")
	}
	m, _ = key(m, "enter")
	m, _ = key(m, "enter")
	if m.stage != editBase || !strings.Contains(ansi.Strip(m.breadcrumb()), "[Base ref]") {
		t.Fatal(m.stage, m.breadcrumb())
	}
	m, _ = key(m, "esc")
	m, _ = key(m, "esc")
	m, _ = key(m, "up") // Change back to owner.
	m, _ = key(m, "enter")
	m, _ = key(m, "enter")
	if m.stage != pickModel || ansi.Strip(m.breadcrumb()) != "Start › Description › Context › Machine › [Model] › Thinking" {
		t.Fatal(m.stage, m.breadcrumb())
	}
	m, _ = key(m, "enter")
	if ansi.Strip(m.breadcrumb()) != "Start › Description › Context › Machine › Model › [Thinking]" {
		t.Fatal(m.breadcrumb())
	}
	m, _ = key(m, "esc")
	m, _ = key(m, "esc")
	m, _ = key(m, "esc")
	m, _ = key(m, "esc")
	if m.stage != askDescription || !strings.Contains(m.breadcrumb(), "Base ref") {
		t.Fatal("previous owner selection leaked into undecided route", m.stage, m.breadcrumb())
	}
	m, _ = key(m, "esc")
	if !strings.Contains(ansi.Strip(m.breadcrumb()), "[Task]") {
		t.Fatal("previous description route leaked into task question")
	}
}

func TestBreadcrumbWidthsAndStyles(t *testing.T) {
	for _, profile := range []termenv.Profile{termenv.TrueColor, termenv.Ascii} {
		r := freshRenderer(t)
		r.SetColorProfile(profile)
		for _, palette := range []string{"", "light", "dark"} {
			m := newModel(t, config(t), nil)
			if palette != "" {
				m.styles = newStyles(testColors(palette))
			}
			m.stage, m.Request.Repo, m.Request.Task = editBase, "owner/one", &app.Task{}
			for _, width := range []int{0, 1, 5, 20, 32, 64, 80, 120} {
				next, _ := m.Update(tea.WindowSizeMsg{Width: width, Height: 22})
				m = next.(Model)
				trail := m.breadcrumb()
				if strings.Contains(trail, "\n") || ansi.StringWidth(trail) > width {
					t.Fatalf("profile %v palette %q width %d: %q", profile, palette, width, trail)
				}
				plain := ansi.Strip(trail)
				if width == 32 && plain != "Start · 4/6 · [Base ref]" {
					t.Fatal("wrong compact trail", plain)
				}
				if width == 20 && plain != "[Base ref]" {
					t.Fatal("current step not prioritised", plain)
				}
				if profile == termenv.Ascii && trail != plain {
					t.Fatal("colourless trail contains escape sequences", trail)
				}
				if width == 120 {
					want := m.styles.text.Render("Start") + m.styles.muted.Render(" › ") +
						m.styles.text.Render("Task") + m.styles.muted.Render(" › ") +
						m.styles.text.Render("Context") + m.styles.muted.Render(" › ") +
						m.styles.text.Render("Machine") + m.styles.muted.Render(" › ") +
						m.styles.title.Render("[Base ref]") + m.styles.muted.Render(" › ") +
						m.styles.muted.Render("Model") + m.styles.muted.Render(" › ") + m.styles.muted.Render("Thinking")
					if trail != want {
						t.Fatal("completed/current/future styling differs", trail)
					}
				}
			}
		}
	}
}

func TestReadyStartHasNoBreadcrumb(t *testing.T) {
	m := newModel(t, config(t), nil)
	m.Ready = true
	if m.View() != "" {
		t.Fatal("ready picker still renders")
	}
}
