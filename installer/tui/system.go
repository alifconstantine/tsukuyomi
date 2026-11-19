package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

type sysSnapshot struct {
	CPU      string
	Memory   string
	UEFI     bool
	Network  string
	Firmware string
}

type diskInfo struct {
	Path  string
	Size  string
	Model string
	Tran  string
}

type wifiNet struct {
	SSID     string
	Signal   int
	Security string
	InUse    bool
}

type installLineMsg string

type installTickMsg struct {
	stream *installStream
	now    time.Time
	bytes  int64
}

func installTick(stream *installStream, readCache bool) tea.Cmd {
	return tea.Tick(time.Second, func(now time.Time) tea.Msg {
		var bytes int64
		if readCache {
			_ = filepath.WalkDir("/mnt/var/cache/pacman/pkg", func(path string, entry os.DirEntry, err error) error {
				if err == nil && entry.Type().IsRegular() && strings.Contains(entry.Name(), ".pkg.tar.") && !strings.HasSuffix(entry.Name(), ".sig") {
					if info, err := entry.Info(); err == nil {
						bytes += info.Size()
					}
				}
				return nil
			})
		}
		return installTickMsg{stream: stream, now: now, bytes: bytes}
	})
}

type installDoneMsg struct {
	err error
}

type installStream struct {
	cmd    *exec.Cmd
	lines  chan string
	done   chan error
	closed bool
}

func probeSystem() sysSnapshot {
	snap := sysSnapshot{
		CPU:      "x86_64",
		Memory:   "unknown",
		Firmware: "BIOS",
		Network:  "Offline",
	}
	if _, err := os.Stat("/sys/firmware/efi"); err == nil {
		snap.UEFI = true
		snap.Firmware = "UEFI"
	}
	if b, err := os.ReadFile("/proc/cpuinfo"); err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(line, "model name") {
				if parts := strings.SplitN(line, ":", 2); len(parts) == 2 {
					snap.CPU = strings.TrimSpace(parts[1])
					break
				}
			}
		}
	}
	if b, err := os.ReadFile("/proc/meminfo"); err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(line, "MemTotal:") {
				fields := strings.Fields(line)
				if len(fields) >= 2 {
					if kb, convErr := strconv.ParseFloat(fields[1], 64); convErr == nil {
						snap.Memory = fmt.Sprintf("%.1f GiB", kb/1024/1024)
					}
				}
				break
			}
		}
	}
	if out, err := exec.Command("nmcli", "-t", "-f", "STATE", "general").Output(); err == nil {
		st := strings.TrimSpace(string(out))
		if strings.HasPrefix(st, "connected") {
			snap.Network = "Connected"
		} else if st != "" {
			snap.Network = st
		}
	}
	return snap
}

func listLocales() []string {
	defaults := []string{
		"en_US.UTF-8",
		"id_ID.UTF-8",
		"en_GB.UTF-8",
		"ja_JP.UTF-8",
		"de_DE.UTF-8",
		"fr_FR.UTF-8",
		"es_ES.UTF-8",
	}
	b, err := os.ReadFile("/usr/share/i18n/SUPPORTED")
	if err != nil {
		return defaults
	}
	seen := map[string]bool{}
	var out []string
	for _, d := range defaults {
		seen[d] = true
		out = append(out, d)
	}
	for _, line := range strings.Split(string(b), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		loc := fields[0]
		if !strings.HasSuffix(loc, ".UTF-8") || seen[loc] {
			continue
		}
		seen[loc] = true
		out = append(out, loc)
	}
	return out
}

func listKeymaps() []string {
	defaults := []string{"us", "uk", "de-latin1", "fr", "jp106", "dvorak"}
	if out, err := exec.Command("localectl", "list-keymaps").Output(); err == nil {
		var res []string
		seen := map[string]bool{}
		for _, d := range defaults {
			seen[d] = true
			res = append(res, d)
		}
		for _, line := range strings.Split(string(out), "\n") {
			k := strings.TrimSpace(line)
			if k == "" || seen[k] {
				continue
			}
			seen[k] = true
			res = append(res, k)
		}
		if len(res) > 0 {
			return res
		}
	}
	return defaults
}

