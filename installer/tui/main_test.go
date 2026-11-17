package main

import (
	"os"
	"os/exec"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

// Published Ulrich Drepper SHA-512 crypt reference test vector.
func TestSha512CryptVector(t *testing.T) {
	got := sha512Crypt("Hello world!", "saltstring")
	want := "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1"
	if got != want {
		t.Fatalf("sha512Crypt mismatch:\n got: %s\nwant: %s", got, want)
	}
}

func TestHashPasswordFormat(t *testing.T) {
	h, err := hashPassword("tsukuyomi-secret")
	if err != nil {
		t.Fatalf("hashPassword failed: %v", err)
	}
	if !strings.HasPrefix(h, "$6$") || len(h) != 106 {
		t.Fatalf("unexpected hash format: %q (len=%d)", h, len(h))
	}
}

func TestDryRunWizardTransition(t *testing.T) {
	m := initialModel(true)
	if m.state != stepIntro {
		t.Fatalf("expected initial state intro, got %s", m.state)
	}
	if m.selectedBrowserPkg() != "brave-bin" {
		t.Fatalf("expected default recommended browser brave-bin, got %s", m.selectedBrowserPkg())
	}
	next, _ := m.onKey("enter") // intro -> welcome
	if next.(model).state != stepWelcome {
		t.Fatalf("expected state welcome after intro, got %s", next.(model).state)
	}
	next, _ = next.(model).onKey("enter") // welcome -> locale
	next, _ = next.(model).onKey("enter") // -> timezone
	next, _ = next.(model).onKey("enter") // -> network
	next, _ = next.(model).onKey("enter") // -> browser
	nm := next.(model)
	if nm.state != stepBrowser {
		t.Fatalf("expected state browser after network, got %s", nm.state)
	}
	next, _ = nm.onKey("enter") // -> disk
	if next.(model).state != stepDisk {
		t.Fatalf("expected state disk after browser, got %s", next.(model).state)
	}
}

func TestIntroTimerAdvancesToWelcome(t *testing.T) {
	m := initialModel(true)
	if v := m.View(); !strings.Contains(v.Content, "TSUKUYOMI OS INSTALLER") {
		t.Fatalf("expected intro banner view, got:\n%s", v.Content)
	}
	var cur tea.Model = m
	for i := 0; i < 60; i++ {
		cur, _ = cur.Update(introTickMsg{})
	}
	if cur.(model).state != stepWelcome {
		t.Fatalf("expected intro ticks to transition to welcome, got %s", cur.(model).state)
	}
}

func TestDryRunSidebarRender(t *testing.T) {
	m := initialModel(true)
	m.state = stepWelcome
	m.w = 110
	m.h = 34
	v := m.View()
	if !strings.Contains(v.Content, "INSTALL STEPS") || !strings.Contains(v.Content, "Browser") {
		t.Fatalf("expected sidebar with INSTALL STEPS and Browser in view")
	}
}

func TestDryRunBackendScript(t *testing.T) {
	m := initialModel(true)
	m.username = "constantine"
	m.password = "secret123"
	m.passConfirm = "secret123"
	hash, err := hashPassword(m.password)
	if err != nil {
		t.Fatal(err)
	}
	m.passwordHash = hash

	cmd := exec.Command("../backend/tsukuyomi-install")
	cmd.Env = buildInstallEnv(m)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("dry-run backend failed: %v\n%s", err, string(out))
	}
	s := string(out)
	if !strings.Contains(s, "@@TSUKUYOMI_DONE") || !strings.Contains(s, "brave-bin") {
		t.Fatalf("expected @@TSUKUYOMI_DONE and brave-bin in backend output, got:\n%s", s)
	}
}

func TestDoneExitActions(t *testing.T) {
	origCmd := exitCommand
	origFile := exitActionFile
	defer func() {
		exitCommand = origCmd
		exitActionFile = origFile
	}()

	marker := t.TempDir() + "/exit-action"
	exitActionFile = marker

	var calls []string
	exitCommand = func(name string, args ...string) *exec.Cmd {
		calls = append(calls, strings.TrimSpace(name+" "+strings.Join(args, " ")))
		return exec.Command("true")
	}

	m := initialModel(true)
	m.state = stepDone
	m.doneCursor = 0
	next, _ := m.onKey("enter")
	if got := next.(model).exitAction; got != "reboot" {
		t.Fatalf("expected exitAction reboot, got %q", got)
	}
	if len(calls) != 0 {
		t.Fatalf("expected no exit command run inside Update, got %v", calls)
	}

	if err := applyExit("reboot", false); err != nil {
		t.Fatalf("applyExit(reboot) failed: %v", err)
	}
	if got := strings.Join(calls, "; "); got != "sync; systemctl reboot" {
		t.Fatalf("unexpected commands: %q", got)
	}
	if data, err := os.ReadFile(marker); err != nil || strings.TrimSpace(string(data)) != "reboot" {
		t.Fatalf("expected marker file reboot, got %q err=%v", string(data), err)
	}
	if err := applyExit("shell", false); err != nil {
		t.Fatalf("applyExit(shell) failed: %v", err)
	}
	if len(calls) != 2 {
		t.Fatalf("expected shell exit not to execute extra commands, got %v", calls)
	}
	if err := applyExit("reboot", true); err != nil {
		t.Fatalf("applyExit dry-run failed: %v", err)
	}
	if len(calls) != 2 {
		t.Fatalf("expected dry-run not to execute reboot, got %v", calls)
	}
}
