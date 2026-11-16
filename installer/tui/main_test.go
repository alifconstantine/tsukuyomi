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
	next, _ := m.onKey("enter")
	nm := next.(model)
	if nm.state != stepLocale {
		t.Fatalf("expected state locale after enter, got %s", nm.state)
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
	if !strings.Contains(s, "@@TSUKUYOMI_DONE") {
		t.Fatalf("expected @@TSUKUYOMI_DONE in backend output, got:\n%s", s)
	}
}
