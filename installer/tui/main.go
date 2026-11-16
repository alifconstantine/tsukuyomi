package main

import (
	"fmt"
	"image/color"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
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

var (
	swapChoices   = []int{0, 4, 8}
	installStages = []struct {
		id    string
		label string
	}{
		{"preflight", "Pre-flight verification"},
		{"disk", "Partitioning GPT target disk"},
		{"luks", "Encryption volume setup"},
		{"filesystems", "Creating Btrfs subvolumes & mounts"},
		{"pacstrap", "Installing CachyOS & end-4 packages"},
		{"configure", "Configuring locale, user & mkinitcpio"},
		{"desktop", "Deploying end-4 shell, fastfetch & SDDM"},
		{"bootloader", "Installing Limine UKI & Plymouth splash"},
		{"finalize", "Finalizing & unmounting"},
	}
	validHostRe = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$`)
	validUserRe = regexp.MustCompile(`^[a-z_][a-z0-9_-]{0,31}$`)
)

const (
	stepWelcome  = "welcome"
	stepLocale   = "locale"
	stepTimezone = "timezone"
	stepNetwork  = "network"
	stepDisk     = "disk"
	stepIdentity = "identity"
	stepReview   = "review"
	stepInstall  = "install"
	stepDone     = "done"
)

var stepOrder = []string{
	stepWelcome,
	stepLocale,
	stepTimezone,
	stepNetwork,
	stepDisk,
	stepIdentity,
	stepReview,
	stepInstall,
}

type model struct {
	w, h   int
	dryRun bool
	state  string
	errMsg string

	sys sysSnapshot

	// Locale & keymap
	locales       []string
	locFiltered   []string
	locCursor     int
	locSearch     string
	locSearching  bool
	keymaps       []string
	keymapIdx     int
	localePaneKey bool // false=locale list, true=keymap cycle

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
	installLog []string
	installErr string
	abortArmed bool
	abortAt    time.Time
	doneCursor int
}

func initialModel(dryRun bool) model {
	locs := listLocales()
	tzs := listTimezones()
	kms := listKeymaps()
	disks := listDisks(dryRun)
	nets, wifiNote := scanWifi()

	m := model{
		dryRun:     dryRun,
		state:      stepWelcome,
		sys:        probeSystem(),
		locales:    locs,
		keymaps:    kms,
		tzAll:      tzs,
		wifiNets:   nets,
		wifiNotice: wifiNote,
		disks:      disks,
		snapshots:  true,
		swapIdx:    1, // 4 GiB default
		hostname:   "tsukuyomi",
	}
	m.applyLocaleFilter()
	m.applyTzFilter()
	return m
}

func (m model) Init() tea.Cmd { return nil }

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
		return m, nil
	case installLineMsg:
		line := string(msg)
		if strings.HasPrefix(line, "@@TSUKUYOMI_STEP ") {
			id := strings.TrimSpace(strings.TrimPrefix(line, "@@TSUKUYOMI_STEP "))
			for i, st := range installStages {
				if st.id == id {
					m.stageIdx = i
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
		m.state = stepDisk
	}
	return m, nil
}

func (m model) keyDisk(k string) (tea.Model, tea.Cmd) {
	switch k {
	case "esc":
		m.state = stepNetwork
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
		m.installLog = nil
		m.installErr = ""
		st, cmd := startInstall(m)
		m.istream = st
		return m, cmd
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
	case "enter":
		if m.dryRun || m.doneCursor == 2 {
			return m, tea.Quit
		}
		if m.doneCursor == 0 {
			_ = exec.Command("systemctl", "reboot").Start()
		} else if m.doneCursor == 1 {
			_ = exec.Command("systemctl", "poweroff").Start()
		}
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

// ───────────────────────── rendering ─────────────────────────

func fg(c color.Color, s string) string {
	return lipgloss.NewStyle().Foreground(c).Render(s)
}

func boldFg(c color.Color, s string) string {
	return lipgloss.NewStyle().Foreground(c).Bold(true).Render(s)
}

func (m model) View() tea.View {
	w := max(m.w, 80)
	h := max(m.h, 24)
	contentW := min(w-4, 92)

	header := m.renderHeader(contentW)
	rail := m.renderStepRail(contentW)
	body := m.renderBody(contentW, max(h-12, 10))
	footer := m.renderFooter(contentW)

	panel := lipgloss.NewStyle().
		Width(contentW).
		Background(cSurface).
		Border(lipgloss.RoundedBorder()).
		BorderForeground(cBorder).
		Padding(1, 2).
		Render(body)

	screen := lipgloss.JoinVertical(lipgloss.Left, header, rail, "", panel, "", footer)
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
	modeTag := ""
	if m.dryRun {
		modeTag = boldFg(cAmber, "[DRY-RUN]")
	}
	pad := max(1, w-lipgloss.Width(title)-lipgloss.Width(modeTag))
	return title + strings.Repeat(" ", pad) + modeTag
}

func (m model) renderStepRail(w int) string {
	names := []string{"Welcome", "Locale", "Zone", "Net", "Disk", "Account", "Review", "Install"}
	active := 0
	for i, s := range stepOrder {
		if s == m.state || (m.state == stepDone && s == stepInstall) {
			active = i
			break
		}
	}
	var parts []string
	for i, n := range names {
		switch {
		case i < active:
			parts = append(parts, fg(cSage, "✓ "+n))
		case i == active:
			parts = append(parts, boldFg(cCrimson, "▸ "+n))
		default:
			parts = append(parts, fg(cMuted, "· "+n))
		}
	}
	line := strings.Join(parts, fg(cBorder, "  "))
	if lipgloss.Width(line) > w {
		return boldFg(cCrimson, fmt.Sprintf("Step %d/%d: %s", active+1, len(names), names[active]))
	}
	return line
}

func (m model) renderBody(w, maxH int) string {
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
	case stepDisk:
		out = m.viewDisk()
	case stepIdentity:
		out = m.viewIdentity()
	case stepReview:
		out = m.viewReview()
	case stepInstall:
		out = m.viewInstall(maxH - 4)
	case stepDone:
		out = m.viewDone()
	}
	if m.errMsg != "" {
		out += "\n\n" + boldFg(cErr, "! "+m.errMsg)
	}
	return out
}

func (m model) viewWelcome() string {
	lines := []string{
		boldFg(cText, "Tsukuyomi OS Guided Installer"),
		fg(cMuted, "CachyOS base · Limine UKI · Plymouth · SDDM · Hyprland (end-4)"),
		"",
		kv("Firmware", m.sys.Firmware),
		kv("Processor", m.sys.CPU),
		kv("Memory", m.sys.Memory),
		kv("Network", m.sys.Network),
		"",
		fg(cMuted, "Press Enter to configure keyboard, timezone, disk, and user account."),
	}
	return strings.Join(lines, "\n")
}

func (m model) viewLocale(listH int) string {
	searchNote := fg(cMuted, "Filter (/): ") + fg(cText, m.locSearch)
	if m.locSearching {
		searchNote = boldFg(cCrimson, "Filter (/): ") + boldFg(cText, m.locSearch+"_")
	}
	list := renderSelectableList(m.locFiltered, m.locCursor, max(listH-4, 5))
	kmLine := fmt.Sprintf("Console Keymap (Tab): %s", boldFg(cCrimson, "< "+m.selectedKeymap()+" >"))
	if m.localePaneKey {
		kmLine = boldFg(cText, "▸ ") + kmLine
	}
	return strings.Join([]string{
		boldFg(cText, "Locale & Keyboard Layout"),
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
	list := renderSelectableList(m.tzFiltered, m.tzCursor, max(listH-3, 6))
	return strings.Join([]string{
		boldFg(cText, "System Timezone"),
		searchNote,
		"",
		list,
	}, "\n")
}

func (m model) viewNetwork(listH int) string {
	if m.wifiPrompt {
		return strings.Join([]string{
			boldFg(cText, "Connect to Wi-Fi: "+m.wifiConnect),
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
		content = renderSelectableList(rows, m.wifiCursor, max(listH-4, 5))
	}
	return strings.Join([]string{
		boldFg(cText, "Network Status: "+m.sys.Network),
		fg(cMuted, "Press 'c' to connect selected Wi-Fi, 'r' to rescan, or Enter to continue."),
		"",
		content,
	}, "\n")
}

func (m model) viewDisk() string {
	var diskRows []string
	for _, d := range m.disks {
		diskRows = append(diskRows, fmt.Sprintf("%-14s %-8s %-28s (%s)", d.Path, d.Size, d.Model, d.Tran))
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
		boldFg(cText, "Target Disk & Storage Layout (GPT + Limine ESP + Btrfs)"),
		fg(cMuted, "Tab moves fields · Space toggles · Ctrl+N or Enter on final row continues"),
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
		boldFg(cText, "System Identity & Primary Administrator"),
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
		boldFg(cText, "Review Installation Plan"),
		"",
		kv("Locale / Keymap", fmt.Sprintf("%s · %s", m.selectedLocale(), m.selectedKeymap())),
		kv("Timezone", m.selectedTimezone()),
		kv("Target Disk", m.selectedDiskPath()+" (GPT: 1G Limine ESP + Btrfs)"),
		kv("Encryption", encStr),
		kv("Snapshots / Swap", fmt.Sprintf("%s · %d GiB swapfile", snapStr, swapChoices[m.swapIdx])),
		kv("Host / User", fmt.Sprintf("%s · %s", m.hostname, m.username)),
		kv("Desktop Stack", "CachyOS + Limine + Plymouth + SDDM + Hyprland (end-4)"),
		"",
		boldFg(cCrimson, "WARNING: All existing data on "+m.selectedDiskPath()+" will be erased."),
		fmt.Sprintf("Type %s and press Enter to begin: %s", boldFg(cText, "INSTALL"), boldFg(cCrimson, m.confirmText+"_")),
	}
	return strings.Join(lines, "\n")
}

func (m model) viewInstall(availH int) string {
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
	logLines := m.installLog
	maxLog := max(availH-len(stageRows)-3, 4)
	if len(logLines) > maxLog {
		logLines = logLines[len(logLines)-maxLog:]
	}
	out := strings.Join(stageRows, "\n") + "\n\n" + boldFg(cMuted, "Log:") + "\n" + fg(cMuted, strings.Join(logLines, "\n"))
	if m.installErr != "" {
		out += "\n\n" + boldFg(cErr, "Installation failed: "+m.installErr+" (press Enter to return)")
	} else if m.abortArmed && time.Since(m.abortAt) <= 3*time.Second {
		out += "\n\n" + boldFg(cAmber, "Press Ctrl+C again within 3s to abort installation")
	}
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

func main() {
	dryRun := os.Getenv("TSUKUYOMI_DRYRUN") == "1"
	for _, arg := range os.Args[1:] {
		if arg == "--dry-run" {
			dryRun = true
		}
	}
	p := tea.NewProgram(initialModel(dryRun))
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "tsukuyomi-tui: %v\n", err)
		os.Exit(1)
	}
}
