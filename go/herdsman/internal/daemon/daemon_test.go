package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/brucenunk/home-config/go/herdsman/internal/app"
	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
)

type fakeBackend struct {
	app.Launcher
	mu             sync.Mutex
	profiles       []herdr.Machine
	snapshots      map[string]herdr.Snapshot
	snapshotErrors map[string]error
	profileError   error
	snapshotHook   func(context.Context, herdr.Machine) error
	calls          []string
	fail           string
	createEntered  chan struct{}
	createRelease  chan struct{}
}

func clone[T any](value T) T {
	data, _ := json.Marshal(value)
	var result T
	_ = json.Unmarshal(data, &result)
	return result
}
func (f *fakeBackend) Machines(context.Context) ([]herdr.Machine, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return clone(f.profiles), f.profileError
}
func (f *fakeBackend) Snapshot(ctx context.Context, m herdr.Machine) (herdr.Snapshot, error) {
	f.mu.Lock()
	snapshot, err, hook := clone(f.snapshots[key(m)]), f.snapshotErrors[key(m)], f.snapshotHook
	f.mu.Unlock()
	if hook != nil {
		if e := hook(ctx, m); e != nil {
			return snapshot, e
		}
	}
	return snapshot, err
}
func (f *fakeBackend) record(call string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, call)
	if f.fail == call {
		return errors.New("injected failure")
	}
	return nil
}
func (f *fakeBackend) Prompt(_ context.Context, m herdr.Machine, name, prompt string) error {
	if err := f.record("prompt:" + name); err != nil {
		return err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	s := f.snapshots[key(m)]
	for i, a := range s.Agents {
		if a.Name == name {
			s.Agents = append(s.Agents[:i], s.Agents[i+1:]...)
			break
		}
	}
	f.snapshots[key(m)] = s
	return nil
}
func (f *fakeBackend) WaitForQuit(context.Context, herdr.Machine, string) error {
	return f.record("wait")
}
func (f *fakeBackend) RemoveWorktree(_ context.Context, _ herdr.Machine, id, _ string) error {
	return f.record("remove:" + id)
}
func (f *fakeBackend) CloseWorkspace(_ context.Context, _ herdr.Machine, id string) error {
	return f.record("close:" + id)
}
func (f *fakeBackend) OwnerHome(context.Context, herdr.Machine, string) (string, error) {
	return "/home/test", nil
}
func (f *fakeBackend) CreateParent(ctx context.Context, _ herdr.Machine, _, _ string) (herdr.Created, error) {
	if err := f.record("create"); err != nil {
		return herdr.Created{}, err
	}
	if f.createEntered != nil {
		select {
		case f.createEntered <- struct{}{}:
		case <-ctx.Done():
			return herdr.Created{}, ctx.Err()
		}
	}
	if f.createRelease != nil {
		select {
		case <-f.createRelease:
		case <-ctx.Done():
			return herdr.Created{}, ctx.Err()
		}
	}
	result := herdr.Created{Workspace: herdr.Workspace{ID: "new"}}
	result.RootPane.ID = "new:p1"
	return result, nil
}
func (f *fakeBackend) StartAgent(context.Context, herdr.Machine, string, string, string) error {
	return f.record("agent start")
}
func (f *fakeBackend) Focus(context.Context, herdr.Machine, string) error { return f.record("focus") }
func config() app.Config {
	return app.Config{Daemon: app.DefaultDaemonConfig(), AgentNames: []string{"possum"}, Machines: map[string]app.MachineConfig{"local": {Repositories: []string{"owner/repo"}}}}
}

func testDaemon(t *testing.T, c app.Config, backend Backend, logger *slog.Logger) *Daemon {
	t.Helper()
	d, err := New(c, backend, logger)
	if err != nil {
		t.Fatal(err)
	}
	return d
}
func backend() *fakeBackend {
	return &fakeBackend{profiles: []herdr.Machine{}, snapshots: map[string]herdr.Snapshot{}, snapshotErrors: map[string]error{}}
}
func logger(out io.Writer) *slog.Logger { return slog.New(slog.NewJSONHandler(out, nil)) }
func eventually(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("condition not met")
}
func stopRun(t *testing.T, d *Daemon) (context.CancelFunc, <-chan struct{}) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { d.Run(ctx); close(done) }()
	eventually(t, func() bool { d.mu.Lock(); defer d.mu.Unlock(); return d.accepting })
	t.Cleanup(func() {
		cancel()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("daemon shutdown timed out")
		}
	})
	return cancel, done
}
func startRequest() Request {
	c := config()
	endpoint, _ := herdr.LocalEndpoint()
	return Request{ConfigID: ConfigID(c), LocalEndpoint: endpoint, Start: &app.StartRequest{Repo: "owner", Machine: herdr.Local(), Description: "Testing"}}
}
func fixture() herdr.Snapshot {
	s := herdr.Snapshot{}
	for _, name := range []string{"one", "two", "three"} {
		s.Agents = append(s.Agents, herdr.Agent{Name: name, Kind: "pi", Status: "idle", WorkspaceID: name, PaneID: name + ":p1", Session: &herdr.AgentSession{Kind: "pi", Value: name}})
		w := herdr.Workspace{ID: name, Label: name}
		w.Worktree = &struct {
			CheckoutPath string `json:"checkout_path"`
			Linked       bool   `json:"is_linked_worktree"`
		}{"/repo/" + name, true}
		s.Workspaces = append(s.Workspaces, w)
	}
	return s
}

