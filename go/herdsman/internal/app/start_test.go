package app

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
)

type fakeLauncher struct {
	profiles                      []herdr.Machine
	agents                        map[string][]herdr.Agent
	workspaces                    []herdr.Workspace
	workspacesByMachine           map[string][]herdr.Workspace
	sourceID                      string
	sourcePath                    string
	requestedSource, parentSource string
	calls                         []string
	fail                          string
	worktree                      herdr.WorktreeRequest
	title, prompt                 string
	workspaceLabel                string
	model, thinking               string
}

func (f *fakeLauncher) call(m herdr.Machine, op string) error {
	f.calls = append(f.calls, m.Label+":"+op)
	if op == f.fail || m.Label+":"+op == f.fail {
		return errors.New("simulated failure")
	}
	return nil
}
func start(ctx context.Context, c Config, f *fakeLauncher, req StartRequest) (StartResult, error) {
	if req.Task == nil && req.Description == "" {
		req.Description = "Investigate deploy latency"
	}
	if req.Model == "" {
		req.Model = "example/vendor/model"
	}
	if req.Thinking == "" {
		req.Thinking = "medium"
	}
	if validRepo(req.Repo) && req.BaseRef == "" {
		req.BaseRef = c.Machines[req.Machine.Label].Repositories[req.Repo].BaseRef()
	}
	return Start(ctx, c, f, f.profiles, req)
}
func (f *fakeLauncher) Home(_ context.Context, m herdr.Machine) (string, error) {
	return "/home/test", f.call(m, "home")
}

func (f *fakeLauncher) OwnerHome(ctx context.Context, m herdr.Machine, owner string) (string, error) {
	if owner != "owner" {
		return "", errors.New("unexpected owner lookup")
	}
	return f.Home(ctx, m)
}
func (f *fakeLauncher) Snapshot(_ context.Context, m herdr.Machine) (herdr.Snapshot, error) {
	workspaces := f.workspaces
	if f.workspacesByMachine != nil {
		workspaces = f.workspacesByMachine[m.Label]
	}
	return herdr.Snapshot{Agents: f.agents[m.Label], Workspaces: workspaces}, f.call(m, "snapshot")
}
func (f *fakeLauncher) Source(_ context.Context, m herdr.Machine, path string) (herdr.Source, error) {
	f.requestedSource = path
	if f.sourcePath != "" {
		path = f.sourcePath
	}
	return herdr.Source{CheckoutPath: path, WorkspaceID: f.sourceID}, f.call(m, "source")
}
func creation(id, pane string) herdr.Created {
	var c herdr.Created
	c.Workspace.ID, c.RootPane.ID = id, pane
	return c
}
func (f *fakeLauncher) CreateParent(_ context.Context, m herdr.Machine, source, label string) (herdr.Created, error) {
	f.parentSource = source
	f.workspaceLabel = label
	if label != "owner/repo" && !strings.Contains(label, " · herdsman: ") {
		return herdr.Created{}, errors.New("bad parent arguments")
	}
	return creation("parent", "parent:p1"), f.call(m, "parent")
}
func (f *fakeLauncher) RenameParent(_ context.Context, m herdr.Machine, id, label string) error {
	return f.call(m, "rename")
}
func (f *fakeLauncher) CreateWorktree(_ context.Context, m herdr.Machine, r herdr.WorktreeRequest) (herdr.Created, error) {
	f.worktree = r
	return creation("task", "task:p1"), f.call(m, "worktree")
}
func (f *fakeLauncher) StartAgent(_ context.Context, m herdr.Machine, name, pane, title, model, thinking string) error {
	f.model, f.thinking = model, thinking
	f.title = title
	return f.call(m, "start")
}
func (f *fakeLauncher) Prompt(_ context.Context, m herdr.Machine, name, prompt string) error {
	f.prompt = prompt
	return f.call(m, "prompt")
}
func (f *fakeLauncher) Focus(_ context.Context, m herdr.Machine, name string) error {
	return f.call(m, "focus")
}

var testAgentNames = []string{"runner", "helper", "quokka", "platypus"}

