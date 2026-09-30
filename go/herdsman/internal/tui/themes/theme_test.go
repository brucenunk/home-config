package themes

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const palette = `[colors]
text = "#202020"
muted = "#4a4a4a"
accent = "#603d3a"
selection_background = "#b0b0b0"
selection_text = "#202020"
match = "#603d3a"
error = "#a01010"
`

func TestLoadExternalPalette(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "custom.toml")
	if err := os.WriteFile(path, []byte(palette), 0600); err != nil {
		t.Fatal(err)
	}
	c, err := Load(dir, "custom")
	if err != nil || c.Text != "#202020" || c.Match != "#603d3a" {
		t.Fatal(c, err)
	}
	// No embedded fallback: missing names and missing directories are neutral.
	for _, root := range []string{dir, filepath.Join(dir, "absent")} {
		c, err := Load(root, "doric-obsidian")
		if err != nil || c != (Colors{}) {
			t.Fatal(c, err)
		}
	}
	// Files are read at startup, not cached across invocations.
	if err := os.WriteFile(path, []byte(strings.ReplaceAll(palette, "#202020", "#e7e7e7")), 0600); err != nil {
		t.Fatal(err)
	}
	c, err = Load(dir, "custom")
	if err != nil || c.Text != "#e7e7e7" {
		t.Fatal(c, err)
	}
}

func TestMalformedOrUnreadablePalette(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "custom.toml")
	for _, text := range []string{
		"not toml", "", "[colors]\ntext = '#202020'\n",
		strings.ReplaceAll(palette, "#202020", "bad color"),
		"background_mode = 'light'\n" + palette,
		palette + "unknown = '#202020'\n",
	} {
		if err := os.WriteFile(path, []byte(text), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := Load(dir, "custom"); err == nil {
			t.Fatalf("accepted malformed palette %q", text)
		}
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(path, 0700); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(dir, "custom"); err == nil {
		t.Fatal("ignored unreadable palette path")
	}
	if err := os.Symlink(filepath.Join(dir, "missing-target"), filepath.Join(dir, "broken.toml")); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(dir, "broken"); err == nil {
		t.Fatal("ignored a present but dangling palette symlink")
	}
}

func TestConfigSelection(t *testing.T) {
	for _, test := range []struct {
		mode  string
		dark  bool
		want  string
		calls int
	}{
		{"auto", true, "doric-obsidian", 1},
		{"auto", false, "doric-marble", 1},
		{"light", true, "doric-marble", 0},
		{"dark", false, "doric-obsidian", 0},
		{"", true, "doric-obsidian", 1},
	} {
		calls := 0
		name := (Config{Mode: test.mode}).Name(func() bool { calls++; return test.dark })
		if name != test.want || calls != test.calls {
			t.Fatalf("%+v: name=%s calls=%d", test, name, calls)
		}
	}
	c := Config{Mode: "auto", Light: "custom-dark", Dark: "custom-light"}
	if err := c.Validate(); err != nil {
		t.Fatal(err)
	}
	if c.Name(func() bool { return true }) != "custom-light" || c.Name(func() bool { return false }) != "custom-dark" {
		t.Fatal("ignored configured theme names")
	}
}

func TestConfigRejectsInvalidNames(t *testing.T) {
	for _, c := range []Config{
		{Mode: "system"}, {Light: "../doric-marble"}, {Dark: "doric-obsidian.toml"},
		{Light: "/absolute"}, {Dark: "bad\x1bname"},
	} {
		if err := c.Validate(); err == nil {
			t.Fatalf("accepted %+v", c)
		}
	}
	if err := (Config{Light: "not-installed", Dark: "custom"}).Validate(); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(t.TempDir(), "../escape"); err == nil {
		t.Fatal("accepted unsafe path")
	}
}
