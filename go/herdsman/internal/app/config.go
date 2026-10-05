package app

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
	"github.com/brucenunk/home-config/go/herdsman/internal/tui/themes"
	"github.com/pelletier/go-toml/v2"
)

type Config struct {
	Daemon     DaemonConfig             `toml:"daemon"`
	Theme      themes.Config            `toml:"theme"`
	AgentNames []string                 `toml:"agent_names"`
	TasksDir   string                   `toml:"tasks_dir"`
	Machines   map[string]MachineConfig `toml:"machines"`
}

type MachineConfig struct {
	Repositories map[string]RepositoryConfig `toml:"repositories"`
}

type DaemonConfig struct {
	RefreshInterval    string `toml:"refresh_interval"`
	QueueCapacity      int    `toml:"queue_capacity"`
	RefreshConcurrency int    `toml:"refresh_concurrency"`
}

func DefaultDaemonConfig() DaemonConfig {
	return DaemonConfig{RefreshInterval: "30s", QueueCapacity: 32, RefreshConcurrency: 4}
}

// RefreshEvery parses the operator-facing duration; callers also use it for
// cache staleness so UI and scheduling share one policy.
func (c DaemonConfig) RefreshEvery() (time.Duration, error) {
	interval, err := time.ParseDuration(c.RefreshInterval)
	if err != nil || interval <= 0 || interval > time.Duration(1<<63-1)/2 {
		return 0, fmt.Errorf("daemon.refresh_interval must be a positive Go duration (for example 30s or 1m), no greater than half the duration limit")
	}
	return interval, nil
}

func (c DaemonConfig) Validate() error {
	if _, err := c.RefreshEvery(); err != nil {
		return err
	}
	if c.QueueCapacity < 1 || c.QueueCapacity > 1024 {
		return fmt.Errorf("daemon.queue_capacity must be between 1 and 1024")
	}
	if c.RefreshConcurrency < 1 || c.RefreshConcurrency > 64 {
		return fmt.Errorf("daemon.refresh_concurrency must be between 1 and 64")
	}
	return nil
}

type RepositoryConfig struct {
	Path          string `toml:"path"`
	DefaultBranch string `toml:"default_branch"`
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

// Accept branch names, not revision expressions, options, or filesystem paths.
func validBranch(s string) bool {
	for _, part := range strings.Split(s, "/") {
		if !validComponent(part) {
			return false
		}
	}
	return true
}

func validRepo(s string) bool {
	p := strings.Split(s, "/")
	return len(p) == 2 && repoComponent.MatchString(p[0]) && repoComponent.MatchString(p[1]) && p[0] != "." && p[0] != ".." && p[1] != "." && p[1] != ".."
}

func validOwner(s string) bool {
	return repoComponent.MatchString(s) && s != "." && s != ".."
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
	c := Config{Daemon: DefaultDaemonConfig()}
	if err := toml.NewDecoder(bytes.NewReader(data)).DisallowUnknownFields().Decode(&c); err != nil {
		return c, fmt.Errorf("parse config: %w", err)
	}
	if err := c.Daemon.Validate(); err != nil {
		return c, err
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
	if len(c.Machines) == 0 {
		return c, fmt.Errorf("config must declare at least one machine and repository")
	}
	for label, m := range c.Machines {
		if strings.TrimSpace(label) == "" || len(m.Repositories) == 0 {
			return c, fmt.Errorf("machine %q needs repositories", label)
		}
		for repo, r := range m.Repositories {
			if !validRepo(repo) {
				return c, fmt.Errorf("invalid repository slug %q", repo)
			}
			if !filepath.IsAbs(r.Path) || strings.ContainsAny(r.Path, "\x00\r\n") {
				return c, fmt.Errorf("machine %q repository %q needs an absolute path to a checkout or bare repository", label, repo)
			}
			if r.DefaultBranch == "" {
				r.DefaultBranch = "main"
			}
			if !validBranch(r.DefaultBranch) {
				return c, fmt.Errorf("invalid default_branch %q for %s on %s", r.DefaultBranch, repo, label)
			}
			m.Repositories[repo] = r
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

func (r RepositoryConfig) BaseRef() string {
	branch := r.DefaultBranch
	if branch == "" {
		branch = "main"
	}
	return "origin/" + branch
}

func (c Config) RepositoryNames() []string {
	var names []string
	for _, m := range c.Machines {
		for repo := range m.Repositories {
			names = append(names, repo)
		}
	}
	slices.Sort(names)
	return slices.Compact(names)
}

// ContextNames uses the declared inventory, never filesystem discovery.
func (c Config) ContextNames(includeOwners bool) []string {
	names := c.RepositoryNames()
	if includeOwners {
		for _, repo := range c.RepositoryNames() {
			owner, _, _ := strings.Cut(repo, "/")
			names = append(names, owner)
		}
		slices.Sort(names)
		names = slices.Compact(names)
	}
	return names
}

func supportsContext(repositories map[string]RepositoryConfig, name string) bool {
	if validRepo(name) {
		_, ok := repositories[name]
		return ok
	}
	if validOwner(name) {
		for repo := range repositories {
			if strings.HasPrefix(repo, name+"/") {
				return true
			}
		}
	}
	return false
}

// Saved profiles remain Herdr-owned. Only enabled, unambiguous labels are destinations.
func (c Config) Destinations(name string, profiles []herdr.Machine) []herdr.Machine {
	var result []herdr.Machine
	if supportsContext(c.Machines["local"].Repositories, name) {
		result = append(result, herdr.Local())
	}
	counts := map[string]int{}
	for _, m := range profiles {
		if m.Enabled {
			counts[m.Label]++
		}
	}
	for _, m := range profiles {
		if m.Enabled && m.Label != "local" && counts[m.Label] == 1 && supportsContext(c.Machines[m.Label].Repositories, name) {
			result = append(result, m)
		}
	}
	slices.SortFunc(result, func(a, b herdr.Machine) int { return strings.Compare(a.Label, b.Label) })
	return result
}
