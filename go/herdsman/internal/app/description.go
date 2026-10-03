package app

import (
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"
)

// ValidateSessionDescription is shared by the form and the launch boundary.
// A description names a promptless session; it is never submitted as a prompt.
func ValidateSessionDescription(description string) error {
	if strings.TrimSpace(description) == "" {
		return fmt.Errorf("enter a session description")
	}
	if !utf8.ValidString(description) {
		return fmt.Errorf("session description must be valid UTF-8")
	}
	if strings.IndexFunc(description, unicode.IsControl) >= 0 {
		return fmt.Errorf("session description must be a single line without control characters")
	}
	if len(description) > maxAgentArgumentBytes {
		return fmt.Errorf("session description exceeds the supported CLI argument size of %d bytes", maxAgentArgumentBytes)
	}
	return nil
}