func TestCacheReadIndependentOfSlowMachine(t *testing.T) {
	f := backend()
	remote := herdr.Machine{ID: "r", Label: "remote", Target: "ssh", Enabled: true}
	f.profiles = []herdr.Machine{remote}
	blocked := make(chan struct{})
	f.snapshotHook = func(ctx context.Context, m herdr.Machine) error {
		if !m.IsLocal() {
			select {
			case <-blocked:
			case <-ctx.Done():
				return ctx.Err()
			}
		}
		return nil
	}
	d := testDaemon(t, config(), f, logger(io.Discard))
	cancel, done := stopRun(t, d)
	eventually(t, func() bool { i := d.Inventory(); return len(i.Machines) == 2 && !i.Machines[0].Updated.IsZero() })
	returned := make(chan Inventory, 1)
	go func() { returned <- d.Inventory() }()
	select {
	case i := <-returned:
		if !i.Machines[1].Updated.IsZero() {
			t.Fatal("remote should still be loading")
		}
	case <-time.After(time.Second):
		t.Fatal("cache read blocked on remote")
	}
	cancel()
	<-done
}
func TestCacheRetainsFailedSnapshotAndOwnsCopies(t *testing.T) {
	f := backend()
	f.snapshots["local"] = fixture()
	var logs bytes.Buffer
	d := testDaemon(t, config(), f, logger(&logs))
	d.refreshMachine(context.Background(), herdr.Local(), 0, d.machines["local"])
	original := d.Inventory()
	original.Machines[0].Snapshot.Agents[0].Name = "changed"
	if d.Inventory().Machines[0].Snapshot.Agents[0].Name != "one" {
		t.Fatal("inventory aliases cache")
	}
	updated := d.Inventory().Machines[0].Updated
	f.snapshotErrors["local"] = errors.New("offline")
	d.refreshMachine(context.Background(), herdr.Local(), 0, d.machines["local"])
	d.refreshMachine(context.Background(), herdr.Local(), 0, d.machines["local"])
	i := d.Inventory()
	if i.Machines[0].Error != "offline" || !i.Machines[0].Updated.Equal(updated) || len(i.FinishTargets()) != 3 {
		t.Fatal(i)
	}
	delete(f.snapshotErrors, "local")
	d.refreshMachine(context.Background(), herdr.Local(), 0, d.machines["local"])
	if strings.Count(logs.String(), "inventory refresh failed") != 1 || strings.Count(logs.String(), "inventory refresh recovered") != 1 {
		t.Fatal(logs.String())
	}
}
func TestObsoleteRefreshCannotOverwriteMutation(t *testing.T) {
	f := backend()
	entered, release := make(chan struct{}), make(chan struct{})
	f.snapshotHook = func(context.Context, herdr.Machine) error { close(entered); <-release; return nil }
	d := testDaemon(t, config(), f, logger(io.Discard))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d.schedule(ctx, false)
	<-entered
	d.mutation(herdr.Local(), true)
	d.mutation(herdr.Local(), false)
	close(release)
	d.wg.Wait()
	if !d.Inventory().Machines[0].Updated.IsZero() {
		t.Fatal("obsolete snapshot published")
	}
	f.mu.Lock()
	f.snapshotHook = nil
	f.snapshots["local"] = fixture()
	f.mu.Unlock()
	d.schedule(ctx, false)
	d.wg.Wait()
	if len(d.Inventory().FinishTargets()) != 3 {
		t.Fatal("post-mutation refresh lost")
	}
}
func TestProfilesRemoveDisabledAndRetainOnFailure(t *testing.T) {
	f := backend()
	m := herdr.Machine{ID: "r", Label: "remote", Target: "ssh", Enabled: true}
	f.profiles = []herdr.Machine{m}
	d := testDaemon(t, config(), f, logger(io.Discard))
	d.refreshProfiles(context.Background())
	if len(d.Inventory().Machines) != 2 {
		t.Fatal("missing remote")
	}
	f.profileError = errors.New("offline")
	d.refreshProfiles(context.Background())
	if len(d.Inventory().Machines) != 2 || d.Inventory().ProfilesError == "" {
		t.Fatal("failure lost inventory")
	}
	f.profileError = nil
	f.profiles[0].Enabled = false
	d.refreshProfiles(context.Background())
	if len(d.Inventory().Machines) != 1 {
		t.Fatal("disabled remote retained")
	}
}
func TestBoundedQueueAndOwnedRequest(t *testing.T) {
	d := testDaemon(t, config(), backend(), logger(io.Discard))
	d.accepting = true
	r := startRequest()
	if err := d.Submit(r); err != nil {
		t.Fatal(err)
	}
	r.Start.Description = "changed"
	job := <-d.queue
	if job.request.Start.Description != "Testing" {
		t.Fatal("queued request aliases caller")
	}
	for n := 0; n < config().Daemon.QueueCapacity; n++ {
		if err := d.Submit(startRequest()); err != nil {
			t.Fatal(err)
		}
	}
	if err := d.Submit(startRequest()); err == nil || !strings.Contains(err.Error(), "full") {
		t.Fatal(err)
	}
	d.accepting = false
	if err := d.Submit(startRequest()); err == nil {
		t.Fatal("accepted during shutdown")
	}
}
func TestSerialWorkerAndShutdownDiscard(t *testing.T) {
	f := backend()
	f.createEntered = make(chan struct{}, 2)
	f.createRelease = make(chan struct{})
	var logs bytes.Buffer
	d := testDaemon(t, config(), f, logger(&logs))
	cancel, done := stopRun(t, d)
	if err := d.Submit(startRequest()); err != nil {
		t.Fatal(err)
	}
	select {
	case <-f.createEntered:
	case <-time.After(time.Second):
		t.Fatal("first request did not start")
	}
	if err := d.Submit(startRequest()); err != nil {
		t.Fatal(err)
	}
	select {
	case <-f.createEntered:
		t.Fatal("second mutation ran concurrently")
	case <-time.After(30 * time.Millisecond):
	}
	cancel()
	<-done
	if !strings.Contains(logs.String(), "request discarded on shutdown") || !strings.Contains(logs.String(), "request failed") {
		t.Fatal(logs.String())
	}
	restarted := testDaemon(t, config(), f, logger(io.Discard))
	if len(restarted.queue) != 0 {
		t.Fatal("requests persisted")
	}
}
func TestSerialWorkerExecutesFollowingRequest(t *testing.T) {
	f := backend()
	f.createEntered = make(chan struct{}, 2)
	f.createRelease = make(chan struct{})
	d := testDaemon(t, config(), f, logger(io.Discard))
	_, _ = stopRun(t, d)
	if err := d.Submit(startRequest()); err != nil {
		t.Fatal(err)
	}
	<-f.createEntered
	if err := d.Submit(startRequest()); err != nil {
		t.Fatal(err)
	}
	close(f.createRelease)
	select {
	case <-f.createEntered:
	case <-time.After(time.Second):
		t.Fatal("following request did not execute")
	}
	eventually(t, func() bool {
		f.mu.Lock()
		defer f.mu.Unlock()
		return strings.Count(strings.Join(f.calls, ","), "focus") == 2
	})
}
func TestFinishRevalidatesBeforeQuitAndStopsBatch(t *testing.T) {
	for _, change := range []string{"session", "status", "workspace", "occupant"} {
		t.Run(change, func(t *testing.T) {
			f := backend()
			f.snapshots["local"] = fixture()
			targets, _ := app.FinishTargetsFromSnapshot(herdr.Local(), f.snapshots["local"])
			s := clone(f.snapshots["local"])
			switch change {
			case "session":
				s.Agents[0].Session.Value = "replacement"
			case "status":
				s.Agents[0].Status = "working"
			case "workspace":
				s.Workspaces[0].Worktree.CheckoutPath = "/different"
			case "occupant":
				a := s.Agents[0]
				a.Name = "extra"
				s.Agents = append(s.Agents, a)
			}
			f.snapshots["local"] = s
			d := testDaemon(t, config(), f, logger(io.Discard))
			if err := d.execute(context.Background(), queued{1, Request{Finish: targets}}); err == nil {
				t.Fatal("stale selection accepted")
			}
			if len(f.calls) != 0 {
				t.Fatal("mutated stale selection", f.calls)
			}
		})
	}
	f := backend()
	f.snapshots["local"] = fixture()
	targets, _ := app.FinishTargetsFromSnapshot(herdr.Local(), f.snapshots["local"])
	f.fail = "prompt:two"
	var logs bytes.Buffer
	d := testDaemon(t, config(), f, logger(&logs))
	err := d.execute(context.Background(), queued{1, Request{Finish: targets}})
	if err == nil || !strings.Contains(err.Error(), "1 completed, 1 unattempted") {
		t.Fatal(err)
	}
	if strings.Contains(strings.Join(f.calls, ","), "prompt:three") || !strings.Contains(logs.String(), "quit submitted") || !strings.Contains(logs.String(), "session unattempted") {
		t.Fatal(f.calls, logs.String())
	}
}
func TestMachineRevalidationUsesCurrentProfiles(t *testing.T) {
	old := herdr.Machine{ID: "r", Label: "remote", Target: "old", Enabled: true}
	current := old
	current.Target = "new"
	if _, err := resolve(old, []herdr.Machine{current}); err == nil {
		t.Fatal("changed target accepted")
	}
	current = old
	current.Session = "replacement"
	if _, err := resolve(old, []herdr.Machine{current}); err == nil {
		t.Fatal("changed remote session accepted")
	}
	current = old
	current.Enabled = false
	if _, err := resolve(old, []herdr.Machine{current}); err == nil {
		t.Fatal("disabled accepted")
	}
}