func startConfig() Config {
	return Config{LocalMachineName: "machine-a", Catalogue: Catalogue{Machines: map[string]CatalogueMachine{
		"machine-a": {Models: []ModelChoice{{Name: "example/vendor/model", ThinkingLevels: []string{"off", "medium", "high"}}}},
		"remote":    {Models: []ModelChoice{{Name: "example/vendor/model", ThinkingLevels: []string{"off", "medium", "high"}}}},
	}}, AgentNames: testAgentNames, Machines: map[string]MachineConfig{
		"local":  {Repositories: map[string]RepositoryConfig{"owner/repo": {Path: "/home/test/work/owner/repo/main", DefaultBranch: "main"}}},
		"remote": {Repositories: map[string]RepositoryConfig{"owner/repo": {Path: "/srv/git/repo.git", DefaultBranch: "main"}}},
	}}
}
func TestStartLocalRemoteAndEmpty(t *testing.T) {
	for _, remote := range []bool{false, true} {
		for _, withTask := range []bool{false, true} {
			m := herdr.Local()
			if remote {
				m = herdr.Machine{ID: "profile", Label: "remote", Target: "ssh-alias", Enabled: true}
			}
			f := &fakeLauncher{profiles: []herdr.Machine{{ID: "profile", Label: "remote", Enabled: true}}}
			req := StartRequest{Repo: "owner/repo", Machine: m}
			if withTask {
				req.Task = &Task{Title: "Task title", Skill: "review", Body: "Task body"}
			}
			r, err := start(context.Background(), startConfig(), f, req)
			if err != nil {
				t.Fatal(err)
			}
			if r.Machine != m.DisplayName() {
				t.Fatal(r.Machine, m.DisplayName())
			}
			want := []string{"local:snapshot", "remote:snapshot", m.Label + ":home", m.Label + ":source", m.Label + ":parent", m.Label + ":worktree", m.Label + ":start"}
			if withTask {
				want = append(want, m.Label+":prompt")
			}
			want = append(want, m.Label+":focus")
			if !reflect.DeepEqual(f.calls, want) {
				t.Fatal(f.calls, want)
			}
			if r.Branch != "jamesl/"+filepath.Base(r.Path) || f.worktree.Base != "refs/remotes/origin/main" || f.worktree.Parent != "parent" || f.parentSource != startConfig().Machines[m.Label].Repositories["owner/repo"].Path {
				t.Fatal(r, f.worktree)
			}
			if withTask {
				if f.title != req.Task.Title || f.prompt != req.Task.Prompt() {
					t.Fatal(f.title, f.prompt)
				}
			} else if f.title != "Investigate deploy latency" || f.worktree.Label != f.title || f.prompt != "" {
				t.Fatal(f.title, f.prompt)
			}
		}
	}
}

func TestAgentNameAvailabilityAndExhaustion(t *testing.T) {
	occupied := map[string]bool{}
	for _, name := range testAgentNames {
		occupied[name] = true
	}
	if _, err := ChooseAgentName(testAgentNames, occupied); err == nil {
		t.Fatal("accepted exhausted pool")
	}
	delete(occupied, "quokka")
	for range 30 {
		name, err := ChooseAgentName(testAgentNames, occupied)
		if err != nil || name != "quokka" {
			t.Fatal(name, err)
		}
	}
	seen := map[string]bool{}
	for range 100 {
		name, _ := ChooseAgentName(testAgentNames, nil)
		seen[name] = true
	}
	if len(seen) < 2 {
		t.Fatal("always chose first agent name")
	}
}

func TestLaunchFailureStopsWithoutRetry(t *testing.T) {
	for _, failure := range []string{"snapshot", "home", "source", "parent", "worktree", "start", "prompt", "focus"} {
		t.Run(failure, func(t *testing.T) {
			f := &fakeLauncher{fail: failure}
			r, err := start(context.Background(), startConfig(), f, StartRequest{Repo: "owner/repo", Machine: herdr.Local(), Task: &Task{Title: "Title", Skill: "review"}})
			if err == nil || f.calls[len(f.calls)-1] != "local:"+failure {
				t.Fatal(err, f.calls)
			}
			if len(r.Steps) > 0 && !strings.Contains(err.Error(), "No automatic cleanup") {
				t.Fatal(err)
			}
			if failure == "prompt" && !strings.Contains(err.Error(), "started Pi") {
				t.Fatal(err)
			}
		})
	}
}

func TestUnknownGlobalOccupancyStopsBeforeMutation(t *testing.T) {
	f := &fakeLauncher{profiles: []herdr.Machine{{ID: "other", Label: "unconfigured", Enabled: true}}, fail: "unconfigured:snapshot"}
	_, err := start(context.Background(), startConfig(), f, StartRequest{Repo: "owner/repo", Machine: herdr.Local()})
	if err == nil || len(f.calls) != 2 {
		t.Fatal(err, f.calls)
	}
}

