package app

import (
	"strings"

	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
)

// The label is a discoverable convention, not a security or ownership token.
// Renamed sessions must be closed manually; no extra lookup or registry is used.
func ownerSessionLabel(owner, agent string) string {
	return "herdsman: " + agent + " · " + owner
}

func ownerSessionWorkspace(w herdr.Workspace, agent string) bool {
	_, ok := ownerFromSessionLabel(w.Label, agent)
	return ok && w.Worktree == nil && w.PaneCount == 1 && w.TabCount == 1
}

// Keep recognizing already-running sessions created before descriptions were
// introduced. New labels put the human description before the unchanged marker.
func ownerFromSessionLabel(label, agent string) (string, bool) {
	prefix := "herdsman: " + agent + " · "
	owner, ok := strings.CutPrefix(label, prefix)
	if !ok || !validOwner(owner) {
		ok = false
		separator := " · " + prefix
		if i := strings.LastIndex(label, separator); i > 0 {
			owner, ok = label[i+len(separator):], true
		}
	}
	return owner, ok && agentName.MatchString(agent) && validOwner(owner)
}
