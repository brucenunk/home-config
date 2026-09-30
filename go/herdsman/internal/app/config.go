package app

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"

	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
	"github.com/brucenunk/home-config/go/herdsman/internal/tui/themes"
	"github.com/pelletier/go-toml/v2"
)

type Config struct {
	Theme        themes.Config               `toml:"theme"`
	AgentNames   []string                    `toml:"agent_names"`
	TasksDir     string                      `toml:"tasks_dir"`
	DefaultBase  string                      `toml:"default_base"`
	Machines     map[string]MachineConfig    `toml:"machines"`
	Repositories map[string]RepositoryConfig `toml:"repositories"`
}

type MachineConfig struct {
	Repositories []string `toml:"repositories"`
}
type RepositoryConfig struct {
	Base string `toml:"base"`
}

var component = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.-]*$`)
var repoComponent = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)
var agentName = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,31}$`)

func validateAgentNames(names []string) error {
	if len(names) == 0 {
		return fmt.Errorf("agent_names must contain at least one name")
	}
	seen := map[string]bool{}
	for _, name := range names {
		if !agentName.MatchString(name) {
			return fmt.Errorf("invalid agent name %q: expected [a-z][a-z0-9_-]{0,31}", name)
		}
		if seen[name] {
			return fmt.Errorf("duplicate agent name %q", name)
		}
		seen[name] = true
	}
	return nil
}

func validComponent(s string) bool {
	return component.MatchString(s) && !strings.Contains(s, "..") && !strings.HasSuffix(s, ".lock") && !strings.HasSuffix(s, ".")
}

func validRepo(s string) bool {
	p := strings.Split(s, "/")
	return len(p) == 2 && repoComponent.MatchString(p[0]) && repoComponent.MatchString(p[1]) && p[0] != "." && p[0] != ".." && p[1] != "." && p[1] != ".."
}

func DefaultConfigPath() (string, error) {
	dir := os.Getenv("XDG_CONFIG_HOME")
	if dir != "" {
		return filepath.Join(dir, "herdsman", "config.toml"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".config", "herdsman", "config.toml"), nil
}

func LoadConfig(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("read config %s: %w", path, err)
	}
	var c Config
	if err := toml.Unmarshal(data, &c); err != nil {
		return c, fmt.Errorf("parse config: %w", err)
	}
	c.Theme = c.Theme.WithDefaults()
	if err := c.Theme.Validate(); err != nil {
		return c, err
	}
	if err := validateAgentNames(c.AgentNames); err != nil {
		return c, err
	}
	if c.TasksDir == "" {
		c.TasksDir = "~/work/tasks"
	}
	if c.DefaultBase == "" {
		c.DefaultBase = "main"
	}
	if !validComponent(c.DefaultBase) {
		return c, fmt.Errorf("invalid default_base %q: expected a checkout directory name", c.DefaultBase)
	}
	if len(c.Machines) == 0 {
		return c, fmt.Errorf("config must declare at least one machine and repository")
	}
	for label, m := range c.Machines {
		if strings.TrimSpace(label) == "" || len(m.Repositories) == 0 {
			return c, fmt.Errorf("machine %q needs repositories", label)
		}
		for _, repo := range m.Repositories {
			if !validRepo(repo) {
				return c, fmt.Errorf("invalid repository slug %q", repo)
			}
		}
	}
	for repo, r := range c.Repositories {
		if !validRepo(repo) || (r.Base != "" && !validComponent(r.Base)) {
			return c, fmt.Errorf("invalid repository override %q", repo)
		}
	}
	c.TasksDir, err = ExpandHome(c.TasksDir)
	return c, err
}

func ExpandHome(path string) (string, error) {
	if path == "~" || strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		if path == "~" {
			return home, nil
		}
		return filepath.Join(home, strings.TrimPrefix(path, "~/")), nil
	}
	return filepath.Abs(path)
}

func (c Config) Base(repo string) string {
	if b := c.Repositories[repo].Base; b != "" {
		return b
	}
	return c.DefaultBase
}

func (c Config) RepositoryNames() []string {
	var names []string
	for _, m := range c.Machines {
		names = append(names, m.Repositories...)
	}
	slices.Sort(names)
	return slices.Compact(names)
}

// Saved profiles remain Herdr-owned. Only enabled, unambiguous labels are destinations.
func (c Config) Destinations(repo string, profiles []herdr.Machine) []herdr.Machine {
	var result []herdr.Machine
	if slices.Contains(c.Machines["local"].Repositories, repo) {
		result = append(result, herdr.Local())
	}
	counts := map[string]int{}
	for _, m := range profiles {
		if m.Enabled {
			counts[m.Label]++
		}
	}
	for _, m := range profiles {
		if m.Enabled && m.Label != "local" && counts[m.Label] == 1 && slices.Contains(c.Machines[m.Label].Repositories, repo) {
			result = append(result, m)
		}
	}
	slices.SortFunc(result, func(a, b herdr.Machine) int { return strings.Compare(a.Label, b.Label) })
	return result
}
