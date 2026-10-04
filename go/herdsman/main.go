package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/brucenunk/home-config/go/herdsman/internal/app"
	"github.com/brucenunk/home-config/go/herdsman/internal/daemon"
	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
	"github.com/brucenunk/home-config/go/herdsman/internal/tui"
	tea "github.com/charmbracelet/bubbletea"
)

const usage = "usage: herdsman [--config PATH]\n       herdsman daemon [--config PATH] [--debug]\n\nWithout a subcommand, choose Start session or End session interactively.\nExecution is queued in the managed daemon; inspect its logs for results."

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run() error {
	command, args := "", os.Args[1:]
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		command, args = args[0], args[1:]
		if command != "daemon" {
			return fmt.Errorf("unknown command %q; use herdsman for the selection UI or herdsman daemon", command)
		}
	}
	fs := flag.NewFlagSet("herdsman", flag.ContinueOnError)
	fs.Usage = func() { fmt.Fprintln(fs.Output(), usage) }
	configPath := fs.String("config", "", "configuration file (default: user config directory/herdsman/config.toml)")
	var debug *bool
	if command == "daemon" {
		debug = fs.Bool("debug", false, "log sanitized Herdr/SSH arguments and subprocess timings")
	}
	if err := fs.Parse(args); err != nil {
		if err == flag.ErrHelp {
			return nil
		}
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("herdsman takes no positional arguments")
	}
	if *configPath == "" {
		path, err := app.DefaultConfigPath()
		if err != nil {
			return err
		}
		*configPath = path
	}
	c, err := app.LoadConfig(*configPath)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	socket, err := daemon.SocketPath()
	if err != nil {
		return err
	}
	if command == "daemon" {
		client := herdr.New()
		client.RedactErrors = true
		if *debug {
			client.Debug = log.New(os.Stderr, "herdsman debug: ", log.LstdFlags|log.Lmicroseconds)
		}
		logger := slog.New(slog.NewJSONHandler(os.Stderr, nil))
		d, err := daemon.New(c, client, logger)
		if err != nil {
			return err
		}
		return d.Serve(ctx, socket)
	}
	themeDir := filepath.Join(filepath.Dir(*configPath), "themes")
	initial, err := tui.NewCommand(c, themeDir)
	if err != nil {
		return err
	}
	model, err := tea.NewProgram(initial, tea.WithContext(ctx)).Run()
	if err != nil {
		return err
	}
	command = model.(tui.CommandModel).Command
	if command == "" {
		fmt.Println("Cancelled; no request queued.")
		return nil
	}
	client := daemon.NewClient(socket)
	defer client.Close()
	inventory, err := client.Inventory(ctx)
	if err != nil {
		return err
	}
	if err := inventory.CheckConfig(c); err != nil {
		return err
	}
	// Cache reads do not call Herdr. Keep warnings in the visible picker rather
	// than scrolling them above a full-height Bubble Tea frame.
	interval, _ := c.Daemon.RefreshEvery()
	warnings := inventoryWarnings(inventory, time.Now(), interval)
	notice := func(now time.Time) (string, bool) { return inventoryStatus(inventory, now, interval) }
	request := daemon.Request{ConfigID: inventory.ConfigID, LocalEndpoint: inventory.LocalEndpoint}
	if command == "finish" {
		targets := inventory.FinishTargets()
		if len(targets) == 0 {
			for _, warning := range warnings {
				fmt.Println(warning)
			}
			if len(warnings) > 0 {
				fmt.Println("No eligible sessions in the available cache. Inventory is incomplete or stale; reopen Herdsman after refresh, or inspect daemon logs.")
			} else {
				fmt.Println("No eligible sessions to end.")
			}
			return nil
		}
		picker, err := tui.NewFinish(c, targets, themeDir)
		if err != nil {
			return err
		}
		picker.SetInventoryNotice(notice)
		model, err := tea.NewProgram(picker, tea.WithContext(ctx)).Run()
		if err != nil {
			return err
		}
		selected := model.(tui.FinishModel)
		if !selected.Ready {
			fmt.Println("Cancelled; no request queued.")
			return nil
		}
		request.Finish = selected.Targets
	} else {
		if inventory.ProfilesUpdated.IsZero() {
			return fmt.Errorf("machine inventory is still loading or unavailable; reopen Herdsman after refresh, or inspect daemon logs")
		}
		picker, err := tui.New(c, inventory.Profiles, themeDir)
		if err != nil {
			return err
		}
		picker.SetInventoryNotice(notice)
		model, err := tea.NewProgram(picker, tea.WithContext(ctx)).Run()
		if err != nil {
			return err
		}
		selected := model.(tui.Model)
		if !selected.Ready {
			fmt.Println("Cancelled; no request queued.")
			return nil
		}
		request.Start = &selected.Request
	}
	if err := client.Submit(ctx, request); err != nil {
		return submissionError(err)
	}
	if request.Start != nil {
		fmt.Printf("Queued start on %q in %q. Inspect daemon logs for the result.\n", request.Start.Machine.DisplayName(), request.Start.Repo)
	} else {
		fmt.Printf("Queued finish for %d session(s). Inspect daemon logs for the result.\n", len(request.Finish))
	}
	return nil
}

func inventoryWarnings(i daemon.Inventory, now time.Time, interval time.Duration) []string {
	var warnings []string
	describe := func(name string, updated time.Time, err string) {
		if updated.IsZero() {
			warnings = append(warnings, fmt.Sprintf("Inventory %q: loading or unavailable (no successful refresh yet).", name))
		} else if err != "" || now.Sub(updated) > 2*interval {
			warnings = append(warnings, fmt.Sprintf("Inventory %q: stale (last successful refresh %s); selections will be revalidated.", name, updated.Format(time.RFC3339)))
		}
		if err != "" {
			warnings = append(warnings, fmt.Sprintf("Inventory %q refresh error: %q", name, err))
		}
	}
	describe("machine profiles", i.ProfilesUpdated, i.ProfilesError)
	for _, m := range i.Machines {
		describe(m.Machine.DisplayName(), m.Updated, m.Error)
	}
	return warnings
}

func submissionError(err error) error {
	var rejection *daemon.Rejection
	if errors.As(err, &rejection) {
		return fmt.Errorf("request rejected; nothing queued: %w", err)
	}
	return fmt.Errorf("queue acknowledgement not received; request may have been accepted—inspect daemon logs before resubmitting: %w", err)
}
