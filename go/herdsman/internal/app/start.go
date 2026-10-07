package app

import (
	"context"
	"fmt"
	"math/rand/v2"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
)

type StartRequest struct {
	BaseRef     string // Final repository branch ref; empty for owner sessions.
	Model       string // Exact catalogue provider/model reference.
	Thinking    string // Supported level for the selected model.
	Repo        string // Selected context: owner or owner/repo.
	Description string // Required without a task file; title only, never a prompt.
	Machine     herdr.Machine
	Task        *Task
}

// The only interface is the launch boundary; implementations do not own policy.
type Launcher interface {
	Home(context.Context, herdr.Machine) (string, error)
	OwnerHome(context.Context, herdr.Machine, string) (string, error)
	Snapshot(context.Context, herdr.Machine) (herdr.Snapshot, error)
	Source(context.Context, herdr.Machine, string) (herdr.Source, error)
	FetchBase(context.Context, herdr.Machine, string, string, string) error
	CreateParent(context.Context, herdr.Machine, string, string) (herdr.Created, error)
	RenameParent(context.Context, herdr.Machine, string, string) error
	CreateWorktree(context.Context, herdr.Machine, herdr.WorktreeRequest) (herdr.Created, error)
	StartAgent(context.Context, herdr.Machine, string, string, string, string, string) error
	Prompt(context.Context, herdr.Machine, string, string) error
	Focus(context.Context, herdr.Machine, string) error
}

type StartResult struct {
	Machine, Repo, AgentName, Title, Path, Branch, Parent, Workspace, Pane string
	Steps                                                                  []string
}

func ChooseAgentName(names []string, occupied map[string]bool) (string, error) {
	for _, i := range rand.Perm(len(names)) {
		if !occupied[names[i]] {
			return names[i], nil
		}
	}
	return "", fmt.Errorf("all configured agent names are unavailable; end an existing session first")
}

