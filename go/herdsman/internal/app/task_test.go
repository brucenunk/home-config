package app

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestTaskPreservesBodyAndConstructsPrompt(t *testing.T) {
	for _, newline := range []string{"\n", "\r\n"} {
		body := newline + "## Context" + newline + "Some **content**." + newline + "---" + newline
		header := strings.Join([]string{"---", `title: "A task: with punctuation"`, "repo: owner/repo", "skill: task-workflow-v3", "identifier: 20260930T193614", "---", ""}, newline)
		task, err := ParseTask([]byte(header + body))
		if err != nil {
			t.Fatal(err)
		}
		if task.Title != "A task: with punctuation" || task.Repo != "owner/repo" || task.Body != body {
			t.Fatalf("%+v", task)
		}
		if task.Prompt() != body+"\n\nLoad the task-workflow-v3 agent skill and follow instructions." {
			t.Fatal(task.Prompt())
		}
		if strings.Contains(task.Prompt(), "identifier:") {
			t.Fatal("front matter included")
		}
	}
}

func TestTaskRejectsMissingOrInvalidMetadata(t *testing.T) {
	for _, data := range []string{
		"body only", "---\ntitle: title\n", "---\nskill: review\n---\nbody",
		"---\ntitle: title\nskill: 'bad name'\n---",
		"---\ntitle: title\nskill: [review]\n---", "---\ntitle: title\ntitle: duplicate\nskill: review\n---",
	} {
		if _, err := ParseTask([]byte(data)); err == nil {
			t.Errorf("accepted %q", data)
		}
	}
}

func TestTaskWithoutSkillPreservesBodyOnly(t *testing.T) {
	for _, newline := range []string{"\n", "\r\n"} {
		for _, field := range []string{"", "skill:" + newline, `skill: ""` + newline} {
			body := newline + "## Context" + newline + "Task body." + newline
			data := "---" + newline + "title: Task" + newline + field + "---" + newline + body
			task, err := ParseTask([]byte(data))
			if err != nil {
				t.Fatal(err)
			}
			if task.Skill != "" || task.Prompt() != body {
				t.Fatalf("unexpected prompt %q", task.Prompt())
			}
		}
	}
}

func TestTaskTransportLimits(t *testing.T) {
	header := "---\ntitle: Task\nskill: review\n---\n"
	for _, body := range []string{"body\x00suffix", "body\xffsuffix", strings.Repeat("x", maxAgentArgumentBytes)} {
		if _, err := ParseTask([]byte(header + body)); err == nil {
			t.Fatal("accepted unsupported prompt")
		}
	}
	task := &Task{Title: "Task", Skill: "review"}
	task.Body = strings.Repeat("x", maxAgentArgumentBytes-len(task.Prompt()))
	if err := task.ValidateTransport(); err != nil {
		t.Fatal(err)
	}
	task.Body += "x"
	if err := task.ValidateTransport(); err == nil {
		t.Fatal("accepted over-limit prompt")
	}
	task.Body, task.Title = "body", strings.Repeat("x", maxAgentArgumentBytes+1)
	if err := task.ValidateTransport(); err == nil {
		t.Fatal("accepted over-limit title")
	}
}

func TestTaskRejectsNonRegularFiles(t *testing.T) {
	path := filepath.Join(t.TempDir(), "task.md")
	if err := syscall.Mkfifo(path, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadTask(path); err == nil || !strings.Contains(err.Error(), "regular file") {
		t.Fatal(err)
	}
	if _, err := ReadTask(t.TempDir()); err == nil {
		t.Fatal("accepted directory as task")
	}
}

func TestReadTaskRejectsOversizedFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "large.md")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	if err = file.Truncate(maxTaskFileBytes + 1); err != nil {
		file.Close()
		t.Fatal(err)
	}
	if err = file.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err = ReadTask(path); err == nil || !strings.Contains(err.Error(), "task file exceeds") {
		t.Fatal(err)
	}
	if _, err = ParseTask([]byte(strings.Repeat("\n", maxTaskFileBytes+1))); err == nil || !strings.Contains(err.Error(), "task file exceeds") {
		t.Fatal(err)
	}
}

func TestTaskTitlesRejectTerminalControls(t *testing.T) {
	for _, title := range []string{`"task\e]52;c;Y2xpcA==\a"`, `"task\tlabel"`} {
		if _, err := ParseTask([]byte("---\ntitle: " + title + "\nskill: review\n---\nBody")); err == nil {
			t.Fatal("accepted terminal controls in title")
		}
	}
	if err := (&Task{Title: "task\x1b]52;c;Y2xpcA==\a", Skill: "review"}).ValidateTransport(); err == nil {
		t.Fatal("accepted terminal controls in direct launch title")
	}
}
