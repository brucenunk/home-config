package tui

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/brucenunk/home-config/go/herdsman/internal/app"
	"github.com/brucenunk/home-config/go/herdsman/internal/tui/themes"
	"github.com/charmbracelet/bubbles/list"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"
	"github.com/pelletier/go-toml/v2"
)

func freshRenderer(t *testing.T) *lipgloss.Renderer {
	t.Helper()
	old := lipgloss.DefaultRenderer()
	r := lipgloss.NewRenderer(&bytes.Buffer{})
	r.SetColorProfile(termenv.TrueColor)
	lipgloss.SetDefaultRenderer(r)
	t.Cleanup(func() { lipgloss.SetDefaultRenderer(old) })
	return r
}

func testColors(mode string) themes.Colors {
	text := "#202020"
	if mode == "dark" {
		text = "#e7e7e7"
	}
	return themes.Colors{Text: text, Muted: "#4a4a4a", Accent: "#603d3a", SelectionBackground: "#b0b0b0", SelectionText: text, Match: "#603d3a", Error: "#a01010"}
}

func themedModel(t *testing.T, c app.Config) Model {
	t.Helper()
	dir := t.TempDir()
	for mode, name := range map[string]string{"light": "doric-marble", "dark": "doric-obsidian"} {
		data, err := toml.Marshal(struct {
			Colors themes.Colors `toml:"colors"`
		}{testColors(mode)})
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, name+".toml"), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	m, err := New(c, nil, dir)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func TestForcedModesInitializeBackground(t *testing.T) {
	for _, mode := range []string{"light", "dark"} {
		t.Run(mode, func(t *testing.T) {
			r := freshRenderer(t)
			c := config(t)
			c.Theme.Mode = mode
			m := newModel(t, c, nil)
			if r.HasDarkBackground() != (mode == "dark") {
				t.Fatal("forced mode did not initialize Lip Gloss background state")
			}
			m.choices("Choose repository", []string{"owner/repo"}, "")
			_ = m.beginTasks()
		})
	}
}

func TestRenderedPaginationAndMatches(t *testing.T) {
	freshRenderer(t)
	c := config(t)
	c.Theme.Mode = "light"
	m := themedModel(t, c)
	names := make([]string, 30)
	for i := range names {
		names[i] = fmt.Sprintf("owner/repo-%02d", i)
	}
	m.choices("Choose repository", names, "")
	if m.list.Paginator.TotalPages < 2 {
		t.Fatal("test requires pagination")
	}
	view := m.list.View()
	for _, dot := range []string{m.styles.title.Render("•"), m.styles.muted.Render("•")} {
		if !strings.Contains(view, dot) {
			t.Fatalf("pagination missing themed dot %q in %q", dot, view)
		}
	}
	_ = m.beginTasks()
	files := make([]taskFile, len(names))
	for i, name := range names {
		files[i] = taskFile{relative: name, path: name}
	}
	m.selector.setFiles(files)
	view = m.selector.view(false, false)
	for _, dot := range []string{m.styles.title.Render("•"), m.styles.muted.Render("•")} {
		if !strings.Contains(view, dot) {
			t.Fatalf("task pagination missing themed dot %q in %q", dot, view)
		}
	}
	// Use the renderer's RGB conversion (which can round a hex component).
	foreground := regexp.MustCompile(`38;2;[0-9]+;[0-9]+;[0-9]+`).FindString(m.styles.match.Render("o"))
	if foreground == "" {
		t.Fatal("test requires truecolor rendering")
	}
	// Require the match foreground immediately before the matched 'o', not
	// merely on a selected border or elsewhere in the view.
	pattern := regexp.MustCompile("\x1b\\[[0-9;]*" + foreground + "[0-9;]*mo")
	m.list.SetFilterText("o")
	d := choiceDelegate{list.NewDefaultDelegate()}
	d.Styles = m.styles.items()
	for _, index := range []int{0, 1} {
		var out bytes.Buffer
		d.Render(&out, m.list, index, item(names[index]))
		if !pattern.MatchString(out.String()) {
			t.Fatalf("choice match color absent: %q", out.String())
		}
		out.Reset()
		taskDelegate{styles: m.styles.items()}.Render(&out, m.selector.list, index, taskFile{relative: names[index], matches: []int{0}})
		if !pattern.MatchString(out.String()) {
			t.Fatalf("task match color absent: %q", out.String())
		}
	}
}

func TestOnlySelectedPaletteIsLoaded(t *testing.T) {
	freshRenderer(t)
	c := config(t)
	c.Theme = themes.Config{Mode: "light", Light: "not-installed", Dark: "broken"}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "broken.toml"), []byte("not toml"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := New(c, nil, dir); err != nil {
		t.Fatal("unused palette should not be loaded", err)
	}
	c.Theme.Mode = "dark"
	if _, err := New(c, nil, dir); err == nil {
		t.Fatal("selected malformed palette should fail startup")
	}
}

func TestMissingPaletteUsesTerminalNativeStyling(t *testing.T) {
	freshRenderer(t)
	c := config(t)
	c.Theme.Mode = "light"
	c.Theme.Light = "not-installed"
	m := newModel(t, c, nil)
	m.choices("Choose repository", []string{"owner/one", "owner/two"}, "")
	_ = m.beginTasks()
	m.selector.setFiles([]taskFile{{relative: "task.md", path: "task.md"}})
	for _, stage := range []stage{askTask, pickTask, pickRepo, pickMachine} {
		m.stage = stage
		view := m.View()
		if strings.Contains(view, "38;2;") || strings.Contains(view, "48;2;") {
			t.Fatalf("palette colors leaked into neutral view: %q", view)
		}
	}
	if !m.styles.title.GetBold() || !m.styles.match.GetUnderline() || !m.styles.selected.GetReverse() {
		t.Fatal("neutral selection emphasis is missing")
	}
}

func TestChoiceRowsAreConsecutive(t *testing.T) {
	for _, mode := range []string{"light", "dark"} {
		c := config(t)
		c.Theme.Mode = mode
		m := newModel(t, c, nil)
		for _, title := range []string{"Choose repository", "Choose machine"} {
			m.choices(title, []string{"owner/one", "owner/two", "owner/three"}, "owner/two")
			if m.list.Index() != 1 {
				t.Fatal("preselection changed")
			}
			view := ansi.Strip(m.list.View())
			lines := strings.Split(view, "\n")
			for i, line := range lines {
				if strings.Contains(line, "owner/one") {
					if i+2 >= len(lines) || !strings.Contains(lines[i+1], "owner/two") || !strings.Contains(lines[i+2], "owner/three") {
						t.Fatalf("rows have gaps: %q", view)
					}
				}
			}
			if !strings.Contains(view, "owner/one") {
				t.Fatal(view)
			}
		}
	}
}

func TestDoricStylesReachEveryPicker(t *testing.T) {
	for _, mode := range []string{"light", "dark"} {
		c := config(t)
		c.Theme.Mode = mode
		m := themedModel(t, c)
		colors := testColors(mode)
		if m.styles.text.GetForeground() != lipgloss.Color(colors.Text) || m.styles.selected.GetBackground() != lipgloss.Color(colors.SelectionBackground) {
			t.Fatal("wrong palette")
		}
		m.choices("Choose repository", []string{"owner/repo"}, "")
		if m.list.FilterInput.PromptStyle.GetForeground() != lipgloss.Color(colors.Accent) || m.list.Help.Styles.ShortDesc.GetForeground() != lipgloss.Color(colors.Muted) {
			t.Fatal("list defaults leaked")
		}
		_ = m.beginTasks() // Do not run discovery; inspect the initialized selector.
		if m.selector.query.TextStyle.GetForeground() != lipgloss.Color(colors.Text) || m.selector.list.Styles.StatusBar.GetForeground() != lipgloss.Color(colors.Muted) {
			t.Fatal("task defaults leaked")
		}
		for _, stage := range []stage{askTask, askEmpty, pickTask, pickRepo, pickMachine} {
			m.stage = stage
			m.message = "bad\x1b]52;clipboard\a"
			view := m.View()
			if strings.Contains(view, "\x1b]52;") || strings.ContainsRune(view, '\a') || !strings.Contains(ansi.Strip(view), "herdsman start") {
				t.Fatalf("unsafe or missing view: %q", view)
			}
		}
	}
}