func TestParentReuseRenameAndAmbiguity(t *testing.T) {
	var w herdr.Workspace
	w.ID, w.Label = "existing", "old label"
	// Use JSON-shaped metadata without inventing an unrelated domain type.
	w.Worktree = &struct {
		CheckoutPath string `json:"checkout_path"`
		Linked       bool   `json:"is_linked_worktree"`
	}{CheckoutPath: "/home/test/work/owner/repo/main"}
	f := &fakeLauncher{workspaces: []herdr.Workspace{w}}
	r, err := start(context.Background(), startConfig(), f, StartRequest{Repo: "owner/repo", Machine: herdr.Local()})
	if err != nil || r.Parent != "existing" || !slicesContain(f.calls, "local:rename") || slicesContain(f.calls, "local:parent") {
		t.Fatal(r, err, f.calls)
	}
	f = &fakeLauncher{workspaces: []herdr.Workspace{w, w}}
	_, err = start(context.Background(), startConfig(), f, StartRequest{Repo: "owner/repo", Machine: herdr.Local()})
	if err == nil || slicesContain(f.calls, "local:worktree") {
		t.Fatal(err, f.calls)
	}
}

func slicesContain(values []string, s string) bool {
	for _, v := range values {
		if v == s {
			return true
		}
	}
	return false
}

func TestOrdinaryParentResolution(t *testing.T) {
	for _, label := range []string{"main shell", "owner/repo"} {
		f := &fakeLauncher{sourceID: "ordinary", workspaces: []herdr.Workspace{{ID: "ordinary", Label: label}}}
		r, err := start(context.Background(), startConfig(), f, StartRequest{Repo: "owner/repo", Machine: herdr.Local()})
		if err != nil || r.Parent != "ordinary" || slicesContain(f.calls, "local:parent") {
			t.Fatal(r, err, f.calls)
		}
		if slicesContain(f.calls, "local:rename") != (label != "owner/repo") {
			t.Fatal(f.calls)
		}
	}
	// An ordinary source must not be confused with another workspace claiming its label.
	f := &fakeLauncher{sourceID: "ordinary", workspaces: []herdr.Workspace{{ID: "ordinary", Label: "source"}, {ID: "other", Label: "owner/repo"}}}
	_, err := start(context.Background(), startConfig(), f, StartRequest{Repo: "owner/repo", Machine: herdr.Local()})
	if err == nil || slicesContain(f.calls, "local:rename") || slicesContain(f.calls, "local:worktree") {
		t.Fatal(err, f.calls)
	}
}

func TestGlobalAgentNamesAreExcluded(t *testing.T) {
	occupied := []herdr.Agent{}
	for _, name := range testAgentNames {
		if name != "platypus" {
			occupied = append(occupied, herdr.Agent{Name: name})
		}
	}
	f := &fakeLauncher{profiles: []herdr.Machine{{ID: "other", Label: "other", Enabled: true}}, agents: map[string][]herdr.Agent{"other": occupied}}
	r, err := start(context.Background(), startConfig(), f, StartRequest{Repo: "owner/repo", Machine: herdr.Local()})
	if err != nil || r.AgentName != "platypus" {
		t.Fatal(r.AgentName, err)
	}
}

func TestLaunchUsesDefaultBranch(t *testing.T) {
	c := startConfig()
	c.Machines["local"].Repositories["owner/repo"] = RepositoryConfig{Path: "/home/test/work/owner/repo/main", DefaultBranch: "master"}
	f := &fakeLauncher{sourceID: "ordinary", workspaces: []herdr.Workspace{{ID: "ordinary", Label: "owner/repo"}}}
	_, err := start(context.Background(), c, f, StartRequest{Repo: "owner/repo", Machine: herdr.Local()})
	if err != nil || f.worktree.Base != "refs/remotes/origin/master" || f.requestedSource != "/home/test/work/owner/repo/main" {
		t.Fatal(err, f.worktree)
	}
}
func TestLaunchIndependentPathAndDefaultBranch(t *testing.T) {
	for _, m := range []herdr.Machine{herdr.Local(), {ID: "profile", Label: "remote", Target: "ssh-alias", Enabled: true}} {
		for _, path := range []string{"/home/test/work/owner/repo/main", "/srv/checkouts/master", "/storage/repo.git"} {
			for _, reuse := range []bool{false, true} {
				t.Run(fmt.Sprintf("%s/%s/reuse=%t", m.Label, path, reuse), func(t *testing.T) {
					c := startConfig()
					c.Machines[m.Label].Repositories["owner/repo"] = RepositoryConfig{Path: path, DefaultBranch: "master"}
					f := &fakeLauncher{profiles: []herdr.Machine{{ID: "profile", Label: "remote", Enabled: true}}}
					if reuse {
						f.sourceID = "existing"
						f.workspaces = []herdr.Workspace{{ID: "existing", Label: "owner/repo"}}
					}
					// Bare sources need no default-branch checkout or probe.
					r, err := start(context.Background(), c, f, StartRequest{Repo: "owner/repo", Machine: m})
					if err != nil || f.requestedSource != path || f.worktree.Base != "refs/remotes/origin/master" || filepath.Dir(r.Path) != "/home/test/work/owner/repo" {
						t.Fatal(r, err, f)
					}
					if reuse {
						if r.Parent != "existing" || f.parentSource != "" {
							t.Fatal(r, f)
						}
					} else if f.parentSource != path {
						t.Fatal(f)
					}
				})
			}
		}
	}
}

