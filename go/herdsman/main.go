package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
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
	if len(os.Args) >= 2 && (os.Args[1] == "--help" || os.Args[1] == "-h") {
		fmt.Println("usage: herdsman [--config PATH] [--debug]\n       herdsman start [--config PATH] [--debug]\n       herdsman finish [--config PATH] [--debug]\n\nWithout a subcommand, choose Start or Finish interactively.")
		return nil
	}
	command, args := "", os.Args[1:]
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		command, args = args[0], args[1:]
		if command != "start" && command != "finish" {
			return fmt.Errorf("unknown command %q; usage: herdsman [start|finish] [--config PATH] [--debug]", command)
		}
	}
	flagName := command
	if flagName == "" {
		flagName = "herdsman"
	}
	fs := flag.NewFlagSet(flagName, flag.ContinueOnError)
	configPath := fs.String("config", "", "configuration file (default: user config directory/herdsman/config.toml)")
	debug := fs.Bool("debug", false, "log Herdr/SSH calls and subprocess timings to stderr")
	if err := fs.Parse(args); err != nil {
		if err == flag.ErrHelp {
			return nil
		}
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("%s takes no positional arguments", flagName)
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
	themeDir := filepath.Join(filepath.Dir(*configPath), "themes")
	if command == "" {
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
			fmt.Println("Cancelled; nothing started or finished.")
			return nil
		}
	}
	client := herdr.New()
	if *debug {
		client.Debug = log.New(os.Stderr, "herdsman debug: ", log.LstdFlags|log.Lmicroseconds)
	}
	profiles, err := client.Machines(ctx)
	if err != nil {
		return fmt.Errorf("read Herdr machines: %w", err)
	}
	if command == "finish" {
		return runFinish(ctx, c, client, profiles, themeDir)
	}
	initial, err := tui.New(c, profiles, themeDir)
	if err != nil {
		return err
	}
	model, err := tea.NewProgram(initial, tea.WithContext(ctx)).Run()
	if err != nil {
		return err
	}
	m := model.(tui.Model)
	if !m.Ready {
		fmt.Println("Cancelled; nothing launched.")
		return nil
	}
	fmt.Printf("Launching on %s in %s…\n", m.Request.Machine.DisplayName(), m.Request.Repo)
	r, err := app.Start(ctx, c, client, profiles, m.Request)
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

func runFinish(ctx context.Context, c app.Config, client *herdr.Client, profiles []herdr.Machine, themeDir string) error {
	targets, err := app.FinishTargets(ctx, client, profiles)
	if err != nil {
		return err
	}
	if len(targets) == 0 {
		fmt.Println("No eligible sessions to finish (requires idle/done Pi in a linked-worktree workspace).")
		return nil
	}
	initial, err := tui.NewFinish(c, targets, themeDir)
	if err != nil {
		return err
	}
	model, err := tea.NewProgram(initial, tea.WithContext(ctx)).Run()
	if err != nil {
		return err
	}
	m := model.(tui.FinishModel)
	if !m.Ready {
		fmt.Println("Cancelled; nothing finished.")
		return nil
	}
	if err := app.Finish(ctx, client, m.Target); err != nil {
		return fmt.Errorf("finish %q on %q: %w", m.Target.Agent.Name, m.Target.Machine.DisplayName(), err)
	}
	fmt.Print(finishSummary(m.Target))
	return nil
}

func finishSummary(target app.FinishTarget) string {
	return fmt.Sprintf("Finished %q on %q; removed %q at %q\nBranch and saved Pi transcript retained.\n", target.Agent.Name, target.Machine.DisplayName(), target.Workspace.Label, target.Workspace.Worktree.CheckoutPath)
}
