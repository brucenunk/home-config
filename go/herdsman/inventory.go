package main

import (
	"fmt"
	"strings"
	"time"

	"github.com/brucenunk/home-config/go/herdsman/internal/daemon"
)

// Recompute age against the picker's fixed inventory; this never queries the
// daemon or replaces rows underneath a selection.
func inventoryStatus(i daemon.Inventory, now time.Time, interval time.Duration) (string, bool) {
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
