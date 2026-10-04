package daemon

import (
	"slices"

	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
)

func cloneAgent(a herdr.Agent) herdr.Agent {
	if a.Session != nil {
		session := *a.Session
		a.Session = &session
	}
	return a
}
func cloneWorkspace(w herdr.Workspace) herdr.Workspace {
	if w.Worktree != nil {
		worktree := *w.Worktree
		w.Worktree = &worktree
	}
	return w
}
func cloneSnapshot(snapshot herdr.Snapshot) herdr.Snapshot {
	snapshot.Agents = slices.Clone(snapshot.Agents)
	for i := range snapshot.Agents {
		snapshot.Agents[i] = cloneAgent(snapshot.Agents[i])
	}
	snapshot.Workspaces = slices.Clone(snapshot.Workspaces)
	for i := range snapshot.Workspaces {
		snapshot.Workspaces[i] = cloneWorkspace(snapshot.Workspaces[i])
	}
	return snapshot
}
func cloneRequest(r Request) Request {
	if r.Start != nil {
		start := *r.Start
		if start.Task != nil {
			task := *start.Task
			start.Task = &task
		}
		r.Start = &start
	}
	r.Finish = slices.Clone(r.Finish)
	for i := range r.Finish {
		r.Finish[i].Agent = cloneAgent(r.Finish[i].Agent)
		r.Finish[i].Workspace = cloneWorkspace(r.Finish[i].Workspace)
	}
	return r
}
