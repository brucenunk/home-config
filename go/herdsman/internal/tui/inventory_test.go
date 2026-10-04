package tui

import (
	"strings"
	"testing"
	"time"

	"github.com/brucenunk/home-config/go/herdsman/internal/app"
	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

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