func TestIncompleteRefreshIsAnErrorNotEmptyInventory(t *testing.T) {
	f := backend()
	f.snapshots["local"] = fixture()
	d := testDaemon(t, config(), f, logger(io.Discard))
	d.refreshMachine(context.Background(), herdr.Local(), 0, d.machines["local"])
	f.snapshots["local"] = herdr.Snapshot{Agents: []herdr.Agent{{Name: "broken"}}}
	d.refreshMachine(context.Background(), herdr.Local(), 0, d.machines["local"])
	i := d.Inventory()
	if i.Machines[0].Error == "" || len(i.FinishTargets()) != 3 {
		t.Fatal(i)
	}
}

func TestSessionOnlyChangeInvalidatesMachineCache(t *testing.T) {
	f := backend()
	m := herdr.Machine{ID: "r", Label: "remote", Target: "ssh", Session: "original", Enabled: true}
	f.profiles = []herdr.Machine{m}
	f.snapshots[key(m)] = fixture()
	d := testDaemon(t, config(), f, logger(io.Discard))
	d.refreshProfiles(context.Background())
	d.refreshMachine(context.Background(), m, 0, d.machines[key(m)])
	f.profiles[0].Session = "replacement"
	d.refreshProfiles(context.Background())
	i := d.Inventory()
	if !i.Machines[1].Updated.IsZero() || len(i.Machines[1].Snapshot.Agents) != 0 {
		t.Fatal("old-session snapshot retained", i)
	}
}

