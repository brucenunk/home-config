package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/brucenunk/home-config/go/herdsman/internal/app"
	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
	"github.com/brucenunk/home-config/go/herdsman/internal/tui"
	tea "github.com/charmbracelet/bubbletea"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	if len(os.Args) < 2 || os.Args[1] == "--help" || os.Args[1] == "-h" {
		fmt.Println("usage: herdsman start [--config PATH]")
		return nil
	}
	if os.Args[1] != "start" {
		return fmt.Errorf("unknown command %q; usage: herdsman start [--config PATH]", os.Args[1])
	}
	fs := flag.NewFlagSet("start", flag.ContinueOnError)
	configPath := fs.String("config", "", "configuration file (default: user config directory/herdsman/config.toml)")
	if err := fs.Parse(os.Args[2:]); err != nil {
		if err == flag.ErrHelp {
			return nil
		}
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("start takes no positional arguments")
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
	client := herdr.New()
	profiles, err := client.Machines(ctx)
	if err != nil {
		return fmt.Errorf("read Herdr machines: %w", err)
	}
	model, err := tea.NewProgram(tui.New(c, profiles), tea.WithContext(ctx)).Run()
	if err != nil {
		return err
	}
	m := model.(tui.Model)
	if !m.Ready {
		fmt.Println("Cancelled; nothing launched.")
		return nil
	}
	fmt.Printf("Launching on %s in %s…\n", m.Request.Machine.DisplayName(), m.Request.Repo)
	r, err := app.Start(ctx, c, client, m.Request)
	if err != nil {
		if r.Path != "" {
			fmt.Fprintf(os.Stderr, "Launch selection: %s · %s · %s\nPath: %s\nBranch: %s\n", r.Machine, r.Repo, r.AgentName, r.Path, r.Branch)
		}
		return err
	}
	fmt.Printf("Started %s: %s\nMachine: %s\nRepository: %s\nPath: %s\nBranch: %s\n", r.AgentName, r.Title, r.Machine, r.Repo, r.Path, r.Branch)
	if !m.Request.Machine.IsLocal() {
		fmt.Printf("If the client did not switch, select %s → %s in Herdr.\n", r.Machine, r.Title)
	}
	return nil
}
