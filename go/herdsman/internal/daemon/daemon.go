// Package daemon owns cached discovery and serial background execution.
package daemon

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"log/slog"
	"slices"
	"sort"
	"sync"
	"time"

	"github.com/brucenunk/home-config/go/herdsman/internal/app"
	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
)

type Backend interface {
	app.Launcher
	app.Finisher
	Machines(context.Context) ([]herdr.Machine, error)
}

type MachineState struct {
	Machine  herdr.Machine
	Snapshot herdr.Snapshot
	Updated  time.Time
	Error    string
}

type Inventory struct {
	LocalEndpoint   string
	ConfigID        string
	Profiles        []herdr.Machine
	ProfilesUpdated time.Time
	ProfilesError   string
	Machines        []MachineState
}

func ConfigID(c app.Config) string {
	data, _ := json.Marshal(c)
	return fmt.Sprintf("%x", sha256.Sum256(data))
}

type Request struct {
	LocalEndpoint string
	ConfigID      string
	Start         *app.StartRequest
	Finish        []app.FinishTarget
}

type queued struct {
	id      uint64
	request Request
}
type entry struct {
	MachineState
	generation                  uint64
	dirty, refreshing, mutating bool
}

type Daemon struct {
	interval           time.Duration
	endpoint           string
	config             app.Config
	backend            Backend
	logger             *slog.Logger
	mu                 sync.Mutex
	profiles           []herdr.Machine
	profilesUpdated    time.Time
	profilesError      string
	profilesRefreshing bool
	machines           map[string]*entry
	queue              chan queued
	nextID             uint64
	accepting          bool
	wake               chan struct{}
	slots              chan struct{}
	wg                 sync.WaitGroup
}

func key(m herdr.Machine) string {
	if m.IsLocal() {
		return "local"
	}
	return "remote:" + m.ID
}

func New(c app.Config, backend Backend, logger *slog.Logger) (*Daemon, error) {
	if err := c.Daemon.Validate(); err != nil {
		return nil, err
	}
	interval, _ := c.Daemon.RefreshEvery()
	d := &Daemon{config: c, interval: interval, backend: backend, logger: logger, machines: make(map[string]*entry), queue: make(chan queued, c.Daemon.QueueCapacity), wake: make(chan struct{}, 1), slots: make(chan struct{}, c.Daemon.RefreshConcurrency)}
	endpoint, err := herdr.LocalEndpoint()
	if err != nil {
		return nil, err
	}
	d.endpoint = endpoint
	d.machines[key(herdr.Local())] = &entry{MachineState: MachineState{Machine: herdr.Local()}, dirty: true}
	return d, nil
}

func (d *Daemon) signal() {
	select {
	case d.wake <- struct{}{}:
	default:
	}
}

// Inventory copies slices under the short cache lock, then deep-copies their
// immutable contents outside it. No serialization is needed for ownership.
// Snapshots are immutable after publication; no network call holds this lock.
func (d *Daemon) Inventory() Inventory {
	d.mu.Lock()
	result := Inventory{ConfigID: ConfigID(d.config), Profiles: slices.Clone(d.profiles), ProfilesUpdated: d.profilesUpdated, ProfilesError: d.profilesError}
	result.LocalEndpoint = d.endpoint
	for _, e := range d.machines {
		result.Machines = append(result.Machines, e.MachineState)
	}
	d.mu.Unlock()
	for index := range result.Machines {
		result.Machines[index].Snapshot = cloneSnapshot(result.Machines[index].Snapshot)
	}
	sort.Slice(result.Machines, func(i, j int) bool { return key(result.Machines[i].Machine) < key(result.Machines[j].Machine) })
	return result
}