type changingProfiles struct {
	Backend
	calls   int
	machine herdr.Machine
}

func (f *changingProfiles) Machines(context.Context) ([]herdr.Machine, error) {
	f.calls++
	m := f.machine
	if f.calls > 1 {
		m.Target = "replacement"
	}
	return []herdr.Machine{m}, nil
}
func TestFinishBatchReloadsProfilesForEveryTarget(t *testing.T) {
	f := backend()
	m := herdr.Machine{ID: "r", Label: "remote", Target: "original", Enabled: true}
	f.snapshots[key(m)] = fixture()
	targets, _ := app.FinishTargetsFromSnapshot(m, f.snapshots[key(m)])
	changing := &changingProfiles{Backend: f, machine: m}
	d := testDaemon(t, config(), changing, logger(io.Discard))
	err := d.execute(context.Background(), queued{1, Request{Finish: targets}})
	if err == nil || changing.calls != 2 || strings.Contains(strings.Join(f.calls, ","), "prompt:two") {
		t.Fatal(err, changing.calls, f.calls)
	}
}
func TestRoutingMismatchRejected(t *testing.T) {
	t.Setenv("HERDR_SOCKET_PATH", "")
	_ = os.Unsetenv("HERDR_SOCKET_PATH")
	t.Setenv("HERDR_SESSION", "default")
	d := testDaemon(t, config(), backend(), logger(io.Discard))
	d.accepting = true
	i := d.Inventory()
	t.Setenv("HERDR_SESSION", "other")
	if err := i.CheckConfig(config()); err == nil {
		t.Fatal("named session mismatch accepted")
	}
	if err := d.Submit(startRequest()); err == nil {
		t.Fatal("different caller endpoint queued")
	}
	t.Setenv("HERDR_SOCKET_PATH", "/different/socket")
	if err := i.CheckConfig(config()); err == nil {
		t.Fatal("socket override mismatch accepted")
	}
}

