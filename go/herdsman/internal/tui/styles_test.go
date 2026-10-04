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
	selectionBackground := "#e5d7c5"
	if mode == "dark" {
		text = "#e7e7e7"
		selectionBackground = "#432f2a"
	}
	return themes.Colors{Text: text, Muted: "#4a4a4a", Accent: "#603d3a", SelectionBackground: selectionBackground, SelectionText: text, FilenameSecondary: "#404040", FilenameMuted: "#595959", Match: "#603d3a", Error: "#a01010"}
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
			m.choices("Choose repository", []string{"owner/repo"})
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
	m.choices("Choose repository", names)
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
	d := choiceDelegate{DefaultDelegate: list.NewDefaultDelegate()}
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

func TestUnicodeFilenameMatchesUseActualFilterOffsets(t *testing.T) {
	freshRenderer(t)
	styles := newStyles(testColors("light"))
	name := "épic/20261001T120931==todo--task.md"
	selector := newTaskSelector(80, 20)
	selector.applyStyles(styles)
	selector.query.SetValue("==todo")
	selector.setFiles([]taskFile{{relative: name, path: name}})
	file := selector.list.SelectedItem().(taskFile)
	if len(file.matches) != 6 || file.matches[0] != strings.Index(name, "==todo") {
		t.Fatal("test requires fuzzy byte offsets", file.matches)
	}
	var out bytes.Buffer
	taskDelegate{styles: styles.items(), filenameSecondary: styles.filenameSecondary, filenameMuted: styles.filenameMuted}.
		Render(&out, selector.list, 0, file)
	foreground := regexp.MustCompile(`38;2;[0-9]+;[0-9]+;[0-9]+`).FindString(styles.match.Render("t"))
	pattern := regexp.MustCompile("\x1b\\[4m\x1b\\[[0-9;]*" + foreground + "[0-9;]*m(.)")
	var highlighted strings.Builder
	for _, match := range pattern.FindAllStringSubmatch(out.String(), -1) {
		highlighted.WriteString(match[1])
	}
	if highlighted.String() != "==todo" {
		t.Fatalf("wrong filename match: %q in %q", highlighted.String(), out.String())
	}
}

