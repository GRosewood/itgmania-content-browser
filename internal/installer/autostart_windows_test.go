//go:build windows

package installer

import (
	"strings"
	"testing"
)

// The task definition is the thing that has to be exactly right: schtasks
// rejects the whole file for a single malformed field, and the failure lands on
// a player's machine rather than here.

func TestTaskNamesArePerInstall(t *testing.T) {
	a := taskName(testInstall(`C:\Games\ITGmania`))
	b := taskName(testInstall(`C:\Games\ITGmania2`))
	if a == b {
		t.Fatal("two installs would fight over one task")
	}
	if !strings.HasPrefix(a, `\`) {
		t.Errorf("task name %q should sit at the scheduler root", a)
	}
}
