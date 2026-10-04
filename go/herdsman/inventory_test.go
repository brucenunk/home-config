package main

import (
	"strings"
	"testing"
	"time"

	"github.com/brucenunk/home-config/go/herdsman/internal/daemon"
	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
)

func TestInventoryStatusAgeAndStaleness(t *testing.T) {
	now := time.Now()
	fresh := daemon.Inventory{ProfilesUpdated: now, Machines: []daemon.MachineState{{Machine: herdr.Local(), Updated: now.Add(-12 * time.Second)}}}
	text, warning := inventoryStatus(fresh, now, 30*time.Second)
	if warning || text != "Inventory: oldest snapshot 12s ago" {
		t.Fatal(text, warning)
	}
	text, warning = inventoryStatus(fresh, now.Add(48*time.Second), 30*time.Second)
	if warning || !strings.Contains(text, "1m ago") {
		t.Fatal("boundary should not yet be stale", text, warning)
	}
	text, warning = inventoryStatus(fresh, now.Add(49*time.Second), 30*time.Second)
	if !warning || !strings.Contains(text, "stale: Local") {
		t.Fatal(text, warning)
	}
	text, warning = inventoryStatus(fresh, now.Add(49*time.Second), time.Minute)
	if warning {
		t.Fatal("staleness ignored configured interval", text)
	}
	fresh.Machines[0].Error = "offline"
	text, warning = inventoryStatus(fresh, now, 30*time.Second)
	if !warning || !strings.Contains(text, "stale: Local") || !strings.Contains(text, "12s ago") {
		t.Fatal("refresh failure must warn immediately", text)
	}
	fresh.Machines = append(fresh.Machines, daemon.MachineState{Machine: herdr.Machine{ID: "r", Label: "devbox"}})
	text, warning = inventoryStatus(fresh, now, 30*time.Second)
	if !warning || !strings.Contains(text, "unavailable: devbox") || !strings.Contains(text, "stale: Local") {
		t.Fatal(text)
	}
	fresh.ProfilesUpdated = time.Time{}
	text, warning = inventoryStatus(fresh, now, 30*time.Second)
	if !warning || !strings.Contains(text, "machine profiles") {
		t.Fatal(text)
	}
}

func TestInventoryAgeClampsFutureTimestamps(t *testing.T) {
	now := time.Now()
	text, warning := inventoryStatus(daemon.Inventory{ProfilesUpdated: now.Add(time.Minute)}, now, 30*time.Second)
	if warning || text != "Inventory: oldest snapshot 0s ago" {
		t.Fatal(text, warning)
	}
}
