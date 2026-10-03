package app

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
)

type Finisher interface {
	Snapshot(context.Context, herdr.Machine) (herdr.Snapshot, error)
	Prompt(context.Context, herdr.Machine, string, string) error
	WaitForQuit(context.Context, herdr.Machine, string) error
	RemoveWorktree(context.Context, herdr.Machine, string, string) error
	CloseWorkspace(context.Context, herdr.Machine, string) error
}

type FinishTarget struct {
	Machine   herdr.Machine
	Agent     herdr.Agent
	Workspace herdr.Workspace
}

func (t FinishTarget) OwnerSession() bool {
	return ownerSessionWorkspace(t.Workspace, t.Agent.Name)
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
	snapshot, err := finishSnapshot(ctx, client, m)
	if err != nil {
		return nil, err
	}
	agents, workspaces := snapshot.Agents, snapshot.Workspaces
	paths := workspacePaths(workspaces)
	names, occupants, workspaceOccupants := map[string]int{}, map[string]int{}, map[string]int{}
	labels, ids := map[string]int{}, map[string]int{}
	for _, w := range workspaces {
		labels[w.Label]++
		ids[w.ID]++
	}
	for _, a := range agents {
		names[a.Name]++
		occupants[paths[a.WorkspaceID]]++
		workspaceOccupants[a.WorkspaceID]++
	}
	var targets []FinishTarget
	for _, w := range workspaces {
		if w.ID == "" || w.Label == "" {
			continue
		}
		for _, a := range agents {
			worktree := w.Worktree != nil && w.Worktree.Linked && w.Worktree.CheckoutPath != "" && occupants[w.Worktree.CheckoutPath] == 1
			owner := ownerSessionWorkspace(w, a.Name) && workspaceOccupants[w.ID] == 1 && labels[w.Label] == 1 && ids[w.ID] == 1
			if (worktree || owner) && a.WorkspaceID == w.ID && a.Name != "" && a.PaneID != "" && a.Session != nil && a.Session.Kind != "" && a.Session.Value != "" && names[a.Name] == 1 && a.Kind == "pi" && (a.Status == "idle" || a.Status == "done") {
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

// Selection authorizes /quit without a pre-quit recheck. Finish never retries a
// mutation. Exit confirmation (wait plus snapshots) has one deadline, separate
// from removal, so a slow shutdown cannot consume the removal timeout.
func Finish(ctx context.Context, client Finisher, target FinishTarget) error {
	if !target.OwnerSession() && (target.Workspace.Worktree == nil || !target.Workspace.Worktree.Linked || target.Workspace.Worktree.CheckoutPath == "") {
		return fmt.Errorf("ineligible session; no changes made")
	}
	if err := client.Prompt(ctx, target.Machine, target.Agent.Name, "/quit"); err != nil {
		return fmt.Errorf("could not confirm /quit; state is uncertain, no removal attempted; inspect Herdr before retrying: %w", err)
	}
	waitCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	err := confirmQuit(waitCtx, client, target)
	cancel()
	if err != nil {
		return fmt.Errorf("after /quit; state is uncertain, no removal attempted; inspect Herdr before retrying: %w", err)
	}
	if target.OwnerSession() {
		if err := client.CloseWorkspace(ctx, target.Machine, target.Workspace.ID); err != nil {
			return fmt.Errorf("could not confirm workspace closure; state is uncertain, closure was not retried; directory contents retained; inspect Herdr: %w", err)
		}
		return nil
	}
	if err := client.RemoveWorktree(ctx, target.Machine, target.Workspace.ID, target.Workspace.Worktree.CheckoutPath); err != nil {
		return fmt.Errorf("could not confirm removal; state is uncertain, removal was not retried; inspect Herdr: %w", err)
	}
	return nil
}

func confirmQuit(ctx context.Context, client Finisher, target FinishTarget) error {
	if err := client.WaitForQuit(ctx, target.Machine, target.Agent.PaneID); err != nil {
		return err
	}
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		snapshot, err := finishSnapshot(ctx, client, target.Machine)
		if err != nil {
			return fmt.Errorf("recheck workspace and agents: %w", err)
		}
		present, err := originalStillPresent(snapshot, target)
		if err != nil {
			return err
		}
		if !present {
			return ctx.Err()
		}
		// Lifecycle release can precede process/inventory disappearance. Retry
		// reads for the original session or its identity-drained record only.
		timer := time.NewTimer(100 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return fmt.Errorf("selected agent still present after /quit: %w", ctx.Err())
		case <-timer.C:
		}
	}
}

func originalStillPresent(snapshot herdr.Snapshot, target FinishTarget) (bool, error) {
	workspaces, agents := snapshot.Workspaces, snapshot.Agents
	owner := target.OwnerSession()
	valid := false
	matches := 0
	for _, w := range workspaces {
		if w.ID == target.Workspace.ID {
			matches++
			if matches > 1 {
				return false, fmt.Errorf("ambiguous workspace after /quit")
			}
			if owner {
				valid = w.Label == target.Workspace.Label && ownerSessionWorkspace(w, target.Agent.Name)
			} else {
				valid = w.Worktree != nil && w.Worktree.Linked && w.Worktree.CheckoutPath == target.Workspace.Worktree.CheckoutPath
			}
		}
	}
	if !valid {
		return false, fmt.Errorf("workspace or checkout changed after /quit")
	}
	paths := workspacePaths(workspaces)
	present := false
	for _, a := range agents {
		sameCheckout := !owner && paths[a.WorkspaceID] == target.Workspace.Worktree.CheckoutPath
		if a.WorkspaceID == target.Workspace.ID || sameCheckout || a.Name == target.Agent.Name || a.PaneID == target.Agent.PaneID {
			if present {
				return false, fmt.Errorf("additional checkout occupant after /quit")
			}
			// Herdr can clear the kind/session before dropping the named agent
			// record. This permits another read, never removal of an occupant.
			draining := a.Name == target.Agent.Name && a.PaneID == target.Agent.PaneID && a.WorkspaceID == target.Agent.WorkspaceID && a.Kind == "" && a.Session == nil
			if !draining {
				if changed := agentIdentityChanges(a, target.Agent); len(changed) > 0 {
					return false, fmt.Errorf("agent identity changed after /quit: %s", strings.Join(changed, ", "))
				}
			}
			present = true
		}
	}
	return present, nil
}

func agentIdentityChanges(a, selected herdr.Agent) []string {
	var changed []string
	if a.Name != selected.Name {
		changed = append(changed, "name")
	}
	if a.Kind != selected.Kind {
		changed = append(changed, "kind")
	}
	if a.PaneID != selected.PaneID {
		changed = append(changed, "pane")
	}
	if a.WorkspaceID != selected.WorkspaceID {
		changed = append(changed, "workspace")
	}
	if a.Session == nil || selected.Session == nil {
		changed = append(changed, "missing session reference")
	} else if *a.Session != *selected.Session {
		changed = append(changed, "session reference")
	}
	return changed
}

func finishSnapshot(ctx context.Context, client Finisher, m herdr.Machine) (herdr.Snapshot, error) {
	snapshot, err := client.Snapshot(ctx, m)
	if err != nil {
		return snapshot, err
	}
	for _, a := range snapshot.Agents {
		if a.WorkspaceID == "" || a.PaneID == "" || a.Status == "" {
			return snapshot, fmt.Errorf("incomplete agent inventory")
		}
	}
	return snapshot, nil
}