func listTimezones() []string {
	defaults := []string{
		"Asia/Jakarta",
		"Asia/Makassar",
		"Asia/Jayapura",
		"Asia/Tokyo",
		"Asia/Singapore",
		"UTC",
		"America/New_York",
		"Europe/London",
	}
	root := "/usr/share/zoneinfo"
	seen := map[string]bool{}
	var out []string
	for _, d := range defaults {
		if _, err := os.Stat(filepath.Join(root, d)); err == nil {
			seen[d] = true
			out = append(out, d)
		}
	}
	_ = filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(root, p)
		if err != nil {
			return nil
		}
		if strings.HasPrefix(rel, "posix/") || strings.HasPrefix(rel, "right/") ||
			rel == "leapseconds" || rel == "tzdata.zi" || rel == "zone.tab" || rel == "zone1970.tab" || rel == "iso3166.tab" {
			return nil
		}
		if !strings.Contains(rel, "/") || seen[rel] {
			return nil
		}
		seen[rel] = true
		out = append(out, rel)
		return nil
	})
	if len(out) == 0 {
		return defaults
	}
	sort.Strings(out[min(len(defaults), len(out)):])
	return out
}

func listDisks(dryRun bool) []diskInfo {
	if dryRun {
		return []diskInfo{
			{Path: "/dev/vda", Size: "64G", Model: "QEMU VIRTIO (dry-run)", Tran: "virtio"},
			{Path: "/dev/nvme0n1", Size: "512G", Model: "NVMe SSD (dry-run)", Tran: "nvme"},
		}
	}
	out, err := exec.Command("lsblk", "-J", "-d", "-o", "NAME,PATH,SIZE,TYPE,MODEL,TRAN,RM").Output()
	if err != nil {
		return nil
	}
	var parsed struct {
		Blockdevices []struct {
			Name  string `json:"name"`
			Path  string `json:"path"`
			Size  string `json:"size"`
			Type  string `json:"type"`
			Model string `json:"model"`
			Tran  string `json:"tran"`
			RM    any    `json:"rm"`
		} `json:"blockdevices"`
	}
	if err := json.Unmarshal(out, &parsed); err != nil {
		return nil
	}
	var disks []diskInfo
	for _, d := range parsed.Blockdevices {
		if d.Type != "disk" || strings.HasPrefix(d.Name, "loop") || strings.HasPrefix(d.Name, "zram") {
			continue
		}
		path := d.Path
		if path == "" {
			path = "/dev/" + d.Name
		}
		model := strings.TrimSpace(d.Model)
		if model == "" {
			model = "Block Device"
		}
		tran := strings.TrimSpace(d.Tran)
		if tran == "" {
			tran = "disk"
		}
		disks = append(disks, diskInfo{
			Path:  path,
			Size:  d.Size,
			Model: model,
			Tran:  tran,
		})
	}
	return disks
}