func TestLaunchRejectsDifferentSourceBeforeMutation(t *testing.T) {
	for _, path := range []string{"/home/test/work/owner/repo/main", "/storage/repo.git"} {
		for _, resolved := range []string{"/home/test/work/other/repo/main", "/home/test/work/owner/repo/other.git", "/home/test/work/owner/repo/master"} {
			c := startConfig()
			c.Machines["local"].Repositories["owner/repo"] = RepositoryConfig{Path: path, DefaultBranch: "master"}
			f := &fakeLauncher{sourcePath: resolved, sourceID: "existing", workspaces: []herdr.Workspace{{ID: "existing", Label: "owner/repo"}}}
			r, err := start(context.Background(), c, f, StartRequest{Repo: "owner/repo", Machine: herdr.Local()})
			if err == nil || !strings.Contains(err.Error(), "different source checkout") || len(r.Steps) != 0 || f.calls[len(f.calls)-1] != "local:source" {
				t.Fatal(r, err, f.calls)
			}
		}
	}
}

func TestInvalidPromptStopsBeforeLaunchReadsOrWrites(t *testing.T) {
	for _, body := range []string{"body\x00suffix", "body\xffsuffix", strings.Repeat("x", maxAgentArgumentBytes)} {
		f := &fakeLauncher{}
		_, err := start(context.Background(), startConfig(), f, StartRequest{Repo: "owner/repo", Machine: herdr.Local(), Task: &Task{Title: "Task", Skill: "review", Body: body}})
		if err == nil || len(f.calls) != 0 {
			t.Fatal(err, f.calls)
		}
	}
}

func TestUsesHerdrSelectedOrdinaryParent(t *testing.T) {
	// Herdr resolves the first source workspace. Do not scan each ordinary pane
	// to enforce uniqueness: either workspace at this checkout can anchor the group.
	f := &fakeLauncher{sourceID: "chosen", workspaces: []herdr.Workspace{{ID: "chosen", Label: "source one"}, {ID: "other", Label: "source two"}}}
	r, err := start(context.Background(), startConfig(), f, StartRequest{Repo: "owner/repo", Machine: herdr.Local()})
	if err != nil || r.Parent != "chosen" || slicesContain(f.calls, "local:parent") {
		t.Fatal(r, err, f.calls)
	}
}

func TestLaunchUsesConfiguredName(t *testing.T) {
	c := startConfig()
	c.AgentNames = []string{"custom_agent"}
	r, err := start(context.Background(), c, &fakeLauncher{}, StartRequest{Repo: "owner/repo", Machine: herdr.Local()})
	if err != nil || r.AgentName != "custom_agent" || r.Title != "Investigate deploy latency" {
		t.Fatal(r, err)
	}
}

func TestLaunchTaskWithoutSkillSendsOnlyBody(t *testing.T) {
	f := &fakeLauncher{}
	task := &Task{Title: "Task", Body: "\nTask body\n"}
	_, err := start(context.Background(), startConfig(), f, StartRequest{Repo: "owner/repo", Machine: herdr.Local(), Task: task})
	if err != nil || f.prompt != task.Body || !slicesContain(f.calls, "local:prompt") {
		t.Fatal(err, f.prompt, f.calls)
	}
}

func TestStartReusesDestinationSnapshot(t *testing.T) {
	m := herdr.Machine{ID: "profile", Label: "remote", Enabled: true}
	f := &fakeLauncher{
		profiles: []herdr.Machine{m, {ID: "disabled", Label: "disabled"}},
		sourceID: "remote-parent",
		workspacesByMachine: map[string][]herdr.Workspace{
			"local":  {{ID: "local-parent", Label: "owner/repo"}},
			"remote": {{ID: "remote-parent", Label: "owner/repo"}},
		},
	}
	r, err := start(context.Background(), startConfig(), f, StartRequest{Repo: "owner/repo", Machine: m})
	if err != nil || r.Parent != "remote-parent" {
		t.Fatal("did not reuse destination inventory", r, err)
	}
	want := []string{"local:snapshot", "remote:snapshot", "remote:home", "remote:source", "remote:worktree", "remote:start", "remote:focus"}
	if !reflect.DeepEqual(f.calls, want) {
		t.Fatal("extra inventory calls or inspected disabled server", f.calls, want)
	}
}