// Submit never waits for execution or invokes Herdr. The HTTP boundary bounds
// payload size; validation here also protects in-process callers.
func (d *Daemon) Submit(r Request) error {
	if r.LocalEndpoint != d.endpoint {
		return fmt.Errorf("local Herdr routing differs from daemon; nothing queued")
	}
	if r.ConfigID != ConfigID(d.config) {
		return fmt.Errorf("configuration differs from daemon; restart the managed service after updating configuration")
	}
	if (r.Start == nil) == (len(r.Finish) == 0) {
		return fmt.Errorf("submit exactly one start or a non-empty finish batch")
	}
	if r.Start != nil {
		if err := d.config.ValidateChoices(*r.Start); err != nil {
			return err
		}
		if len(d.config.Destinations(r.Start.Repo, []herdr.Machine{r.Start.Machine})) == 0 {
			return fmt.Errorf("invalid context/machine selection")
		}
		if r.Start.Task != nil {
			if err := r.Start.Task.ValidateTransport(); err != nil {
				return err
			}
		} else if err := app.ValidateSessionDescription(r.Start.Description); err != nil {
			return err
		}
	} else {
		seen := map[string]bool{}
		for _, t := range r.Finish {
			id := key(t.Machine) + ":" + t.Agent.Name
			if t.Agent.Name == "" || t.Workspace.ID == "" || t.Agent.PaneID == "" || seen[id] {
				return fmt.Errorf("invalid or duplicate finish selection")
			}
			seen[id] = true
		}
	}
	owned := cloneRequest(r)
	d.mu.Lock()
	defer d.mu.Unlock()
	if !d.accepting {
		return fmt.Errorf("daemon is shutting down or not ready")
	}
	d.nextID++
	job := queued{d.nextID, owned}
	select {
	case d.queue <- job:
		d.logger.Info("request accepted", "request", job.id, "operation", operation(r), "pending", len(d.queue))
		if r.Start != nil {
			title := r.Start.Description
			if r.Start.Task != nil {
				title = r.Start.Task.Title
			}
			d.logger.Info("start selection", "request", job.id, "machine", r.Start.Machine.DisplayName(), "context", r.Start.Repo, "title", title)
		} else {
			for _, t := range r.Finish {
				d.logger.Info("finish selection", "request", job.id, "machine", t.Machine.DisplayName(), "agent", t.Agent.Name, "workspace", t.Workspace.ID)
			}
		}
		return nil
	default:
		return fmt.Errorf("request queue is full; nothing queued")
	}
}

func operation(r Request) string {
	if r.Start != nil {
		return "start"
	}
	return "finish"
}

// Run starts all background loops and blocks until cancellation. No accepted
// request inherits the socket client's lifetime, and no work is replayed.
func (d *Daemon) Run(ctx context.Context) {
	d.mu.Lock()
	d.accepting = true
	d.mu.Unlock()
	d.logger.Info("daemon started", "refresh_interval", d.interval.String(), "queue_capacity", cap(d.queue), "refresh_concurrency", cap(d.slots))
	d.wg.Add(1)
	go func() { defer d.wg.Done(); d.worker(ctx) }()
	ticker := time.NewTicker(d.interval)
	defer ticker.Stop()
	d.schedule(ctx, true)
	for {
		select {
		case <-ctx.Done():
			d.mu.Lock()
			d.accepting = false
			d.mu.Unlock()
			d.wg.Wait()
			discarded := 0
			for {
				select {
				case job := <-d.queue:
					discarded++
					d.logger.Warn("request discarded on shutdown", "request", job.id, "operation", operation(job.request))
				default:
					d.logger.Info("daemon stopped", "discarded", discarded)
					return
				}
			}
		case <-ticker.C:
			d.schedule(ctx, true)
		case <-d.wake:
			d.schedule(ctx, false)
		}
	}
}