func scanWifi() ([]wifiNet, string) {
	_ = exec.Command("nmcli", "device", "wifi", "rescan").Run()
	out, err := exec.Command("nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "device", "wifi", "list").Output()
	if err != nil {
		return nil, "nmcli unavailable or no Wi-Fi adapter detected"
	}
	seen := map[string]bool{}
	var nets []wifiNet
	for _, line := range strings.Split(string(out), "\n") {
		if line == "" {
			continue
		}
		parts := strings.Split(line, ":")
		if len(parts) < 4 {
			continue
		}
		ssid := strings.TrimSpace(parts[1])
		if ssid == "" || seen[ssid] {
			continue
		}
		seen[ssid] = true
		sig, _ := strconv.Atoi(strings.TrimSpace(parts[2]))
		sec := strings.TrimSpace(parts[3])
		if sec == "" {
			sec = "Open"
		}
		nets = append(nets, wifiNet{
			SSID:     ssid,
			Signal:   sig,
			Security: sec,
			InUse:    strings.TrimSpace(parts[0]) == "*",
		})
	}
	return nets, ""
}

func connectWifi(ssid, pass string) error {
	args := []string{"device", "wifi", "connect", ssid}
	if pass != "" {
		args = append(args, "password", pass)
	}
	out, err := exec.Command("nmcli", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func resolveBackendScript() string {
	candidates := []string{
		os.Getenv("TSUKUYOMI_BACKEND"),
		"/usr/local/lib/tsukuyomi/backend/tsukuyomi-install",
		"/usr/local/bin/tsukuyomi-install",
	}
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		candidates = append(candidates,
			filepath.Join(dir, "../backend/tsukuyomi-install"),
			filepath.Join(dir, "tsukuyomi/installer/backend/tsukuyomi-install"),
		)
	}
	if cwd, err := os.Getwd(); err == nil {
		candidates = append(candidates,
			filepath.Join(cwd, "../backend/tsukuyomi-install"),
			filepath.Join(cwd, "tsukuyomi/installer/backend/tsukuyomi-install"),
		)
	}
	for _, c := range candidates {
		if c == "" {
			continue
		}
		if st, err := os.Stat(c); err == nil && !st.IsDir() {
			return c
		}
	}
	return "tsukuyomi-install"
}

func buildInstallEnv(m model) []string {
	env := os.Environ()
	swap := "0"
	if m.swapIdx >= 0 && m.swapIdx < len(swapChoices) {
		swap = strconv.Itoa(swapChoices[m.swapIdx])
	}
	encrypt := "0"
	if m.encrypt {
		encrypt = "1"
	}
	snaps := "0"
	if m.snapshots {
		snaps = "1"
	}
	vars := map[string]string{
		"TSUKUYOMI_DISK":             m.selectedDiskPath(),
		"TSUKUYOMI_LOCALE":           m.selectedLocale(),
		"TSUKUYOMI_KEYMAP":           m.selectedKeymap(),
		"TSUKUYOMI_TIMEZONE":         m.selectedTimezone(),
		"TSUKUYOMI_BROWSER":          m.selectedBrowserPkg(),
		"TSUKUYOMI_HOSTNAME":         strings.TrimSpace(m.hostname),
		"TSUKUYOMI_USERNAME":         strings.TrimSpace(m.username),
		"TSUKUYOMI_FULLNAME":         strings.TrimSpace(m.fullname),
		"TSUKUYOMI_PASSWORD_HASH":    m.passwordHash,
		"TSUKUYOMI_ENCRYPT":          encrypt,
		"TSUKUYOMI_LUKS_PASSPHRASE":  m.luksPass,
		"TSUKUYOMI_SWAP_GIB":         swap,
		"TSUKUYOMI_SUBVOL_SNAPSHOTS": snaps,
	}
	if m.dryRun {
		vars["TSUKUYOMI_DRYRUN"] = "1"
		if _, err := os.Stat("/usr/share/tsukuyomi"); err != nil {
			if cwd, cerr := os.Getwd(); cerr == nil {
				for _, p := range []string{
					filepath.Join(cwd, "../../archiso/airootfs/usr/share/tsukuyomi"),
					filepath.Join(cwd, "tsukuyomi/archiso/airootfs/usr/share/tsukuyomi"),
				} {
					if _, serr := os.Stat(p); serr == nil {
						vars["TSUKUYOMI_SHARE"] = p
						break
					}
				}
			}
		}
	}
	for k, v := range vars {
		env = append(env, k+"="+v)
	}
	return env
}

func startInstall(m model) (*installStream, tea.Cmd) {
	backend := resolveBackendScript()
	cmd := exec.Command(backend)
	cmd.Env = buildInstallEnv(m)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	pr, pw := io.Pipe()
	cmd.Stdout = pw
	cmd.Stderr = pw

	s := &installStream{
		cmd:   cmd,
		lines: make(chan string, 256),
		done:  make(chan error, 1),
	}

	if err := cmd.Start(); err != nil {
		_ = pw.Close()
		_ = pr.Close()
		s.done <- err
		close(s.lines)
		return s, s.wait()
	}

	go func() {
		defer close(s.lines)
		defer pr.Close()
		sc := bufio.NewScanner(pr)
		buf := make([]byte, 0, 64*1024)
		sc.Buffer(buf, 1024*1024)
		for sc.Scan() {
			s.lines <- ansi.Strip(sc.Text())
		}
	}()

	go func() {
		err := cmd.Wait()
		_ = pw.Close()
		s.done <- err
	}()

	return s, s.wait()
}

func (s *installStream) wait() tea.Cmd {
	return func() tea.Msg {
		line, ok := <-s.lines
		if ok {
			return installLineMsg(line)
		}
		err := <-s.done
		return installDoneMsg{err: err}
	}
}

func (s *installStream) kill() {
	if s == nil || s.closed || s.cmd == nil || s.cmd.Process == nil {
		return
	}
	s.closed = true
	_ = syscall.Kill(-s.cmd.Process.Pid, syscall.SIGTERM)
	time.Sleep(150 * time.Millisecond)
	_ = syscall.Kill(-s.cmd.Process.Pid, syscall.SIGKILL)
}