func TestConfiguredDaemonPolicy(t *testing.T) {
	c := config()
	c.Daemon = app.DaemonConfig{RefreshInterval: "10ms", QueueCapacity: 2, RefreshConcurrency: 1}
	f := backend()
	reads := make(chan struct{}, 16)
	f.snapshotHook = func(context.Context, herdr.Machine) error {
		select {
		case reads <- struct{}{}:
		default:
		}
		return nil
	}
	d := testDaemon(t, c, f, logger(io.Discard))
	if cap(d.queue) != 2 || cap(d.slots) != 1 || d.interval != 10*time.Millisecond {
		t.Fatal("policy not applied")
	}
	_, _ = stopRun(t, d)
	for n := 0; n < 2; n++ {
		select {
		case <-reads:
		case <-time.After(time.Second):
			t.Fatal("configured refresh interval not used")
		}
	}
	c.Daemon.QueueCapacity = 0
	if _, err := New(c, f, logger(io.Discard)); err == nil {
		t.Fatal("invalid constructor policy accepted")
	}
}

func TestExplicitCopiesOwnNestedValues(t *testing.T) {
	s := fixture()
	copied := cloneSnapshot(s)
	copied.Agents[0].Session.Value = "changed"
	copied.Workspaces[0].Worktree.CheckoutPath = "changed"
	copied.Workspaces[0].Label = "changed"
	if s.Agents[0].Session.Value != "one" || s.Workspaces[0].Worktree.CheckoutPath != "/repo/one" || s.Workspaces[0].Label != "one" {
		t.Fatal("snapshot copy aliases original")
	}
	r := startRequest()
	r.Start.Task = &app.Task{Title: "Task", Body: "prompt"}
	owned := cloneRequest(r)
	owned.Start.Task.Body = "changed"
	owned.Start.Repo = "changed"
	if r.Start.Task.Body != "prompt" || r.Start.Repo != "owner" {
		t.Fatal("start copy aliases original")
	}
	targets, _ := app.FinishTargetsFromSnapshot(herdr.Local(), s)
	r = Request{Finish: targets}
	owned = cloneRequest(r)
	owned.Finish[0].Agent.Session.Value = "changed"
	owned.Finish[0].Workspace.Worktree.CheckoutPath = "changed"
	owned.Finish[0].Machine.Label = "changed"
	if r.Finish[0].Agent.Session.Value != "one" || r.Finish[0].Workspace.Worktree.CheckoutPath != "/repo/one" || r.Finish[0].Machine.Label != "local" {
		t.Fatal("finish copy aliases original")
	}
	if copy := cloneSnapshot(herdr.Snapshot{}); copy.Agents != nil || copy.Workspaces != nil {
		t.Fatal("nil slices changed")
	}
	if copy := cloneSnapshot(herdr.Snapshot{Agents: []herdr.Agent{}, Workspaces: []herdr.Workspace{}}); copy.Agents == nil || copy.Workspaces == nil {
		t.Fatal("empty slices changed")
	}
	if copy := cloneRequest(Request{}); copy.Start != nil || copy.Finish != nil {
		t.Fatal("nil request fields changed")
	}
}