func TestUnselectedRepositoryHasNoHighlightedRow(t *testing.T) {
	freshRenderer(t)
	m, _ := key(newModel(t, config(t), nil), "n")
	m = describeSession(m)
	d := m.choiceDelegate(true)
	var first, other bytes.Buffer
	d.Render(&first, m.list, 0, item("owner/repo"))
	d.Render(&other, m.list, 1, item("owner/repo"))
	if first.String() != other.String() {
		t.Fatal("unselected first row was highlighted")
	}
	d.unselected = false
	first.Reset()
	d.Render(&first, m.list, 0, item("owner/repo"))
	if first.String() == other.String() {
		t.Fatal("explicit selection has no visual highlight")
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

func TestThemedConfirmationButtons(t *testing.T) {
	freshRenderer(t)
	for _, mode := range []string{"light", "dark"} {
		c := config(t)
		c.Theme.Mode = mode
		m := themedModel(t, c)
		for _, stage := range []stage{askTask, askEmpty} {
			m.stage = stage
			for _, yes := range []bool{true, false} {
				m.yes = yes
				yesStyle, noStyle := m.styles.text, m.styles.selected
				if yes {
					yesStyle, noStyle = noStyle, yesStyle
				}
				left := yesStyle.Padding(0, 1).Width(7).Align(lipgloss.Center).Render("Yes")
				right := noStyle.Padding(0, 1).Width(7).Align(lipgloss.Center).Render("No")
				if ansi.StringWidth(left) != 7 || ansi.StringWidth(right) != 7 {
					t.Fatal("unequal button sizes")
				}
				view := m.View()
				if !strings.Contains(view, left+"  "+right) || strings.Contains(view, "[Yes]") || strings.Contains(view, "[No]") {
					t.Fatalf("wrong confirmation layout: %q", view)
				}
				if !strings.Contains(ansi.Strip(view), "←/→ choose · enter confirm · y/n · esc cancel") {
					t.Fatal("confirmation controls changed")
				}
			}
		}
	}
}

func TestNativeConfirmationRetainsBrackets(t *testing.T) {
	freshRenderer(t)
	m := newModel(t, config(t), nil)
	for _, stage := range []stage{askTask, askEmpty} {
		m.stage = stage
		for _, yes := range []bool{true, false} {
			m.yes = yes
			want := "  Yes    [No]"
			if yes {
				want = " [Yes]    No"
			}
			if !strings.Contains(ansi.Strip(m.View()), want) {
				t.Fatal("native confirmation layout changed")
			}
		}
	}
}

func TestColorlessThemedConfirmationRetainsBrackets(t *testing.T) {
	r := freshRenderer(t)
	r.SetColorProfile(termenv.Ascii)
	c := config(t)
	c.Theme.Mode = "light"
	m := themedModel(t, c)
	for _, stage := range []stage{askTask, askEmpty} {
		m.stage = stage
		m.yes = true
		yesView := m.View()
		m.yes = false
		noView := m.View()
		if yesView == noView || !strings.Contains(yesView, "[Yes]") || !strings.Contains(noView, "[No]") {
			t.Fatal("colourless confirmation selection is invisible")
		}
		if strings.Contains(yesView+noView, "\x1b[") {
			t.Fatal("colourless renderer emitted ANSI styling")
		}
	}
}

func TestDenoteFilenameStyles(t *testing.T) {
	s := newStyles(testColors("light"))
	for _, name := range []string{
		"epic/20261001T120931==todo--improve-theme__ui_theme.md",
		"épic/20261001T120931==todo--改善-thème.md",
		"20261001T120931--plain.md",
	} {
		parts := filenameStyles(name, s.filenameSecondary, s.filenameMuted)
		if len(parts) != len([]rune(name)) {
			t.Fatalf("missing styles for %q", name)
		}
		for _, test := range []struct {
			text  string
			color lipgloss.TerminalColor
			bold  bool
		}{
			{"20261001", s.filenameSecondary.GetForeground(), false},
			{"T", s.filenameMuted.GetForeground(), false},
			{"120931", s.filenameSecondary.GetForeground(), false},
			{"==", s.filenameMuted.GetForeground(), false},
			{"todo", s.filenameSecondary.GetForeground(), true},
			{"--", s.filenameMuted.GetForeground(), false},
			{"__", s.filenameMuted.GetForeground(), false},
			{"ui_theme", s.filenameSecondary.GetForeground(), true},
			{".md", s.filenameMuted.GetForeground(), false},
		} {
			index := strings.Index(name, test.text)
			if index < 0 {
				continue
			}
			index = len([]rune(name[:index]))
			for _, style := range parts[index : index+len([]rune(test.text))] {
				if style.GetForeground() != test.color || style.GetBold() != test.bold {
					t.Fatalf("%q: wrong style for %q", name, test.text)
				}
			}
		}
		if strings.Contains(name, "/") && !parts[0].GetBold() {
			t.Fatal("directory is not bold")
		}
		title := strings.Index(name, "--") + 2
		if style := parts[len([]rune(name[:title]))]; style.GetForeground() != (lipgloss.NoColor{}) || style.GetBold() {
			t.Fatal("title should inherit regular row text")
		}
	}
	for _, name := range []string{"task.md", "epic/not-a-denote==todo--task.md"} {
		if filenameStyles(name, s.filenameSecondary, s.filenameMuted) != nil {
			t.Fatal("fontified ordinary filename", name)
		}
	}
	native := newStyles(themes.Colors{})
	if filenameStyles("20261001T120931==todo--task.md", native.filenameSecondary, native.filenameMuted) != nil {
		t.Fatal("fontified terminal-native fallback")
	}
}

func TestFilenameRenderingSelectionAndMatches(t *testing.T) {
	freshRenderer(t)
	for _, mode := range []string{"light", "dark"} {
		s := newStyles(testColors(mode))
		name := "épic/20261001T120931==todo--改善-theme__ui.md"
		parts := filenameStyles(name, s.filenameSecondary, s.filenameMuted)
		matchIndex := strings.Index(name, "todo")
		foreground := regexp.MustCompile(`38;2;[0-9]+;[0-9]+;[0-9]+`).FindString(s.match.Render("t"))
		pattern := regexp.MustCompile("\x1b\\[[0-9;]*" + foreground + "[0-9;]*mt")
		for _, style := range []lipgloss.Style{s.items().NormalTitle, s.items().SelectedTitle} {
			var out bytes.Buffer
			renderFilenameTitle(&out, name, []int{matchIndex}, style, s.match, parts, 80)
			if !pattern.MatchString(out.String()) {
				t.Fatalf("match colour absent: %q", out.String())
			}
			if !strings.Contains(ansi.Strip(out.String()), name) {
				t.Fatal("filename altered", out.String())
			}
			if style.GetBackground() != (lipgloss.NoColor{}) && ansi.StringWidth(out.String()) != 80 {
				t.Fatalf("selection did not fill width: %d", ansi.StringWidth(out.String()))
			}
			for _, width := range []int{4, 20, 40} {
				out.Reset()
				renderFilenameTitle(&out, name, []int{matchIndex}, style, s.match, parts, width)
				if ansi.StringWidth(out.String()) > width || strings.Contains(out.String(), "\n") {
					t.Fatalf("bad truncation at width %d: %q", width, out.String())
				}
			}
		}
		if s.selected.GetBold() {
			t.Fatal("whole selected row is bold")
		}
		var out bytes.Buffer
		renderTitle(&out, "owner/repo", nil, s.items().SelectedTitle, s.match, 80)
		if ansi.StringWidth(out.String()) != 80 {
			t.Fatal("choice selection did not fill width")
		}
	}
}

func TestFilenameRenderingPreservesGraphemes(t *testing.T) {
	freshRenderer(t)
	s := newStyles(testColors("light"))
	for _, cluster := range []string{"👩‍💻", "e\u0301", "🇦🇺"} {
		name := "20261001T120931==todo--" + cluster + ".md"
		parts := filenameStyles(name, s.filenameSecondary, s.filenameMuted)
		index := len("20261001T120931==todo--") + len(string([]rune(cluster)[0]))
		for _, matches := range [][]int{nil, {index}} {
			for _, width := range []int{26, 30, 80} {
				var out bytes.Buffer
				renderFilenameTitle(&out, name, matches, s.items().SelectedTitle, s.match, parts, width)
				if strings.Contains(out.String(), "\n") || ansi.StringWidth(out.String()) != width {
					t.Fatalf("grapheme %q broke width %d: %q", cluster, width, out.String())
				}
				if strings.Contains(ansi.Strip(out.String()), cluster) && !strings.Contains(out.String(), cluster) {
					t.Fatalf("escapes split grapheme %q: %q", cluster, out.String())
				}
			}
		}
	}
}

func TestMissingPaletteUsesTerminalNativeStyling(t *testing.T) {
	freshRenderer(t)
	c := config(t)
	c.Theme.Mode = "light"
	c.Theme.Light = "not-installed"
	m := newModel(t, c, nil)
	m.choices("Choose repository", []string{"owner/one", "owner/two"})
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
			m.choices(title, []string{"owner/one", "owner/two", "owner/three"})
			m.list.Select(1)
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
		m.choices("Choose repository", []string{"owner/repo"})
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
			if strings.Contains(view, "\x1b]52;") || strings.ContainsRune(view, '\a') || !strings.Contains(ansi.Strip(view), "herdsman · start session") {
				t.Fatalf("unsafe or missing view: %q", view)
			}
		}
	}
}
