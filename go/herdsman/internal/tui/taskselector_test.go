package tui

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestDiscoverTasksRecursesAndUsesRelativeFilenames(t *testing.T) {
	root := t.TempDir()
	for _, path := range []string{"root==todo--task.md", "epic/task==todo--task.md", "epic/sub-epic/nested==todo--task.md", "history==done--task.md", "history==discarded--task.md", "plain.md", "notes.txt", "epic==todo--directory/plain.md"} {
		full := filepath.Join(root, path)
		if err := os.MkdirAll(filepath.Dir(full), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte("not front matter; names only"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Mkdir(filepath.Join(root, "directory==todo--task.md"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Mkfifo(filepath.Join(root, "pipe==todo--task.md"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(root, filepath.Join(root, "loop")); err != nil {
		t.Fatal(err)
	}
	files, err := discoverTasks(root)
	if err != nil {
		t.Fatal(err)
	}
	var paths []string
	for _, f := range files {
		paths = append(paths, f.relative)
		if !filepath.IsAbs(f.path) {
			t.Fatal(f.path)
		}
	}
	want := []string{"epic/sub-epic/nested==todo--task.md", "epic/task==todo--task.md", "root==todo--task.md"}
	if !reflect.DeepEqual(paths, want) {
		t.Fatal(paths, want)
	}
}

func TestTaskSelectorFuzzyRankingAndTypingKeys(t *testing.T) {
	s := newTaskSelector(100, 30)
	s.setFiles([]taskFile{{path: "/notes/other.md", relative: "other.md"}, {path: "/notes/network/network-share.md", relative: "network/network-share.md"}})
	s.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("NETSHARE")})
	if len(s.list.Items()) != 1 || s.selectedPath() != "/notes/network/network-share.md" {
		t.Fatal(s.list.Items(), s.selectedPath())
	}
	if len(s.list.Items()[0].(taskFile).matches) == 0 {
		t.Fatal("no highlighting positions")
	}
	s.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("q")})
	if s.query.Value() != "NETSHAREq" || s.selectedPath() != "" {
		t.Fatal(s.query.Value(), s.selectedPath())
	}
}

func TestTaskSelectorArrowsDoNotChangeQuery(t *testing.T) {
	s := newTaskSelector(100, 30)
	s.setFiles([]taskFile{{path: "/a.md", relative: "a.md"}, {path: "/b.md", relative: "b.md"}})
	s.update(tea.KeyMsg{Type: tea.KeyDown})
	if s.selectedPath() != "/b.md" || s.query.Value() != "" {
		t.Fatal(s.selectedPath(), s.query.Value())
	}
}

func TestTaskSelectorRendersSnapshotWithoutFilesystem(t *testing.T) {
	s := newTaskSelector(100, 30)
	s.setFiles([]taskFile{{path: "/nonexistent/task.md", relative: "epic/task.md"}})
	_ = s.view(false, false)
	_ = s.view(true, false)
	_ = s.view(false, true)
}

func TestTaskFilenameControlsCannotReachTerminal(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "task==todo--task\x1b]52;c;Y2xpcA==\a.md")
	if err := os.WriteFile(path, []byte("task"), 0600); err != nil {
		t.Fatal(err)
	}
	files, err := discoverTasks(root)
	if err != nil || len(files) != 1 || files[0].path != path {
		t.Fatal(files, err)
	}
	if strings.ContainsAny(files[0].relative, "\x1b\a") || !strings.Contains(files[0].relative, `\x1b`) {
		t.Fatal(files[0].relative)
	}
	s := newTaskSelector(100, 30)
	s.setFiles(files)
	if view := s.view(false, false); strings.Contains(view, "\x1b]52;") || strings.ContainsRune(view, '\a') {
		t.Fatal("terminal command in filename rendering")
	}
	m := New(config(t), nil)
	m.message = "cannot read " + path
	if view := m.View(); strings.Contains(view, "\x1b]52;") || strings.ContainsRune(view, '\a') {
		t.Fatal("terminal command in error rendering")
	}
}
