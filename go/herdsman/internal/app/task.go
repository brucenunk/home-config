package app

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"

	"gopkg.in/yaml.v3"
)

type Task struct {
	Title string `yaml:"title"`
	Skill string `yaml:"skill"`
	Repo  string `yaml:"repo"`
	Body  string `yaml:"-"`
}

var skillName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]*$`)

func ReadTask(path string) (*Task, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("task must be a regular file: %s", path)
	}
	if info.Size() > maxTaskFileBytes {
		return nil, fmt.Errorf("task file exceeds %d bytes: %s", maxTaskFileBytes, path)
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxTaskFileBytes+1))
	if err != nil {
		return nil, err
	}
	return ParseTask(data)
}

// Split on delimiter lines without reformatting any of the body, including CRLF.
func ParseTask(data []byte) (*Task, error) {
	if len(data) > maxTaskFileBytes {
		return nil, fmt.Errorf("task file exceeds %d bytes", maxTaskFileBytes)
	}
	lines := bytes.SplitAfter(data, []byte("\n"))
	if len(lines) == 0 || strings.TrimRight(string(lines[0]), "\r\n") != "---" {
		return nil, fmt.Errorf("task needs YAML front matter")
	}
	for i := 1; i < len(lines); i++ {
		if strings.TrimRight(string(lines[i]), "\r\n") != "---" {
			continue
		}
		var task Task
		if err := yaml.Unmarshal(bytes.Join(lines[1:i], nil), &task); err != nil {
			return nil, fmt.Errorf("task front matter: %w", err)
		}
		if strings.TrimSpace(task.Title) == "" || strings.ContainsAny(task.Title, "\x00\r\n") {
			return nil, fmt.Errorf("task needs a non-empty single-line title")
		}
		if task.Skill != "" && !skillName.MatchString(task.Skill) {
			return nil, fmt.Errorf("task needs a valid skill name")
		}
		task.Body = string(bytes.Join(lines[i+1:], nil))
		if err := task.ValidateTransport(); err != nil {
			return nil, err
		}
		return &task, nil
	}
	return nil, fmt.Errorf("task front matter has no closing ---")
}

func (t *Task) Prompt() string {
	if t.Skill == "" {
		return t.Body
	}
	return t.Body + "\n\nLoad the " + t.Skill + " agent skill and follow instructions."
}

// Leave headroom below Linux's 128 KiB per-argument limit. The title and
// complete prompt are each passed as one CLI argument, never truncated.
const maxAgentArgumentBytes = 120 * 1024
const maxTaskFileBytes = 256 * 1024

func (t *Task) ValidateTransport() error {
	if strings.IndexFunc(t.Title, unicode.IsControl) >= 0 {
		return fmt.Errorf("task title must not contain control characters")
	}
	for _, arg := range []struct{ name, value string }{{"title", t.Title}, {"prompt", t.Prompt()}} {
		if !utf8.ValidString(arg.value) {
			return fmt.Errorf("task %s is not valid UTF-8; it cannot be sent through the Herdr CLI", arg.name)
		}
		if strings.ContainsRune(arg.value, '\x00') {
			return fmt.Errorf("task %s contains a NUL byte; it cannot be sent through the Herdr CLI", arg.name)
		}
		if len(arg.value) > maxAgentArgumentBytes {
			return fmt.Errorf("task %s exceeds the supported CLI argument size of %d bytes (got %d)", arg.name, maxAgentArgumentBytes, len(arg.value))
		}
	}
	return nil
}