func (d *Daemon) schedule(ctx context.Context, periodic bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if periodic && !d.profilesRefreshing {
		d.profilesRefreshing = true
		d.wg.Add(1)
		go func() { defer d.wg.Done(); d.refreshProfiles(ctx) }()
	}
	for _, e := range d.machines {
		if periodic {
			e.dirty = true
		}
		if !e.dirty || e.refreshing || e.mutating {
			continue
		}
		e.dirty = false
		e.refreshing = true
		generation, m := e.generation, e.Machine
		d.wg.Add(1)
		go func() { defer d.wg.Done(); d.refreshMachine(ctx, m, generation, e) }()
	}
}

func (d *Daemon) refreshProfiles(ctx context.Context) {
	profiles, err := d.backend.Machines(ctx)
	d.mu.Lock()
	defer d.mu.Unlock()
	d.profilesRefreshing = false
	if ctx.Err() != nil {
		return
	}
	message := ""
	if err != nil {
		message = err.Error()
	}
	d.logRefresh("profiles", d.profilesError, message)
	d.profilesError = message
	if err != nil {
		return
	}
	d.profiles = profiles
	d.profilesUpdated = time.Now()
	enabled := map[string]bool{key(herdr.Local()): true}
	for _, m := range profiles {
		if !m.Enabled {
			continue
		}
		k := key(m)
		enabled[k] = true
		e := d.machines[k]
		if e == nil || e.Machine != m {
			d.machines[k] = &entry{MachineState: MachineState{Machine: m}, dirty: true}
		}
	}
	for k := range d.machines {
		if !enabled[k] {
			delete(d.machines, k)
		}
	}
	d.signal()
}

func (d *Daemon) refreshMachine(ctx context.Context, m herdr.Machine, generation uint64, expected *entry) {
	select {
	case d.slots <- struct{}{}:
	case <-ctx.Done():
		return
	}
	snapshot, err := d.backend.Snapshot(ctx, m)
	if err == nil {
		_, err = app.FinishTargetsFromSnapshot(m, snapshot)
	}
	<-d.slots
	d.mu.Lock()
	defer d.mu.Unlock()
	e := d.machines[key(m)]
	if e != expected || e == nil || e.Machine != m {
		return
	}
	e.refreshing = false
	if ctx.Err() != nil {
		return
	}
	if e.generation != generation {
		e.dirty = true
		d.signal()
		return
	}
	message := ""
	if err != nil {
		message = err.Error()
	}
	d.logRefresh(m.DisplayName(), e.Error, message)
	e.Error = message
	if err == nil {
		e.Snapshot = snapshot
		e.Updated = time.Now()
	}
	d.signal()
}

func (d *Daemon) logRefresh(machine, old, current string) {
	if current == old {
		return
	}
	if current != "" {
		d.logger.Warn("inventory refresh failed", "machine", machine, "error", current)
	} else {
		d.logger.Info("inventory refresh recovered", "machine", machine)
	}
}

func (d *Daemon) mutation(m herdr.Machine, active bool) {
	d.mu.Lock()
	if e := d.machines[key(m)]; e != nil {
		e.generation++
		e.mutating = active
		e.dirty = true
	}
	d.mu.Unlock()
	d.signal()
}

func (d *Daemon) worker(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case job := <-d.queue:
			if ctx.Err() != nil {
				d.logger.Warn("request discarded on shutdown", "request", job.id)
				return
			}
			start := time.Now()
			d.logger.Info("request started", "request", job.id, "operation", operation(job.request))
			err := d.execute(ctx, job)
			if err != nil {
				d.logger.Error("request failed", "request", job.id, "elapsed", time.Since(start), "error", err.Error(), "recovery", "inspect Herdr before submitting another request; no automatic retries or cleanup")
			} else {
				d.logger.Info("request succeeded", "request", job.id, "elapsed", time.Since(start))
			}
		}
	}
}

