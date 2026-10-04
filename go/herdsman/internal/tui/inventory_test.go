package tui

import (
	"strings"
	"testing"
	"time"

	"github.com/brucenunk/home-config/go/herdsman/internal/app"
	"github.com/brucenunk/home-config/go/herdsman/internal/daemon"
	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

func TestInventoryStatusAgeAndStaleness(t *testing.T) {
	now := time.Now()
	fresh := daemon.Inventory{ProfilesUpdated: now, Machines: []daemon.MachineState{{Machine: herdr.Local(), Updated: now.Add(-12 * time.Second)}}}
	text, warning := InventoryStatus(fresh, now, 30*time.Second)
	if warning || text != "Inventory: oldest snapshot 12s ago" {
		t.Fatal(text, warning)
	}
	text, warning = InventoryStatus(fresh, now.Add(48*time.Second), 30*time.Second)
	if warning || !strings.Contains(text, "1m ago") {
		t.Fatal("boundary should not yet be stale", text, warning)
	}
	text, warning = InventoryStatus(fresh, now.Add(49*time.Second), 30*time.Second)
	if !warning || !strings.Contains(text, "stale: Local") {
		t.Fatal(text, warning)
	}
	text, warning = InventoryStatus(fresh, now.Add(49*time.Second), time.Minute)
	if warning {
		t.Fatal("staleness ignored configured interval", text)
	}
	fresh.Machines[0].Error = "offline"
	text, warning = InventoryStatus(fresh, now, 30*time.Second)
	if !warning || !strings.Contains(text, "stale: Local") || !strings.Contains(text, "12s ago") {
		t.Fatal("refresh failure must warn immediately", text)
	}
	fresh.Machines = append(fresh.Machines, daemon.MachineState{Machine: herdr.Machine{ID: "r", Label: "devbox"}})
	text, warning = InventoryStatus(fresh, now, 30*time.Second)
	if !warning || !strings.Contains(text, "unavailable: devbox") || !strings.Contains(text, "stale: Local") {
		t.Fatal(text)
	}
	fresh.ProfilesUpdated = time.Time{}
	text, warning = InventoryStatus(fresh, now, 30*time.Second)
	if !warning || !strings.Contains(text, "machine profiles") {
		t.Fatal(text)
	}
}

func TestInventoryAgeClampsFutureTimestamps(t *testing.T) {
	now := time.Now()
	text, warning := InventoryStatus(daemon.Inventory{ProfilesUpdated: now.Add(time.Minute)}, now, 30*time.Second)
	if warning || text != "Inventory: oldest snapshot 0s ago" {
		t.Fatal(text, warning)
	}
}

func TestInventoryWarnings(t *testing.T) {
	now := time.Now()
	i := daemon.Inventory{ProfilesUpdated: now, Machines: []daemon.MachineState{{Machine: herdr.Local(), Updated: now}}}
	if warnings := InventoryWarnings(i, now, 30*time.Second); len(warnings) != 0 {
		t.Fatal(warnings)
	}
	i.Machines = append(i.Machines, daemon.MachineState{Machine: herdr.Machine{ID: "r", Label: "remote\x1b"}, Error: "failure\x1b"})
	warnings := strings.Join(InventoryWarnings(i, now, 30*time.Second), "\n")
	if !strings.Contains(warnings, "no successful refresh") || strings.ContainsRune(warnings, '\x1b') {
		t.Fatal(warnings)
	}
	i.Machines[1].Updated = now.Add(-time.Minute)
	if warnings := strings.Join(InventoryWarnings(i, now, 30*time.Second), " "); !strings.Contains(warnings, "stale") {
		t.Fatal(warnings)
	}
}

func TestInventoryNoticeVisibleWithinPicker(t *testing.T) {
	c := app.Config{}
	for _, height := range []int{16, 24} {
		var targets []app.FinishTarget
		for i := 0; i < 40; i++ {
			targets = append(targets, app.FinishTarget{Agent: herdr.Agent{Name: "possum"}, Workspace: herdr.Workspace{Label: "Task"}})
		}
		m, err := NewFinish(c, targets, t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		m.SetInventoryNotice(func(time.Time) (string, bool) { return "Inventory stale: devbox · oldest success 2m ago", true })
		model, _ := m.Update(tea.WindowSizeMsg{Width: 80, Height: height})
		view := ansi.Strip(model.View())
		if !strings.Contains(view, "Inventory stale: devbox") || strings.Count(view, "\n") > height {
			t.Fatalf("height=%d lines=%d\n%s", height, strings.Count(view, "\n"), view)
		}
	}
	m, err := New(c, nil, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	m.SetInventoryNotice(func(time.Time) (string, bool) { return "Inventory: oldest snapshot 12s ago", false })
	m.repositories()
	model, _ := m.Update(tea.WindowSizeMsg{Width: 80, Height: 24})
	if !strings.Contains(ansi.Strip(model.View()), "Inventory: oldest snapshot 12s ago") {
		t.Fatal(model.View())
	}
}

func TestInventoryAgeTickPreservesSelection(t *testing.T) {
	c := app.Config{}
	target := app.FinishTarget{Agent: herdr.Agent{Name: "possum"}, Workspace: herdr.Workspace{Label: "Task"}}
	m, err := NewFinish(c, []app.FinishTarget{target}, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	m.SetInventoryNotice(func(at time.Time) (string, bool) {
		if at.Sub(now) > time.Minute {
			return "Inventory stale: Local", true
		}
		return "Inventory: oldest snapshot 12s ago", false
	})
	if m.Init() == nil {
		t.Fatal("age tick not scheduled")
	}
	selected, _ := m.Update(tea.KeyMsg{Type: tea.KeySpace})
	m = selected.(FinishModel)
	updated, cmd := m.Update(inventoryTickMsg(now.Add(2 * time.Minute)))
	final := updated.(FinishModel)
	if cmd == nil || final.marked != 1 || !final.picker.inventoryWarning || !strings.Contains(ansi.Strip(final.View()), "Inventory stale: Local") {
		t.Fatal("age update lost status or selection")
	}
	if final.picker.list.Items()[0].(finishItem).target.Agent.Name != "possum" {
		t.Fatal("age update changed inventory")
	}
}
