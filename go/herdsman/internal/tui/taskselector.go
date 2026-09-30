package tui

import (
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"unicode"

	"github.com/charmbracelet/bubbles/list"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

type taskFile struct {
	path     string
	relative string
	matches  []int
}

func (f taskFile) FilterValue() string { return f.relative }

// Paths stay untouched for reads; control characters are visible text in the UI.
func displayText(text string) string {
	var result strings.Builder
	for _, r := range text {
		if unicode.IsControl(r) {
			quoted := strconv.QuoteRune(r)
			result.WriteString(quoted[1 : len(quoted)-1])
		} else {
			result.WriteRune(r)
		}
	}
	return result.String()
}

// Index names only. Rendering and fuzzy matching never touch the filesystem.
func discoverTasks(root string) ([]taskFile, error) {
	root, err := filepath.EvalSymlinks(root)
	if err != nil {
		return nil, fmt.Errorf("cannot read task directory: %w", err)
	}
	info, err := os.Stat(root)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("task directory is not a directory: %s", root)
	}
	var files []taskFile
	err = filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			if path != root && os.IsNotExist(err) {
				return nil
			}
			return err
		}
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".md" || !strings.Contains(entry.Name(), "==todo--") {
			return nil
		}
		info, err := entry.Info()
		if os.IsNotExist(err) {
			return nil
		}
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return nil
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		files = append(files, taskFile{path: path, relative: displayText(filepath.ToSlash(relative))})
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("cannot read task directory %s: %w", root, err)
	}
	slices.SortFunc(files, func(a, b taskFile) int { return strings.Compare(a.relative, b.relative) })
	return files, nil
}

type taskSelector struct {
	query textinput.Model
	list  list.Model
	files []taskFile
}

func newTaskSelector(width, height int) taskSelector {
	query := textinput.New()
	query.Prompt = "Find: "
	query.Placeholder = "Type to fuzzy-find filenames"
	query.Focus()
	l := list.New(nil, taskDelegate{styles: list.NewDefaultItemStyles()}, width, max(3, height-10))
	l.SetFilteringEnabled(false)
	l.SetShowTitle(false)
	l.SetShowHelp(false)
	l.DisableQuitKeybindings()
	s := taskSelector{query: query, list: l}
	s.resize(width, height)
	return s
}

func (s *taskSelector) resize(width, height int) {
	s.query.Width = max(1, width-6)
	s.list.SetSize(width, max(3, height-10))
}

func (s *taskSelector) setFiles(files []taskFile) {
	s.files = files
	s.filter()
}

func (s *taskSelector) filter() {
	var items []list.Item
	if s.query.Value() == "" {
		for _, f := range s.files {
			items = append(items, f)
		}
	} else {
		paths := make([]string, len(s.files))
		for i, f := range s.files {
			paths[i] = f.relative
		}
		for _, rank := range list.DefaultFilter(s.query.Value(), paths) {
			f := s.files[rank.Index]
			f.matches = rank.MatchedIndexes
			items = append(items, f)
		}
	}
	s.list.SetItems(items)
	s.list.Select(0)
}

func (s *taskSelector) update(msg tea.Msg) tea.Cmd {
	if key, ok := msg.(tea.KeyMsg); ok {
		switch key.String() {
		case "up", "down", "pgup", "pgdown":
			var cmd tea.Cmd
			s.list, cmd = s.list.Update(msg)
			return cmd
		}
	}
	before := s.query.Value()
	var cmd tea.Cmd
	s.query, cmd = s.query.Update(msg)
	if s.query.Value() != before {
		s.filter()
	}
	return cmd
}

func (s taskSelector) selectedPath() string {
	if selected, ok := s.list.SelectedItem().(taskFile); ok {
		return selected.path
	}
	return ""
}

func (s taskSelector) view(loadingIndex, loadingTask bool) string {
	body := s.list.View()
	if loadingIndex {
		body = "Reading task filenames…"
	}
	if loadingTask {
		body = "Reading task file…"
	}
	return s.query.View() + "\n\n" + body
}

type taskDelegate struct{ styles list.DefaultItemStyles }

func (taskDelegate) Height() int                         { return 1 }
func (taskDelegate) Spacing() int                        { return 0 }
func (taskDelegate) Update(tea.Msg, *list.Model) tea.Cmd { return nil }
func (d taskDelegate) Render(w io.Writer, m list.Model, index int, item list.Item) {
	f := item.(taskFile)
	style := d.styles.NormalTitle
	if index == m.Index() {
		style = d.styles.SelectedTitle
	}
	title := ansi.Truncate(f.relative, max(1, m.Width()-2), "…")
	title = lipgloss.StyleRunes(title, f.matches, style.Inline(true).Inherit(d.styles.FilterMatch), style.Inline(true))
	fmt.Fprint(w, style.Render(title))
}
