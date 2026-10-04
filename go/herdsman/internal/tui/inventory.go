package tui

import (
	"fmt"
	"strings"
	"time"

	"github.com/brucenunk/home-config/go/herdsman/internal/daemon"
)

// InventoryStatus recomputes age against the picker's fixed inventory; this never queries the
// daemon or replaces rows underneath a selection.
func InventoryStatus(i daemon.Inventory, now time.Time, interval time.Duration) (string, bool) {
	var unavailable, stale []string
	var oldest, oldestStale time.Duration
	inspect := func(name string, updated time.Time, err string) {
		if updated.IsZero() {
			unavailable = append(unavailable, name)
			return
		}
		age := max(time.Duration(0), now.Sub(updated))
		oldest = max(oldest, age)
		if err != "" || age > 2*interval {
			stale = append(stale, name)
			oldestStale = max(oldestStale, age)
		}
	}
	inspect("machine profiles", i.ProfilesUpdated, i.ProfilesError)
	for _, m := range i.Machines {
		inspect(m.Machine.DisplayName(), m.Updated, m.Error)
	}
	if len(unavailable) > 0 {
		text := "Inventory unavailable: " + strings.Join(unavailable, ", ")
		if len(stale) > 0 {
			text += " · stale: " + strings.Join(stale, ", ")
		}
		return text, true
	}
	if len(stale) > 0 {
		return fmt.Sprintf("Inventory stale: %s · oldest success %s ago", strings.Join(stale, ", "), ageText(oldestStale)), true
	}
	return fmt.Sprintf("Inventory: oldest snapshot %s ago", ageText(oldest)), false
}
func ageText(age time.Duration) string {
	text := age.Truncate(time.Second).String()
	if strings.HasSuffix(text, "m0s") {
		text = strings.TrimSuffix(text, "0s")
	}
	return text
}

// InventoryWarnings describes unavailable or stale snapshots for non-picker output.
func InventoryWarnings(i daemon.Inventory, now time.Time, interval time.Duration) []string {
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
