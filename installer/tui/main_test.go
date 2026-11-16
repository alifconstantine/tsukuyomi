package main

import (
	"os/exec"
	"strings"
	"testing"
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
	if m.state != stepWelcome {
		t.Fatalf("expected initial state welcome, got %s", m.state)
	}
	if m.selectedBrowserPkg() != "brave-bin" {
		t.Fatalf("expected default recommended browser brave-bin, got %s", m.selectedBrowserPkg())
	}
	next, _ := m.onKey("enter") // -> locale
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

func TestDryRunSidebarRender(t *testing.T) {
	m := initialModel(true)
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