// Resolve against fresh Herdr-owned profiles, not client-supplied SSH targets.
func resolve(selected herdr.Machine, profiles []herdr.Machine) (herdr.Machine, error) {
	if selected.IsLocal() {
		return herdr.Local(), nil
	}
	for _, m := range profiles {
		if m.Enabled && m.ID == selected.ID && m.Label == selected.Label && m.Target == selected.Target && m.Session == selected.Session {
			return m, nil
		}
	}
	return herdr.Machine{}, fmt.Errorf("selected machine changed or is disabled; no changes made; select again")
}

func (d *Daemon) execute(ctx context.Context, job queued) error {
	r := job.request
	if r.Start != nil {
		profiles, err := d.backend.Machines(ctx)
		if err != nil {
			return fmt.Errorf("revalidate machine profiles: %w", err)
		}
		m, err := resolve(r.Start.Machine, profiles)
		if err != nil {
			return err
		}
		r.Start.Machine = m
		d.mutation(m, true)
		defer d.mutation(m, false)
		result, err := app.Start(ctx, d.config, d.backend, profiles, *r.Start)
		d.logger.Info("start execution result", "request", job.id, "machine", result.Machine, "context", result.Repo, "title", result.Title, "agent", result.AgentName, "path", result.Path, "branch", result.Branch, "workspace", result.Workspace, "steps", result.Steps)
		return err
	}
	for i, t := range r.Finish {
		if err := ctx.Err(); err != nil {
			return fmt.Errorf("%d completed, %d unattempted: %w", i, len(r.Finish)-i, err)
		}
		// Earlier cleanups may take tens of seconds; profiles are Herdr-owned
		// and must be checked again immediately before each target.
		profiles, profileErr := d.backend.Machines(ctx)
		m, err := resolve(t.Machine, profiles)
		if profileErr != nil {
			err = fmt.Errorf("revalidate machine profiles: %w", profileErr)
		}
		if err == nil {
			t.Machine = m
			d.mutation(m, true)
			err = app.RevalidateFinish(ctx, d.backend, t)
			if err == nil {
				err = app.Finish(ctx, &loggedFinisher{Finisher: d.backend, logger: d.logger, request: job.id}, t)
			}
			d.mutation(m, false)
		}
		if err != nil {
			for _, remaining := range r.Finish[i+1:] {
				d.logger.Warn("session unattempted", "request", job.id, "machine", remaining.Machine.DisplayName(), "agent", remaining.Agent.Name, "workspace", remaining.Workspace.ID)
			}
			return fmt.Errorf("finish %q on %q: %d completed, %d unattempted: %w", t.Agent.Name, t.Machine.DisplayName(), i, len(r.Finish)-i-1, err)
		}
		d.logger.Info("session ended", "request", job.id, "machine", m.DisplayName(), "agent", t.Agent.Name, "workspace", t.Workspace.ID, "label", t.Workspace.Label, "ordinary_session", t.OrdinarySession())
	}
	return nil
}

// CheckConfig prevents a UI using a different managed or --config inventory.
func (i Inventory) CheckConfig(c app.Config) error {
	endpoint, err := herdr.LocalEndpoint()
	if err != nil {
		return err
	}
	if i.LocalEndpoint != endpoint {
		return fmt.Errorf("local Herdr routing differs from daemon; use the matching Herdr session/socket or configure the managed service; no request queued")
	}
	if i.ConfigID != ConfigID(c) {
		return fmt.Errorf("configuration differs from daemon; use its configuration or restart the managed service")
	}
	return nil
}

// FinishTargets exposes successful cached inventories, with stale/error state
// reported separately by the UI. Execution always revalidates selections.
func (i Inventory) FinishTargets() []app.FinishTarget {
	var targets []app.FinishTarget
	for _, m := range i.Machines {
		if m.Updated.IsZero() {
			continue
		}
		found, err := app.FinishTargetsFromSnapshot(m.Machine, m.Snapshot)
		if err == nil {
			targets = append(targets, found...)
		}
	}
	sort.SliceStable(targets, func(a, b int) bool { return targets[a].Workspace.Label < targets[b].Workspace.Label })
	return targets
}