func TestInvalidRoutingCannotMatchDefaultDaemon(t *testing.T) {
	t.Setenv("HERDR_SOCKET_PATH", "")
	_ = os.Unsetenv("HERDR_SOCKET_PATH")
	t.Setenv("HERDR_SESSION", "default")
	d := testDaemon(t, config(), backend(), logger(io.Discard))
	i := d.Inventory()
	t.Setenv("HERDR_SESSION", "..")
	if err := i.CheckConfig(config()); err == nil {
		t.Fatal("invalid session matched default endpoint")
	}
	if _, err := New(config(), backend(), logger(io.Discard)); err == nil {
		t.Fatal("daemon accepted invalid routing")
	}
}

func TestDelayedRefreshCannotPublishIntoRecreatedEntry(t *testing.T) {
	f := backend()
	m := herdr.Machine{ID: "r", Label: "remote", Target: "ssh", Enabled: true}
	f.profiles = []herdr.Machine{m}
	f.snapshots[key(m)] = fixture()
	oldEntered, newEntered := make(chan struct{}), make(chan struct{})
	oldRelease, newRelease := make(chan struct{}), make(chan struct{})
	var calls atomic.Int32
	f.snapshotHook = func(ctx context.Context, host herdr.Machine) error {
		if host.IsLocal() {
			return nil
		}
		var release <-chan struct{}
		switch calls.Add(1) {
		case 1:
			close(oldEntered)
			release = oldRelease
		case 2:
			close(newEntered)
			release = newRelease
		default:
			return nil
		}
		select {
		case <-release:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	d := testDaemon(t, config(), f, logger(io.Discard))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d.refreshProfiles(ctx)
	original := d.machines[key(m)]
	oldDone := make(chan struct{})
	go func() { d.refreshMachine(ctx, m, 0, original); close(oldDone) }()
	<-oldEntered
	f.mu.Lock()
	f.profiles[0].Enabled = false
	f.mu.Unlock()
	d.refreshProfiles(ctx)
	f.mu.Lock()
	f.profiles[0].Enabled = true
	f.snapshots[key(m)] = herdr.Snapshot{Agents: []herdr.Agent{}, Workspaces: []herdr.Workspace{}}
	f.mu.Unlock()
	d.refreshProfiles(ctx)
	replacement := d.machines[key(m)]
	if replacement == original {
		t.Fatal("test did not recreate entry")
	}
	d.schedule(ctx, false)
	<-newEntered
	close(oldRelease)
	<-oldDone
	d.mu.Lock()
	refreshing, updated := replacement.refreshing, replacement.Updated
	d.mu.Unlock()
	if !refreshing || !updated.IsZero() {
		t.Fatal("obsolete completion modified replacement entry")
	}
	close(newRelease)
	d.wg.Wait()
	i := d.Inventory()
	if i.Machines[1].Updated.IsZero() || len(i.Machines[1].Snapshot.Agents) != 0 {
		t.Fatal("new refresh lost", i)
	}
}
