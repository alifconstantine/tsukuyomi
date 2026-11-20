package main

import (
	"fmt"
	"image/color"
	"os"
	"os/exec"
	"regexp"
	"slices"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/sahilm/fuzzy"
)

// Tsukuyomi Obsidian & Dark Crimson Palette (keyboard-driven TUI).
var (
	cBg      = lipgloss.Color("#060607")
	cSurface = lipgloss.Color("#120E0E")
	cBorder  = lipgloss.Color("#3A2B2B")
	cText    = lipgloss.Color("#EAE2D5")
	cMuted   = lipgloss.Color("#8C857A")
	cCrimson = lipgloss.Color("#C92A2A")
	cSage    = lipgloss.Color("#7FA67D")
	cAmber   = lipgloss.Color("#C79A5B")
	cErr     = lipgloss.Color("#E05252")
)

type browserChoice struct {
	pkg         string
	label       string
	hint        string
	recommended bool
}

var (
	swapChoices = []int{0, 4, 8}
	browsers    = []browserChoice{
		{pkg: "brave-bin", label: "Brave", hint: "privacy-first Chromium with adblock · CachyOS repo", recommended: true},
		{pkg: "firefox", label: "Firefox", hint: "open-source Mozilla browser · extra repo"},
		{pkg: "zen-browser-bin", label: "Zen Browser", hint: "vertical tabs Firefox fork · CachyOS repo"},
		{pkg: "chromium", label: "Chromium", hint: "open-source Google Chrome base · extra repo"},
		{pkg: "none", label: "None", hint: "skip browser installation (install later)"},
	}
	installStages = []struct {
		id    string
		label string
	}{
		{"preflight", "Pre-flight verification"},
		{"disk", "Partitioning GPT target disk"},
		{"luks", "Encryption volume setup"},
		{"filesystems", "Creating Btrfs subvolumes & mounts"},
		{"pacstrap", "Installing CachyOS, Ryoku & CLI tools"},
		{"configure", "Configuring locale, user & mkinitcpio"},
		{"desktop", "Deploying Tsukuyomi desktop, fastfetch & SDDM"},
		{"bootloader", "Installing Limine UKI & Plymouth splash"},
		{"finalize", "Finalizing & unmounting"},
	}
	validHostRe = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$`)
	validUserRe = regexp.MustCompile(`^[a-z_][a-z0-9_-]{0,31}$`)
)

const (
	stepIntro    = "intro"
	stepWelcome  = "welcome"
	stepLocale   = "locale"
	stepTimezone = "timezone"
	stepNetwork  = "network"
	stepBrowser  = "browser"
	stepDisk     = "disk"
	stepIdentity = "identity"
	stepReview   = "review"
	stepInstall  = "install"
	stepDone     = "done"
)

const introBanner = `███  ███  █ █  █ █  █ █  █ █  ███  █   █  ███
 █   █    █ █  ██   █ █  █ █  █ █  ██ ██   █
 █   ███  █ █  █    █ █   █   █ █  █ █ █   █
 █     █  █ █  ██   █ █   █   █ █  █   █   █
 █   ███  ███  █ █  ███   █   ███  █   █  ███`

type introTickMsg time.Time

func introTickCmd() tea.Cmd {
	return tea.Tick(33*time.Millisecond, func(t time.Time) tea.Msg {
		return introTickMsg(t)
	})
}

var stepMeta = []struct {
	key   string
	label string
}{
	{stepWelcome, "Welcome"},
	{stepLocale, "Locale"},
	{stepTimezone, "Timezone"},
	{stepNetwork, "Network"},
	{stepBrowser, "Browser"},
	{stepDisk, "Disk"},
	{stepIdentity, "Account"},
	{stepReview, "Review"},
	{stepInstall, "Install"},
}

type model struct {
	w, h       int
	dryRun     bool
	state      string
	errMsg     string
	introTick  int
	introRatio float64

	sys sysSnapshot

	// Locale & keymap
	locales       []string
	locFiltered   []string
	locCursor     int
	locSearch     string
	locSearching  bool
	keymaps       []string
	keymapIdx     int
	localePaneKey bool

	// Timezone
	tzAll      []string
	tzFiltered []string
	tzCursor   int
	tzSearch   string
	tzSearchOn bool

	// Network
	wifiNets    []wifiNet
	wifiCursor  int
	wifiNotice  string
	wifiPrompt  bool
	wifiPass    string
	wifiConnect string

	// Browser
	browserCursor int

	// Disk & storage
	disks      []diskInfo
	diskCursor int
	diskFocus  int // 0=disk list, 1=encrypt toggle, 2=luks pass, 3=luks confirm, 4=snapshots, 5=swap
	encrypt    bool
	luksPass   string
	luksConf   string
	snapshots  bool
	swapIdx    int

	// Identity
	idFocus      int // 0=hostname, 1=username, 2=fullname, 3=pass, 4=confirm
	hostname     string
	username     string
	fullname     string
	password     string
	passConfirm  string
	passwordHash string

	// Review
	confirmText string

	// Install & done
	istream    *installStream
	stageIdx   int
	stageStart time.Time
	stageTime  time.Duration
	cacheBytes int64
	installLog []string
	installErr string
	abortArmed bool
	abortAt    time.Time
	doneCursor int
	exitAction string
}

func initialModel(dryRun bool) model {
	locs := listLocales()
	tzs := listTimezones()
	kms := listKeymaps()
	disks := listDisks(dryRun)
	nets, wifiNote := scanWifi()

	m := model{
		dryRun:        dryRun,
		state:         stepIntro,
		sys:           probeSystem(),
		locales:       locs,
		keymaps:       kms,
		tzAll:         tzs,
		wifiNets:      nets,
		wifiNotice:    wifiNote,
		browserCursor: 0, // Brave (Recommended)
		disks:         disks,
		snapshots:     true,
		swapIdx:       1, // 4 GiB default
		hostname:      "tsukuyomi",
	}
	m.applyLocaleFilter()
	m.applyTzFilter()
	return m
}

func (m model) Init() tea.Cmd {
	if m.state == stepIntro {
		return introTickCmd()
	}
	return nil
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
		return m, nil
	case introTickMsg:
		if m.state != stepIntro {
			return m, nil
		}
		m.introTick++
		const fillTicks = 42.0
		const holdTicks = 12
		t := min(float64(m.introTick)/fillTicks, 1.0)
		// Ease-out cubic for snappy terminal splash bar.
		inv := 1.0 - t
		m.introRatio = 1.0 - inv*inv*inv
		if m.introTick >= int(fillTicks)+holdTicks {
			m.state = stepWelcome
			return m, nil
		}
		return m, introTickCmd()
	case installTickMsg:
		if m.state != stepInstall || m.installErr != "" || msg.stream != m.istream {
			return m, nil
		}
		m.stageTime = msg.now.Sub(m.stageStart).Truncate(time.Second)
		m.cacheBytes = msg.bytes
		return m, installTick(m.istream, !m.dryRun && installStages[m.stageIdx].id == "pacstrap")
	case installLineMsg:
		line := string(msg)
		if strings.HasPrefix(line, "@@TSUKUYOMI_STEP ") {
			id := strings.TrimSpace(strings.TrimPrefix(line, "@@TSUKUYOMI_STEP "))
			for i, st := range installStages {
				if st.id == id {
					m.stageIdx = i
					m.stageStart = time.Now()
					m.stageTime = 0
					m.cacheBytes = 0
					break
				}
			}
		} else {
			m.installLog = append(m.installLog, line)
			if len(m.installLog) > 300 {
				m.installLog = m.installLog[len(m.installLog)-300:]
			}
		}
		if m.istream != nil {
			return m, m.istream.wait()
		}
		return m, nil
	case installDoneMsg:
		if msg.err != nil {
			m.installErr = msg.err.Error()
		} else {
			m.stageIdx = len(installStages)
			m.state = stepDone
		}
		return m, nil
	case tea.MouseWheelMsg:
		switch msg.Button {
		case tea.MouseWheelUp:
			return m.onKey("up")
		case tea.MouseWheelDown:
			return m.onKey("down")
		}
	case tea.KeyPressMsg:
		return m.onKey(msg.String())
	}
	return m, nil
}

func (m model) onKey(k string) (tea.Model, tea.Cmd) {
	if k == "ctrl+c" {
		if m.state == stepInstall && m.installErr == "" {
			if m.abortArmed && time.Since(m.abortAt) <= 3*time.Second {
				m.istream.kill()
				return m, tea.Quit
			}
			m.abortArmed = true
			m.abortAt = time.Now()
			return m, nil
		}
		return m, tea.Quit
	}

	m.errMsg = ""
	switch m.state {
	case stepIntro:
		if k == "q" {
			return m, tea.Quit
		}
		m.state = stepWelcome
	case stepWelcome:
		if k == "enter" {
			m.state = stepLocale
		} else if k == "q" {
			return m, tea.Quit
		}
	case stepLocale:
		return m.keyLocale(k)
	case stepTimezone:
		return m.keyTimezone(k)
	case stepNetwork:
		return m.keyNetwork(k)
	case stepBrowser:
		return m.keyBrowser(k)
	case stepDisk:
		return m.keyDisk(k)
	case stepIdentity:
		return m.keyIdentity(k)
	case stepReview:
		return m.keyReview(k)
	case stepInstall:
		if m.installErr != "" && (k == "enter" || k == "esc") {
			m.installErr = ""
			m.state = stepReview
		}
	case stepDone:
		return m.keyDone(k)
	}
	return m, nil
}

func (m model) keyLocale(k string) (tea.Model, tea.Cmd) {
	if m.locSearching {
		switch k {
		case "esc", "enter":
			m.locSearching = false
		case "backspace":
			if len(m.locSearch) > 0 {
				m.locSearch = m.locSearch[:len(m.locSearch)-1]
				m.applyLocaleFilter()
			}
		default:
			if editText(&m.locSearch, k) {
				m.applyLocaleFilter()
			}
		}
		return m, nil
	}
	switch k {
	case "esc":
		m.state = stepWelcome
	case "tab":
		m.localePaneKey = !m.localePaneKey
	case "up", "k":
		if m.localePaneKey {
			m.keymapIdx = (m.keymapIdx - 1 + len(m.keymaps)) % len(m.keymaps)
		} else if m.locCursor > 0 {
			m.locCursor--
		}
	case "down", "j":
		if m.localePaneKey {
			m.keymapIdx = (m.keymapIdx + 1) % len(m.keymaps)
		} else if m.locCursor < len(m.locFiltered)-1 {
			m.locCursor++
		}
	case "left", "h":
		if m.localePaneKey {
			m.keymapIdx = (m.keymapIdx - 1 + len(m.keymaps)) % len(m.keymaps)
		}
	case "right", "l":
		if m.localePaneKey {
			m.keymapIdx = (m.keymapIdx + 1) % len(m.keymaps)
		}
	case "/":
		m.locSearching = true
		m.localePaneKey = false
	case "enter":
		m.state = stepTimezone
	}
	return m, nil
}

func (m model) keyTimezone(k string) (tea.Model, tea.Cmd) {
	if m.tzSearchOn {
		switch k {
		case "esc", "enter":
			m.tzSearchOn = false
		case "backspace":
			if len(m.tzSearch) > 0 {
				m.tzSearch = m.tzSearch[:len(m.tzSearch)-1]
				m.applyTzFilter()
			}
		default:
			if editText(&m.tzSearch, k) {
				m.applyTzFilter()
			}
		}
		return m, nil
	}
	switch k {
	case "esc":
		m.state = stepLocale
	case "up", "k":
		if m.tzCursor > 0 {
			m.tzCursor--
		}
	case "down", "j":
		if m.tzCursor < len(m.tzFiltered)-1 {
			m.tzCursor++
		}
	case "/":
		m.tzSearchOn = true
	case "enter":
		m.state = stepNetwork
	}
	return m, nil
}

func (m model) keyNetwork(k string) (tea.Model, tea.Cmd) {
	if m.wifiPrompt {
		switch k {
		case "esc":
			m.wifiPrompt = false
			m.wifiPass = ""
		case "enter":
			if err := connectWifi(m.wifiConnect, m.wifiPass); err != nil {
				m.errMsg = err.Error()
			} else {
				m.wifiPrompt = false
				m.wifiPass = ""
				m.wifiNets, m.wifiNotice = scanWifi()
				m.sys = probeSystem()
			}
		case "backspace":
			if len(m.wifiPass) > 0 {
				m.wifiPass = m.wifiPass[:len(m.wifiPass)-1]
			}
		default:
			editText(&m.wifiPass, k)
		}
		return m, nil
	}
	switch k {
	case "esc":
		m.state = stepTimezone
	case "r":
		m.wifiNets, m.wifiNotice = scanWifi()
		m.sys = probeSystem()
	case "up", "k":
		if m.wifiCursor > 0 {
			m.wifiCursor--
		}
	case "down", "j":
		if m.wifiCursor < len(m.wifiNets)-1 {
			m.wifiCursor++
		}
	case "c":
		if len(m.wifiNets) > 0 {
			net := m.wifiNets[m.wifiCursor]
			if net.Security == "Open" {
				if err := connectWifi(net.SSID, ""); err != nil {
					m.errMsg = err.Error()
				} else {
					m.wifiNets, m.wifiNotice = scanWifi()
					m.sys = probeSystem()
				}
			} else {
				m.wifiConnect = net.SSID
				m.wifiPass = ""
				m.wifiPrompt = true
			}
		}
	case "enter":
		m.state = stepBrowser
	}
	return m, nil
}

func (m model) keyBrowser(k string) (tea.Model, tea.Cmd) {
	switch k {
	case "esc":
		m.state = stepNetwork
	case "up", "k":
		if m.browserCursor > 0 {
			m.browserCursor--
		}
	case "down", "j":
		if m.browserCursor < len(browsers)-1 {
			m.browserCursor++
		}
	case "enter":
		m.state = stepDisk
	}
	return m, nil
}

func (m model) keyDisk(k string) (tea.Model, tea.Cmd) {
	switch k {
	case "esc":
		m.state = stepBrowser
		return m, nil
	case "tab":
		m.diskFocus = (m.diskFocus + 1) % 6
		if !m.encrypt && (m.diskFocus == 2 || m.diskFocus == 3) {
			m.diskFocus = 4
		}
		return m, nil
	case "shift+tab":
		m.diskFocus = (m.diskFocus + 5) % 6
		if !m.encrypt && (m.diskFocus == 2 || m.diskFocus == 3) {
			m.diskFocus = 1
		}
		return m, nil
	}

	switch m.diskFocus {
	case 0:
		switch k {
		case "up", "k":
			if m.diskCursor > 0 {
				m.diskCursor--
			}
		case "down", "j":
			if m.diskCursor < len(m.disks)-1 {
				m.diskCursor++
			}
		case "enter":
			if len(m.disks) == 0 {
				m.errMsg = "No writable target disk found"
			} else {
				m.state = stepIdentity
			}
		}
	case 1:
		if k == "space" || k == "enter" {
			m.encrypt = !m.encrypt
		}
	case 2:
		if k == "enter" {
			m.diskFocus = 3
		} else if k == "backspace" && len(m.luksPass) > 0 {
			m.luksPass = m.luksPass[:len(m.luksPass)-1]
		} else {
			editText(&m.luksPass, k)
		}
	case 3:
		if k == "enter" {
			m.diskFocus = 4
		} else if k == "backspace" && len(m.luksConf) > 0 {
			m.luksConf = m.luksConf[:len(m.luksConf)-1]
		} else {
			editText(&m.luksConf, k)
		}
	case 4:
		if k == "space" || k == "enter" {
			m.snapshots = !m.snapshots
		}
	case 5:
		if k == "space" || k == "right" || k == "l" || k == "enter" {
			m.swapIdx = (m.swapIdx + 1) % len(swapChoices)
		} else if k == "left" || k == "h" {
			m.swapIdx = (m.swapIdx - 1 + len(swapChoices)) % len(swapChoices)
		}
	}

	if k == "ctrl+n" || (k == "enter" && m.diskFocus >= 4) {
		if err := m.validateDisk(); err != nil {
			m.errMsg = err.Error()
		} else {
			m.state = stepIdentity
		}
	}
	return m, nil
}

func (m model) keyIdentity(k string) (tea.Model, tea.Cmd) {
	switch k {
	case "esc":
		m.state = stepDisk
		return m, nil
	case "tab", "down":
		m.idFocus = (m.idFocus + 1) % 5
		return m, nil
	case "shift+tab", "up":
		m.idFocus = (m.idFocus + 4) % 5
		return m, nil
	case "enter":
		if m.idFocus < 4 {
			m.idFocus++
			return m, nil
		}
		if err := m.validateIdentity(); err != nil {
			m.errMsg = err.Error()
			return m, nil
		}
		hash, err := hashPassword(m.password)
		if err != nil {
			m.errMsg = err.Error()
			return m, nil
		}
		m.passwordHash = hash
		m.confirmText = ""
		m.state = stepReview
		return m, nil
	case "backspace":
		switch m.idFocus {
		case 0:
			if len(m.hostname) > 0 {
				m.hostname = m.hostname[:len(m.hostname)-1]
			}
		case 1:
			if len(m.username) > 0 {
				m.username = m.username[:len(m.username)-1]
			}
		case 2:
			if len(m.fullname) > 0 {
				m.fullname = m.fullname[:len(m.fullname)-1]
			}
		case 3:
			if len(m.password) > 0 {
				m.password = m.password[:len(m.password)-1]
			}
		case 4:
			if len(m.passConfirm) > 0 {
				m.passConfirm = m.passConfirm[:len(m.passConfirm)-1]
			}
		}
		return m, nil
	default:
		switch m.idFocus {
		case 0:
			editText(&m.hostname, k)
		case 1:
			editText(&m.username, k)
		case 2:
			editText(&m.fullname, k)
		case 3:
			editText(&m.password, k)
		case 4:
			editText(&m.passConfirm, k)
		}
	}
	return m, nil
}

func (m model) keyReview(k string) (tea.Model, tea.Cmd) {
	switch k {
	case "esc":
		m.state = stepIdentity
		return m, nil
	case "backspace":
		if len(m.confirmText) > 0 {
			m.confirmText = m.confirmText[:len(m.confirmText)-1]
		}
		return m, nil
	case "enter":
		if strings.ToUpper(strings.TrimSpace(m.confirmText)) != "INSTALL" {
			m.errMsg = "Type INSTALL to confirm disk erase & start installation"
			return m, nil
		}
		m.state = stepInstall
		m.stageIdx = 0
		m.stageStart = time.Now()
		m.stageTime = 0
		m.cacheBytes = 0
		m.installLog = nil
		m.installErr = ""
		st, cmd := startInstall(m)
		m.istream = st
		return m, tea.Batch(cmd, installTick(st, false))
	default:
		editText(&m.confirmText, k)
	}
	return m, nil
}

func (m model) keyDone(k string) (tea.Model, tea.Cmd) {
	switch k {
	case "up", "k", "left", "h":
		m.doneCursor = (m.doneCursor + 2) % 3
	case "down", "j", "right", "l", "tab":
		m.doneCursor = (m.doneCursor + 1) % 3
	case "1":
		m.doneCursor = 0
	case "2":
		m.doneCursor = 1
	case "3":
		m.doneCursor = 2
	case "q":
		m.exitAction = "shell"
		return m, tea.Quit
	case "enter":
		actions := []string{"reboot", "poweroff", "shell"}
		m.exitAction = actions[m.doneCursor]
		return m, tea.Quit
	}
	return m, nil
}

func editText(dst *string, k string) bool {
	if k == "space" {
		*dst += " "
		return true
	}
	if len([]rune(k)) == 1 {
		*dst += k
		return true
	}
	return false
}

func (m *model) applyLocaleFilter() {
	m.locFiltered = filterList(m.locales, m.locSearch)
	if m.locCursor >= len(m.locFiltered) {
		m.locCursor = max(0, len(m.locFiltered)-1)
	}
}

func (m *model) applyTzFilter() {
	m.tzFiltered = filterList(m.tzAll, m.tzSearch)
	if m.tzCursor >= len(m.tzFiltered) {
		m.tzCursor = max(0, len(m.tzFiltered)-1)
	}
}

func filterList(items []string, q string) []string {
	q = strings.TrimSpace(q)
	if q == "" {
		return items
	}
	matches := fuzzy.Find(q, items)
	out := make([]string, 0, len(matches))
	for _, mt := range matches {
		out = append(out, mt.Str)
	}
	return out
}

func (m model) selectedLocale() string {
	if len(m.locFiltered) > 0 && m.locCursor < len(m.locFiltered) {
		return m.locFiltered[m.locCursor]
	}
	return "en_US.UTF-8"
}

func (m model) selectedKeymap() string {
	if len(m.keymaps) > 0 && m.keymapIdx < len(m.keymaps) {
		return m.keymaps[m.keymapIdx]
	}
	return "us"
}

func (m model) selectedTimezone() string {
	if len(m.tzFiltered) > 0 && m.tzCursor < len(m.tzFiltered) {
		return m.tzFiltered[m.tzCursor]
	}
	return "Asia/Jakarta"
}

func (m model) selectedBrowser() browserChoice {
	if m.browserCursor >= 0 && m.browserCursor < len(browsers) {
		return browsers[m.browserCursor]
	}
	return browsers[0]
}

func (m model) selectedBrowserPkg() string {
	return m.selectedBrowser().pkg
}

func (m model) selectedDiskPath() string {
	if len(m.disks) > 0 && m.diskCursor < len(m.disks) {
		return m.disks[m.diskCursor].Path
	}
	return ""
}

func (m model) validateDisk() error {
	if len(m.disks) == 0 {
		return fmt.Errorf("no target disk available")
	}
	if m.encrypt {
		if len(m.luksPass) < 4 {
			return fmt.Errorf("encryption passphrase must be at least 4 characters")
		}
		if m.luksPass != m.luksConf {
			return fmt.Errorf("encryption passphrases do not match")
		}
	}
	return nil
}

func (m model) validateIdentity() error {
	h := strings.TrimSpace(m.hostname)
	u := strings.TrimSpace(m.username)
	if !validHostRe.MatchString(h) {
		return fmt.Errorf("invalid hostname (letters, digits, hyphens only)")
	}
	if !validUserRe.MatchString(u) || u == "root" {
		return fmt.Errorf("invalid username (lowercase alphanumeric, cannot be root)")
	}
	if len(m.password) < 4 {
		return fmt.Errorf("password must be at least 4 characters")
	}
	if m.password != m.passConfirm {
		return fmt.Errorf("passwords do not match")
	}
	return nil
}

// ───────────────────────── rendering (Ryoku-style sidebar + card) ─────────────────────────

func fg(c color.Color, s string) string {
	return lipgloss.NewStyle().Foreground(c).Render(s)
}

func boldFg(c color.Color, s string) string {
	return lipgloss.NewStyle().Foreground(c).Bold(true).Render(s)
}

func truncStr(s string, w int) string {
	if w <= 0 {
		return ""
	}
	if lipgloss.Width(s) <= w {
		return s
	}
	r := []rune(s)
	for len(r) > 0 && lipgloss.Width(string(r))+1 > w {
		r = r[:len(r)-1]
	}
	return string(r) + "…"
}

func (m model) activeStepIdx() int {
	for i, s := range stepMeta {
		if s.key == m.state || (m.state == stepDone && s.key == stepInstall) {
			return i
		}
	}
	return 0
}

func (m model) View() tea.View {
	w := max(m.w, 80)
	h := max(m.h, 24)

	if m.state == stepIntro {
		placed := lipgloss.Place(w, h, lipgloss.Center, lipgloss.Center, m.viewIntro(),
			lipgloss.WithWhitespaceStyle(lipgloss.NewStyle().Background(cBg)))
		v := tea.NewView(placed)
		v.AltScreen = true
		v.MouseMode = tea.MouseModeCellMotion
		v.BackgroundColor = cBg
		v.ForegroundColor = cText
		v.WindowTitle = "Tsukuyomi OS Installer"
		return v
	}

	showRail := w >= 92
	railW := 24
	totalW := min(w-4, 108)
	cardW := totalW
	if showRail {
		cardW = totalW - railW - 2
	}
	innerH := max(h-10, 14)

	header := m.renderHeader(totalW)
	body := m.renderBody(cardW-6, innerH)
	footer := m.renderFooter(totalW)

	card := lipgloss.NewStyle().
		Width(cardW).
		Height(innerH).
		Background(cSurface).
		Border(lipgloss.RoundedBorder()).
		BorderForeground(cBorder).
		Padding(1, 2).
		Render(body)

	var mainArea string
	if showRail {
		rail := m.renderSidebar(railW, innerH)
		mainArea = lipgloss.JoinHorizontal(lipgloss.Top, rail, "  ", card)
	} else {
		mainArea = card
	}

	screen := lipgloss.JoinVertical(lipgloss.Left, header, "", mainArea, "", footer)
	placed := lipgloss.Place(w, h, lipgloss.Center, lipgloss.Center, screen,
		lipgloss.WithWhitespaceStyle(lipgloss.NewStyle().Background(cBg)))

	v := tea.NewView(placed)
	v.AltScreen = true
	v.MouseMode = tea.MouseModeCellMotion
	v.BackgroundColor = cBg
	v.ForegroundColor = cText
	v.WindowTitle = "Tsukuyomi OS Installer"
	return v
}

func (m model) renderHeader(w int) string {
	title := boldFg(cCrimson, "月読") + " " + boldFg(cText, "TSUKUYOMI OS") + fg(cMuted, "  ·  INSTALLER")
	right := fg(cMuted, fmt.Sprintf("Step %d/%d", m.activeStepIdx()+1, len(stepMeta)))
	if m.dryRun {
		right = boldFg(cAmber, "[DRY-RUN]") + "  " + right
	}
	pad := max(1, w-lipgloss.Width(title)-lipgloss.Width(right))
	return title + strings.Repeat(" ", pad) + right
}

func (m model) renderSidebar(railW, innerH int) string {
	active := m.activeStepIdx()
	var lines []string
	lines = append(lines, boldFg(cMuted, "INSTALL STEPS"), "")
	for i, s := range stepMeta {
		switch {
		case i < active || m.state == stepDone:
			lines = append(lines, fg(cSage, "✓ ")+fg(cText, s.label))
		case i == active:
			lines = append(lines, boldFg(cCrimson, "▸ "+s.label))
		default:
			lines = append(lines, fg(cBorder, "· ")+fg(cMuted, s.label))
		}
	}

	lines = append(lines, "", fg(cBorder, strings.Repeat("─", railW-4)), boldFg(cMuted, "SELECTIONS"))
	summary := []struct {
		k, v string
	}{
		{"Zone", m.selectedTimezone()},
		{"Browser", m.selectedBrowser().label},
		{"Disk", m.selectedDiskPath()},
		{"User", m.username},
	}
	for _, row := range summary {
		val := row.v
		if val == "" {
			val = "—"
		}
		lines = append(lines, fg(cMuted, row.k+": ")+fg(cText, truncStr(val, railW-6-len(row.k))))
	}

	return lipgloss.NewStyle().
		Width(railW).
		Height(innerH).
		Background(cBg).
		Border(lipgloss.RoundedBorder()).
		BorderForeground(cBorder).
		Padding(1, 1).
		Render(strings.Join(lines, "\n"))
}

func (m model) renderBody(innerW, maxH int) string {
	var out string
	switch m.state {
	case stepWelcome:
		out = m.viewWelcome()
	case stepLocale:
		out = m.viewLocale(maxH - 4)
	case stepTimezone:
		out = m.viewTimezone(maxH - 4)
	case stepNetwork:
		out = m.viewNetwork(maxH - 4)
	case stepBrowser:
		out = m.viewBrowser(innerW)
	case stepDisk:
		out = m.viewDisk()
	case stepIdentity:
		out = m.viewIdentity()
	case stepReview:
		out = m.viewReview()
	case stepInstall:
		out = m.viewInstall(innerW, maxH-4)
	case stepDone:
		out = m.viewDone()
	}
	if m.errMsg != "" {
		out += "\n\n" + boldFg(cErr, "! "+m.errMsg)
	}
	return out
}

func (m model) viewIntro() string {
	bannerText := introBanner
	fullCh, emptyCh := "█", "░"
	if os.Getenv("TERM") == "dumb" {
		bannerText = "T S U K U Y O M I"
		fullCh, emptyCh = "#", "-"
	}
	banner := boldFg(cCrimson, bannerText)
	subtitle := boldFg(cText, "月読") + fg(cMuted, "  ·  TSUKUYOMI OS INSTALLER")

	const barW = 42
	filled := int(m.introRatio * float64(barW))
	if filled < 0 {
		filled = 0
	} else if filled > barW {
		filled = barW
	}
	bar := fg(cCrimson, strings.Repeat(fullCh, filled)) + fg(cBorder, strings.Repeat(emptyCh, barW-filled))
	dots := (m.introTick / 6) % 4
	status := fg(cMuted, "Preparing installer"+strings.Repeat(".", dots)+strings.Repeat(" ", 3-dots))
	hint := fg(cBorder, "Press any key to continue · Ctrl+C to quit")

	return lipgloss.JoinVertical(
		lipgloss.Center,
		banner,
		"",
		subtitle,
		"",
		bar,
		"",
		status,
		"",
		hint,
	)
}

func (m model) viewWelcome() string {
	lines := []string{
		boldFg(cCrimson, "Tsukuyomi OS Guided Installer"),
		fg(cMuted, "CachyOS base · Limine UKI · Plymouth · SDDM · Hyprland (Ryoku)"),
		"",
		kv("Firmware", m.sys.Firmware),
		kv("Processor", m.sys.CPU),
		kv("Memory", m.sys.Memory),
		kv("Network", m.sys.Network),
		"",
		fg(cText, "Included stack:"),
		fg(cMuted, "  • Kernel & Repos : CachyOS (linux-cachyos) + yay + paru"),
		fg(cMuted, "  • Desktop Shell  : Hyprland + Ryoku + Tsukuyomi lockscreen"),
		fg(cMuted, "  • CLI Toolkit    : htop, btop, neovim, ripgrep, fd, bat, eza, fzf, zoxide"),
		"",
		boldFg(cText, "Press Enter to begin installation."),
	}
	return strings.Join(lines, "\n")
}

func (m model) viewLocale(listH int) string {
	searchNote := fg(cMuted, "Filter (/): ") + fg(cText, m.locSearch)
	if m.locSearching {
		searchNote = boldFg(cCrimson, "Filter (/): ") + boldFg(cText, m.locSearch+"_")
	}
	list := renderSelectableList(m.locFiltered, m.locCursor, max(listH-5, 5))
	kmLine := fmt.Sprintf("Console Keymap (Tab): %s", boldFg(cCrimson, "< "+m.selectedKeymap()+" >"))
	if m.localePaneKey {
		kmLine = boldFg(cText, "▸ ") + kmLine
	}
	return strings.Join([]string{
		boldFg(cCrimson, "Locale & Keyboard Layout"),
		searchNote,
		"",
		list,
		"",
		kmLine,
	}, "\n")
}

func (m model) viewTimezone(listH int) string {
	searchNote := fg(cMuted, "Filter (/): ") + fg(cText, m.tzSearch)
	if m.tzSearchOn {
		searchNote = boldFg(cCrimson, "Filter (/): ") + boldFg(cText, m.tzSearch+"_")
	}
	list := renderSelectableList(m.tzFiltered, m.tzCursor, max(listH-4, 6))
	return strings.Join([]string{
		boldFg(cCrimson, "System Timezone"),
		searchNote,
		"",
		list,
	}, "\n")
}

func (m model) viewNetwork(listH int) string {
	if m.wifiPrompt {
		return strings.Join([]string{
			boldFg(cCrimson, "Connect to Wi-Fi: "+m.wifiConnect),
			"",
			fmt.Sprintf("Passphrase: %s", boldFg(cText, strings.Repeat("•", len([]rune(m.wifiPass)))+"_")),
			"",
			fg(cMuted, "Enter to connect · Esc to cancel"),
		}, "\n")
	}
	var rows []string
	for _, n := range m.wifiNets {
		mark := " "
		if n.InUse {
			mark = "*"
		}
		rows = append(rows, fmt.Sprintf("%s %-28s %3d%%  %s", mark, n.SSID, n.Signal, n.Security))
	}
	content := fg(cMuted, "No Wi-Fi networks found (Ethernet or offline install still supported).")
	if m.wifiNotice != "" {
		content = fg(cMuted, m.wifiNotice)
	}
	if len(rows) > 0 {
		content = renderSelectableList(rows, m.wifiCursor, max(listH-5, 5))
	}
	return strings.Join([]string{
		boldFg(cCrimson, "Network Status: "+m.sys.Network),
		fg(cMuted, "Press 'c' to connect selected Wi-Fi, 'r' to rescan, or Enter to continue."),
		"",
		content,
	}, "\n")
}

func (m model) viewBrowser(innerW int) string {
	lines := []string{
		boldFg(cCrimson, "Web Browser"),
		fg(cMuted, "Select the default browser to install and configure for your desktop:"),
		"",
	}
	for i, b := range browsers {
		tag := ""
		if b.recommended {
			tag = boldFg(cSage, " [Recommended]")
		}
		if i == m.browserCursor {
			lines = append(lines, boldFg(cCrimson, "▸ "+b.label)+tag)
		} else {
			lines = append(lines, fg(cText, "  "+b.label)+tag)
		}
		lines = append(lines, fg(cMuted, "    "+truncStr(b.hint, max(innerW-6, 20))))
	}
	return strings.Join(lines, "\n")
}

func (m model) viewDisk() string {
	var diskRows []string
	for _, d := range m.disks {
		diskRows = append(diskRows, fmt.Sprintf("%-14s %-8s %-24s (%s)", d.Path, d.Size, d.Model, d.Tran))
	}
	diskList := fg(cErr, "No target disk detected")
	if len(diskRows) > 0 {
		diskList = renderSelectableList(diskRows, m.diskCursor, 4)
	}

	encBox := "[ ]"
	if m.encrypt {
		encBox = "[x]"
	}
	snapBox := "[ ]"
	if m.snapshots {
		snapBox = "[x]"
	}

	lines := []string{
		boldFg(cCrimson, "Target Disk & Storage Layout"),
		fg(cMuted, "GPT (1G Limine ESP + Btrfs) · Tab moves fields · Space toggles"),
		"",
		focusLabel(m.diskFocus == 0, "Target Disk:"),
		diskList,
		"",
		focusLabel(m.diskFocus == 1, fmt.Sprintf("%s LUKS2 Disk Encryption", encBox)),
	}
	if m.encrypt {
		lines = append(lines,
			focusLabel(m.diskFocus == 2, fmt.Sprintf("  Passphrase: %s", maskInput(m.luksPass, m.diskFocus == 2))),
			focusLabel(m.diskFocus == 3, fmt.Sprintf("  Confirm   : %s", maskInput(m.luksConf, m.diskFocus == 3))),
		)
	}
	lines = append(lines,
		focusLabel(m.diskFocus == 4, fmt.Sprintf("%s Btrfs @snapshots + Limine snapshot menu", snapBox)),
		focusLabel(m.diskFocus == 5, fmt.Sprintf("Swapfile Size: < %d GiB >", swapChoices[m.swapIdx])),
	)
	return strings.Join(lines, "\n")
}

func (m model) viewIdentity() string {
	lines := []string{
		boldFg(cCrimson, "System Identity & Primary Administrator"),
		fg(cMuted, "Password is hashed in-process with SHA-512 crypt ($6$)."),
		"",
		focusLabel(m.idFocus == 0, fmt.Sprintf("Hostname  : %s", plainInput(m.hostname, m.idFocus == 0))),
		focusLabel(m.idFocus == 1, fmt.Sprintf("Username  : %s", plainInput(m.username, m.idFocus == 1))),
		focusLabel(m.idFocus == 2, fmt.Sprintf("Full Name : %s", plainInput(m.fullname, m.idFocus == 2))),
		focusLabel(m.idFocus == 3, fmt.Sprintf("Password  : %s", maskInput(m.password, m.idFocus == 3))),
		focusLabel(m.idFocus == 4, fmt.Sprintf("Confirm   : %s", maskInput(m.passConfirm, m.idFocus == 4))),
	}
	return strings.Join(lines, "\n")
}

func (m model) viewReview() string {
	encStr := "Disabled"
	if m.encrypt {
		encStr = "LUKS2 Enabled"
	}
	snapStr := "Disabled"
	if m.snapshots {
		snapStr = "Enabled (Snapper + Limine)"
	}
	lines := []string{
		boldFg(cCrimson, "Review Installation Plan"),
		"",
		kv("Locale / Keymap", fmt.Sprintf("%s · %s", m.selectedLocale(), m.selectedKeymap())),
		kv("Timezone", m.selectedTimezone()),
		kv("Web Browser", m.selectedBrowser().label+" ("+m.selectedBrowserPkg()+")"),
		kv("Target Disk", m.selectedDiskPath()+" (GPT: 1G Limine ESP + Btrfs)"),
		kv("Encryption", encStr),
		kv("Snapshots / Swap", fmt.Sprintf("%s · %d GiB swapfile", snapStr, swapChoices[m.swapIdx])),
		kv("Host / User", fmt.Sprintf("%s · %s", m.hostname, m.username)),
		kv("Desktop Stack", "CachyOS + Limine + Plymouth + SDDM + Hyprland (Ryoku)"),
		"",
		boldFg(cCrimson, "WARNING: All existing data on "+m.selectedDiskPath()+" will be erased."),
		fmt.Sprintf("Type %s and press Enter to begin: %s", boldFg(cText, "INSTALL"), boldFg(cCrimson, m.confirmText+"_")),
	}
	return strings.Join(lines, "\n")
}

func (m model) viewInstall(availW, availH int) string {
	var stageRows []string
	for i, st := range installStages {
		switch {
		case i < m.stageIdx:
			stageRows = append(stageRows, fg(cSage, "  [ok] "+st.label))
		case i == m.stageIdx:
			stageRows = append(stageRows, boldFg(cCrimson, "  [>>] "+st.label))
		default:
			stageRows = append(stageRows, fg(cMuted, "  [  ] "+st.label))
		}
	}
	status := "Stage time " + m.stageTime.String()
	if m.cacheBytes > 0 && installStages[m.stageIdx].id == "pacstrap" {
		status += fmt.Sprintf(" · %.0f MiB in download cache", float64(m.cacheBytes)/(1<<20))
	}
	var notice string
	if m.installErr != "" {
		notice = boldFg(cErr, "Installation failed: "+m.installErr+" (press Enter to return)")
	} else if m.abortArmed && time.Since(m.abortAt) <= 3*time.Second {
		notice = boldFg(cAmber, "Press Ctrl+C again within 3s to abort installation")
	}
	if notice != "" {
		notice = "\n" + ansi.Truncate(notice, availW, "…")
	}

	// Fit recent output by rendered rows so a long pacman line can't hide the latest error.
	maxLog := max(availH-len(stageRows)-3-strings.Count(notice, "\n"), 1)
	var logRows []string
	for i := len(m.installLog) - 1; i >= 0 && len(logRows) < maxLog; i-- {
		rows := strings.Split(ansi.Hardwrap(m.installLog[i], availW, true), "\n")
		for j := len(rows) - 1; j >= 0 && len(logRows) < maxLog; j-- {
			logRows = append(logRows, rows[j])
		}
	}
	slices.Reverse(logRows)
	out := strings.Join(stageRows, "\n") + "\n" + fg(cMuted, status) + "\n\n" +
		fg(cMuted, strings.Join(logRows, "\n")) + notice
	return out
}

func (m model) viewDone() string {
	opts := []string{"Reboot now", "Power off", "Exit to recovery shell"}
	var rows []string
	for i, o := range opts {
		if i == m.doneCursor {
			rows = append(rows, boldFg(cCrimson, "▸ "+o))
		} else {
			rows = append(rows, fg(cText, "  "+o))
		}
	}
	note := "Remove the live USB medium before rebooting into Limine -> Plymouth -> SDDM -> Hyprland."
	if m.dryRun {
		note = "Dry-run completed cleanly. No disk changes were written."
	}
	return strings.Join([]string{
		boldFg(cSage, "✓ Tsukuyomi OS installation complete"),
		fg(cMuted, note),
		"",
		strings.Join(rows, "\n"),
	}, "\n")
}

func (m model) renderFooter(w int) string {
	hint := "↑/↓ move · enter next · esc back · ctrl+c quit"
	switch m.state {
	case stepLocale, stepTimezone:
		hint = "↑/↓ move · / filter · tab switch · enter next · esc back"
	case stepNetwork:
		hint = "↑/↓ select · c connect · r rescan · enter next · esc back"
	case stepBrowser:
		hint = "↑/↓ choose browser · enter next · esc back"
	case stepDisk:
		hint = "tab field · space toggle · ctrl+n next · esc back"
	case stepIdentity:
		hint = "tab/↑/↓ field · enter next · esc back"
	case stepReview:
		hint = "type INSTALL · enter start · esc back"
	case stepInstall:
		hint = "installing... · ctrl+c twice to abort"
	case stepDone:
		hint = "↑/↓ select · enter confirm"
	}
	return fg(cMuted, hint)
}

func kv(k, v string) string {
	return fmt.Sprintf("%-18s %s", fg(cMuted, k+":"), fg(cText, v))
}

func focusLabel(active bool, s string) string {
	if active {
		return boldFg(cCrimson, "▸ "+s)
	}
	return fg(cText, "  "+s)
}

func plainInput(val string, active bool) string {
	if active {
		return boldFg(cText, val+"_")
	}
	return fg(cText, val)
}

func maskInput(val string, active bool) string {
	dots := strings.Repeat("•", len([]rune(val)))
	if active {
		return boldFg(cText, dots+"_")
	}
	return fg(cText, dots)
}

func renderSelectableList(items []string, cursor, height int) string {
	if len(items) == 0 {
		return fg(cMuted, "(empty)")
	}
	start := max(0, cursor-height/2)
	if start+height > len(items) {
		start = max(0, len(items)-height)
	}
	end := min(len(items), start+height)
	var out []string
	for i := start; i < end; i++ {
		if i == cursor {
			out = append(out, boldFg(cCrimson, "▸ "+items[i]))
		} else {
			out = append(out, fg(cText, "  "+items[i]))
		}
	}
	return strings.Join(out, "\n")
}

var (
	exitCommand    = exec.Command
	exitActionFile = "/run/tsukuyomi-exit-action"
)

// applyExit writes the chosen post-install action for tsukuyomi-installer-session
// and executes reboot/poweroff synchronously after Bubble Tea restores the TTY.
func applyExit(action string, dryRun bool) error {
	if dryRun || (action != "reboot" && action != "poweroff") {
		return nil
	}
	if exitActionFile != "" {
		_ = os.WriteFile(exitActionFile, []byte(action+"\n"), 0o644)
	}
	_ = exitCommand("sync").Run()
	if err := exitCommand("systemctl", action).Run(); err != nil {
		return exitCommand(action).Run()
	}
	return nil
}

func main() {
	dryRun := os.Getenv("TSUKUYOMI_DRYRUN") == "1"
	for _, arg := range os.Args[1:] {
		if arg == "--dry-run" {
			dryRun = true
		}
	}
	p := tea.NewProgram(initialModel(dryRun))
	fm, err := p.Run()
	if err != nil {
		fmt.Fprintf(os.Stderr, "tsukuyomi-tui: %v\n", err)
		os.Exit(1)
	}
	if m, ok := fm.(model); ok {
		if err := applyExit(m.exitAction, m.dryRun); err != nil {
			fmt.Fprintf(os.Stderr, "tsukuyomi-tui: %s failed: %v\n", m.exitAction, err)
			os.Exit(1)
		}
	}
}