func Start(ctx context.Context, c Config, client Launcher, profiles []herdr.Machine, req StartRequest) (r StartResult, err error) {
	r.Machine, r.Repo = req.Machine.DisplayName(), req.Repo
	if err := validateAgentNames(c.AgentNames); err != nil {
		return r, err
	}
	if req.Task != nil {
		if !validRepo(req.Repo) {
			return r, fmt.Errorf("task-file sessions require a repository context")
		}
		if err := req.Task.ValidateTransport(); err != nil {
			return r, err
		}
	} else if err := ValidateSessionDescription(req.Description); err != nil {
		return r, err
	}
	destinations := c.Destinations(req.Repo, profiles)
	i := slices.IndexFunc(destinations, func(m herdr.Machine) bool { return m.Label == req.Machine.Label && m.ID == req.Machine.ID })
	if i < 0 {
		return r, fmt.Errorf("context/machine selection is no longer available")
	}
	m := destinations[i]
	if err := c.ValidateChoices(req); err != nil {
		return r, err
	}
	occupied := map[string]bool{}
	var workspaces []herdr.Workspace
	// Names are globally unique client policy, including saved servers outside our config.
	for _, host := range append([]herdr.Machine{herdr.Local()}, profiles...) {
		if !host.Enabled {
			continue
		}
		snapshot, e := client.Snapshot(ctx, host)
		if e != nil {
			return r, fmt.Errorf("cannot establish agent name availability on %s: %w", host.DisplayName(), e)
		}
		if host.ID == m.ID && host.Label == m.Label {
			workspaces = snapshot.Workspaces
		}
		for _, a := range snapshot.Agents {
			occupied[a.Name] = true
		}
	}
	r.AgentName, err = ChooseAgentName(c.AgentNames, occupied)
	if err != nil {
		return r, err
	}
	r.Title = strings.TrimSpace(req.Description)
	if req.Task != nil {
		r.Title = req.Task.Title
	}
	var home string
	if validOwner(req.Repo) {
		home, err = client.OwnerHome(ctx, m, req.Repo)
	} else {
		home, err = client.Home(ctx, m)
	}
	if err != nil {
		return r, err
	}
	mutating := false
	defer func() {
		if err != nil && mutating {
			err = fmt.Errorf("%w\nLaunch stopped. Successful steps: %s. The failing operation may also have applied; inspect Herdr before retrying. No automatic cleanup was performed.", err, strings.Join(r.Steps, "; "))
		}
	}()
	if validOwner(req.Repo) {
		r.Path = filepath.Join(home, "work", req.Repo)
		if err := ctx.Err(); err != nil {
			return r, err
		}
		mutating = true
		created, e := client.CreateParent(ctx, m, r.Path, r.Title)
		if e != nil {
			return r, fmt.Errorf("create owner session workspace: %w", e)
		}
		r.Workspace, r.Pane = created.Workspace.ID, created.RootPane.ID
		r.Steps = append(r.Steps, "created owner session workspace "+r.Workspace+" at "+r.Path)
	} else {
		repository := c.Machines[m.Label].Repositories[req.Repo]
		base := "refs/heads/" + req.BaseRef
		if strings.Contains(req.BaseRef, "/") {
			base = "refs/remotes/" + req.BaseRef
		}
		source := repository.Path
		stamp := time.Now().UTC().Format("20060102T150405.000000000Z")
		r.Path = filepath.Join(home, "work", req.Repo, stamp)
		r.Branch = "jamesl/" + stamp
		resolved, err := client.Source(ctx, m, source)
		if err != nil {
			return r, fmt.Errorf("resolve parent: %w", err)
		}
		if filepath.Clean(resolved.CheckoutPath) != filepath.Clean(source) {
			return r, fmt.Errorf("Herdr resolved %s to a different source checkout: %s", source, resolved.CheckoutPath)
		}
		var parent *herdr.Workspace
		for _, w := range workspaces {
			matches := (resolved.WorkspaceID != "" && w.ID == resolved.WorkspaceID) || (w.Worktree != nil && !w.Worktree.Linked && filepath.Clean(w.Worktree.CheckoutPath) == source)
			if matches {
				if parent != nil {
					return r, fmt.Errorf("multiple parent workspaces for %s; resolve in Herdr", source)
				}
				copy := w
				parent = &copy
			} else if w.Label == req.Repo {
				return r, fmt.Errorf("workspace label %s is already used by a different checkout", req.Repo)
			}
		}
		if resolved.WorkspaceID != "" && parent == nil {
			return r, fmt.Errorf("source workspace is absent from the selected inventory; select again")
		}
		if remote, branch, ok := strings.Cut(req.BaseRef, "/"); ok {
			if err := client.FetchBase(ctx, m, source, remote, branch); err != nil {
				return r, fmt.Errorf("fetch base %s on %s: %w", req.BaseRef, m.DisplayName(), err)
			}
		}
		if err := ctx.Err(); err != nil {
			return r, err
		}
		// From this point, failures may leave state behind. Never retry or delete it.
		mutating = true
		if parent == nil {
			var created herdr.Created
			created, err = client.CreateParent(ctx, m, source, req.Repo)
			if err != nil {
				return r, fmt.Errorf("create parent: %w", err)
			}
			r.Parent = created.Workspace.ID
			r.Steps = append(r.Steps, "created parent "+r.Parent)
		} else {
			r.Parent = parent.ID
			r.Steps = append(r.Steps, "reused parent "+r.Parent)
			if parent.Label != req.Repo {
				err = client.RenameParent(ctx, m, parent.ID, req.Repo)
				if err != nil {
					return r, fmt.Errorf("rename parent: %w", err)
				}
				r.Steps = append(r.Steps, "renamed parent")
			}
		}
		created, err := client.CreateWorktree(ctx, m, herdr.WorktreeRequest{Parent: r.Parent, Branch: r.Branch, Base: base, Path: r.Path, Label: r.Title})
		if err != nil {
			return r, fmt.Errorf("create worktree: %w", err)
		}
		r.Workspace, r.Pane = created.Workspace.ID, created.RootPane.ID
		r.Steps = append(r.Steps, "created worktree "+r.Path+" ("+r.Workspace+", "+r.Pane+")")
	}
	if err = client.StartAgent(ctx, m, r.AgentName, r.Pane, r.Title, req.Model, req.Thinking); err != nil {
		return r, fmt.Errorf("start Pi %s: %w", r.AgentName, err)
	}
	r.Steps = append(r.Steps, "started Pi "+r.AgentName)
	if req.Task != nil {
		if err = client.Prompt(ctx, m, r.AgentName, req.Task.Prompt()); err != nil {
			return r, fmt.Errorf("submit task prompt: %w", err)
		}
		r.Steps = append(r.Steps, "submitted task prompt")
	}
	if err = client.Focus(ctx, m, r.AgentName); err != nil {
		return r, fmt.Errorf("focus agent: %w", err)
	}
	r.Steps = append(r.Steps, "focused agent")
	return r, nil
}
