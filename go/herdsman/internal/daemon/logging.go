package daemon

import (
	"context"
	"log/slog"

	"github.com/brucenunk/home-config/go/herdsman/internal/app"
	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
)

// Log confirmed mutation steps without response payloads or prompt content.
// Read-only safety checks retain their normal diagnostics in the final error.
type loggedFinisher struct {
	app.Finisher
	logger  *slog.Logger
	request uint64
}

func (f *loggedFinisher) Prompt(ctx context.Context, m herdr.Machine, name, prompt string) error {
	err := f.Finisher.Prompt(ctx, m, name, prompt)
	if err == nil {
		f.logger.Info("quit submitted", "request", f.request, "machine", m.DisplayName(), "agent", name)
	}
	return err
}
func (f *loggedFinisher) RemoveWorktree(ctx context.Context, m herdr.Machine, id, path string) error {
	err := f.Finisher.RemoveWorktree(ctx, m, id, path)
	if err == nil {
		f.logger.Info("worktree removed", "request", f.request, "machine", m.DisplayName(), "workspace", id, "path", path)
	}
	return err
}
func (f *loggedFinisher) CloseWorkspace(ctx context.Context, m herdr.Machine, id string) error {
	err := f.Finisher.CloseWorkspace(ctx, m, id)
	if err == nil {
		f.logger.Info("workspace closed", "request", f.request, "machine", m.DisplayName(), "workspace", id)
	}
	return err
}
