package app

import (
	"context"
	"fmt"
	"sort"
	"time"

	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
)

type Finisher interface {
	Agents(context.Context, herdr.Machine) ([]herdr.Agent, error)
	Workspaces(context.Context, herdr.Machine) ([]herdr.Workspace, error)
	Prompt(context.Context, herdr.Machine, string, string) error
	RemoveWorktree(context.Context, herdr.Machine, string, string) error
}

type FinishTarget struct {
	Machine   herdr.Machine
	Agent     herdr.Agent
	Workspace herdr.Workspace
}

// FinishTargets is a read-only snapshot. Checkouts used by multiple agents are
// excluded because forced removal would also delete their working files.
func FinishTargets(ctx context.Context, client Finisher, profiles []herdr.Machine) ([]FinishTarget, error) {
	hosts := []herdr.Machine{herdr.Local()}
	for _, m := range profiles {
		if m.Enabled {
			hosts = append(hosts, m)
		}
	}
	var targets []FinishTarget
	for _, m := range hosts {
		found, err := finishTargetsOn(ctx, client, m)
		if err != nil {
			return nil, fmt.Errorf("inspect %s; no changes made: %w", m.DisplayName(), err)
		}
		targets = append(targets, found...)
	}
	sort.SliceStable(targets, func(i, j int) bool { return targets[i].Workspace.Label < targets[j].Workspace.Label })
	return targets, nil
}

func finishTargetsOn(ctx context.Context, client Finisher, m herdr.Machine) ([]FinishTarget, error) {
	agents, err := finishAgents(ctx, client, m)
	if err != nil {
		return nil, err
	}
	workspaces, err := client.Workspaces(ctx, m)
	if err != nil {
		return nil, err
	}
	paths := workspacePaths(workspaces)
	names, occupants := map[string]int{}, map[string]int{}
	for _, a := range agents {
		names[a.Name]++
		occupants[paths[a.WorkspaceID]]++
	}
	var targets []FinishTarget
	for _, w := range workspaces {
		if w.ID == "" || w.Label == "" || w.Worktree == nil || !w.Worktree.Linked || w.Worktree.CheckoutPath == "" {
			continue
		}
		for _, a := range agents {
			if a.WorkspaceID == w.ID && a.Name != "" && a.PaneID != "" && a.Session != nil && a.Session.Kind != "" && a.Session.Value != "" && names[a.Name] == 1 && occupants[w.Worktree.CheckoutPath] == 1 && a.Kind == "pi" && (a.Status == "idle" || a.Status == "done") {
				targets = append(targets, FinishTarget{m, a, w})
			}
		}
	}
	return targets, nil
}

func workspacePaths(workspaces []herdr.Workspace) map[string]string {
	paths := make(map[string]string, len(workspaces))
	for _, w := range workspaces {
		if w.Worktree != nil {
			paths[w.ID] = w.Worktree.CheckoutPath
		}
	}
	return paths
}

func sameTarget(a, b FinishTarget) bool {
	return a.Agent.Name == b.Agent.Name && a.Agent.PaneID == b.Agent.PaneID && a.Agent.Session != nil && b.Agent.Session != nil && *a.Agent.Session == *b.Agent.Session && a.Workspace.ID == b.Workspace.ID && a.Workspace.Worktree != nil && b.Workspace.Worktree != nil && a.Workspace.Worktree.CheckoutPath == b.Workspace.Worktree.CheckoutPath
}

// Finish never retries a mutation. Polling after /quit is bounded separately
// from the final removal, so a slow quit cannot consume the removal timeout.
func Finish(ctx context.Context, client Finisher, target FinishTarget) error {
	fresh, err := finishTargetsOn(ctx, client, target.Machine)
	if err != nil {
		return fmt.Errorf("recheck session; no changes made: %w", err)
	}
	matched := false
	for _, t := range fresh {
		if sameTarget(t, target) {
			matched = true
		}
	}
	if !matched {
		return fmt.Errorf("selected session changed or is no longer eligible; no changes made")
	}
	if err := client.Prompt(ctx, target.Machine, target.Agent.Name, "/quit"); err != nil {
		return fmt.Errorf("could not confirm /quit; state is uncertain, no removal attempted; inspect Herdr before retrying: %w", err)
	}
	if err := waitForQuit(ctx, client, target); err != nil {
		return fmt.Errorf("after /quit; state is uncertain, no removal attempted; inspect Herdr before retrying: %w", err)
	}
	// Recheck the checkout after quitting: never remove a replacement workspace.
	workspaces, err := client.Workspaces(ctx, target.Machine)
	if err != nil {
		return fmt.Errorf("recheck checkout after /quit; no removal attempted: %w", err)
	}
	valid := false
	for _, w := range workspaces {
		if w.ID == target.Workspace.ID && w.Worktree != nil && w.Worktree.Linked && w.Worktree.CheckoutPath == target.Workspace.Worktree.CheckoutPath {
			valid = true
		}
	}
	if !valid {
		return fmt.Errorf("checkout changed after /quit; no removal attempted")
	}
	agents, err := finishAgents(ctx, client, target.Machine)
	if err != nil {
		return fmt.Errorf("recheck agents after /quit; no removal attempted: %w", err)
	}
	paths := workspacePaths(workspaces)
	for _, a := range agents {
		if a.WorkspaceID == target.Workspace.ID || paths[a.WorkspaceID] == target.Workspace.Worktree.CheckoutPath || a.Name == target.Agent.Name {
			return fmt.Errorf("agent appeared after /quit; no removal attempted")
		}
	}
	if err := client.RemoveWorktree(ctx, target.Machine, target.Workspace.ID, target.Workspace.Worktree.CheckoutPath); err != nil {
		return fmt.Errorf("could not confirm removal; state is uncertain, removal was not retried; inspect Herdr: %w", err)
	}
	return nil
}

func finishAgents(ctx context.Context, client Finisher, m herdr.Machine) ([]herdr.Agent, error) {
	agents, err := client.Agents(ctx, m)
	if err != nil {
		return nil, err
	}
	for _, a := range agents {
		if a.WorkspaceID == "" || a.PaneID == "" || a.Status == "" {
			return nil, fmt.Errorf("incomplete agent inventory")
		}
	}
	return agents, nil
}

func waitForQuit(ctx context.Context, client Finisher, target FinishTarget) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	for {
		agents, err := finishAgents(ctx, client, target.Machine)
		if err != nil {
			return err
		}
		present := false
		for _, a := range agents {
			if a.Name == target.Agent.Name {
				present = true
			} else if a.WorkspaceID == target.Workspace.ID {
				return fmt.Errorf("another agent appeared in the selected workspace")
			}
		}
		if !present {
			return nil
		}
		timer := time.NewTimer(time.Second)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}
