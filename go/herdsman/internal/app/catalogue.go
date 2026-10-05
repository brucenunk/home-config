package app

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
)

type Catalogue struct {
	Machines map[string]CatalogueMachine `json:"machines"`
}
type CatalogueMachine struct {
	Repositories []string      `json:"repositories"`
	Models       []ModelChoice `json:"models"`
}
type ModelChoice struct {
	Name           string   `json:"name"`
	ThinkingLevels []string `json:"thinkingLevels"`
}

var thinkingLevels = []string{"off", "minimal", "low", "medium", "high", "xhigh", "max"}

func safeHint(s string) bool {
	return utf8.ValidString(s) && len(s) <= 4096 && strings.IndexFunc(s, unicode.IsControl) < 0
}

func (c *Config) loadCatalogue(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read catalogue %s: %w", path, err)
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&c.Catalogue); err != nil {
		return fmt.Errorf("parse catalogue: %w", err)
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return fmt.Errorf("catalogue must contain one JSON object")
	}
	return c.ValidateCatalogue()
}

// Operational TOML owns routing and repository policy; JSON supplies only choices.
func (c Config) ValidateCatalogue() error {
	if c.LocalMachineName == "" || !safeHint(c.LocalMachineName) || c.LocalMachineName == "local" {
		return fmt.Errorf("local_machine_name must be a named catalogue key, not local")
	}
	if _, ok := c.Machines["local"]; !ok {
		return fmt.Errorf("local_machine_name requires machines.local")
	}
	if _, ok := c.Machines[c.LocalMachineName]; ok {
		return fmt.Errorf("local_machine_name also appears as a remote TOML machine")
	}
	if len(c.Catalogue.Machines) != len(c.Machines) {
		return fmt.Errorf("catalogue and TOML machine inventory differ")
	}
	for label, operational := range c.Machines {
		name := label
		if label == "local" {
			name = c.LocalMachineName
		}
		machine, ok := c.Catalogue.Machines[name]
		if !ok || !safeHint(name) {
			return fmt.Errorf("catalogue missing or invalid machine %q", name)
		}
		repos := slices.Clone(machine.Repositories)
		slices.Sort(repos)
		expected := make([]string, 0, len(operational.Repositories))
		for slug := range operational.Repositories {
			expected = append(expected, slug)
		}
		slices.Sort(expected)
		if !slices.Equal(repos, expected) {
			return fmt.Errorf("catalogue repositories differ from TOML for %s", name)
		}
		seen := map[string]bool{}
		providers := map[string]string{}
		for _, model := range machine.Models {
			provider, id, found := strings.Cut(model.Name, "/")
			canonical := strings.ToLower(model.Name)
			providerKey := strings.ToLower(provider)
			if !found || provider == "" || id == "" || strings.TrimSpace(provider) != provider || strings.TrimSpace(id) != id || !safeHint(model.Name) || seen[canonical] {
				return fmt.Errorf("invalid or duplicate catalogue model %q on %s", model.Name, name)
			}
			if previous, ok := providers[providerKey]; ok && previous != provider {
				return fmt.Errorf("Pi cannot distinguish catalogue providers %q and %q on %s", previous, provider, name)
			}
			providers[providerKey] = provider
			seen[canonical] = true
			levels := map[string]bool{}
			for _, level := range model.ThinkingLevels {
				if !slices.Contains(thinkingLevels, level) || levels[level] {
					return fmt.Errorf("invalid or duplicate thinking level %q for %s", level, model.Name)
				}
				levels[level] = true
			}
		}
		if operational.DefaultModel != "" && !slices.ContainsFunc(machine.Models, func(model ModelChoice) bool { return model.Name == operational.DefaultModel }) {
			return fmt.Errorf("default_model %q is not a catalogue model for %s", operational.DefaultModel, name)
		}
	}
	return nil
}

func (c Config) MachineName(m herdr.Machine) string {
	if m.IsLocal() {
		return c.LocalMachineName
	}
	return m.Label
}
func (c Config) Models(m herdr.Machine) []ModelChoice {
	return c.Catalogue.Machines[c.MachineName(m)].Models
}
func (c Config) Model(m herdr.Machine, name string) (ModelChoice, bool) {
	for _, model := range c.Models(m) {
		if model.Name == name {
			return model, true
		}
	}
	return ModelChoice{}, false
}
func (m ModelChoice) DefaultThinking() string {
	if slices.Contains(m.ThinkingLevels, "medium") {
		return "medium"
	}
	if slices.Contains(m.ThinkingLevels, "off") {
		return "off"
	}
	return ""
}

// ValidateChoices checks final selections only. Task hints never authorize execution.
func (c Config) ValidateChoices(req StartRequest) error {
	model, ok := c.Model(req.Machine, req.Model)
	if !ok {
		return fmt.Errorf("choose a configured model for %s", req.Machine.DisplayName())
	}
	if !slices.Contains(model.ThinkingLevels, req.Thinking) {
		return fmt.Errorf("thinking %q is not supported by %s", req.Thinking, req.Model)
	}
	if validOwner(req.Repo) {
		if req.BaseRef != "" {
			return fmt.Errorf("owner sessions cannot have a base ref")
		}
	} else if !validRepo(req.Repo) || !ValidBaseRef(req.BaseRef) {
		return fmt.Errorf("invalid repository/base-ref selection")
	}
	return nil
}

// A slash always means remote/ref. Plain names deliberately select local branches.
func ValidBaseRef(ref string) bool {
	return len(ref) <= 4096 && validBranch(ref) && !strings.HasPrefix(ref, "refs/")
}
