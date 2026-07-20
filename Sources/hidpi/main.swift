import AppKit
import CDisplayPrivate
import CoreGraphics
import Foundation

// MARK: - Helpers

func errWrite(_ msg: String) {
    FileHandle.standardError.write(Data((msg).utf8))
}

// MARK: - Display enumeration

func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

// Human-readable monitor model (e.g. "P27QBA-RX"), resolved via NSScreen.
// Returns nil if AppKit can't map the display (no window-server session).
func displayName(_ display: CGDirectDisplayID) -> String? {
    if #available(macOS 10.15, *) {
        for s in NSScreen.screens {
            let num = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value ?? 0
            if num == display { return s.localizedName }
        }
    }
    return nil
}

func allModes(_ display: CGDirectDisplayID) -> [modes_D4] {
    let n = Int(hidpi_number_of_modes(display))
    guard n > 0 else { return [] }
    var modes = [modes_D4](repeating: modes_D4(), count: n)
    hidpi_copy_all_modes(display, &modes, Int32(n))
    return modes
}

func bitsPerPixel(_ m: modes_D4) -> Int {
    switch m.derived.depth {
    case 1: return 8
    case 2: return 16
    case 4: return 32
    default: return 32
    }
}

// Backing pixels actually rendered by the GPU (2W x 2H for a scale-2 HiDPI
// mode). For a 1x mode this equals the logical size.
func pixelSize(_ m: modes_D4) -> (w: Int, h: Int) {
    (Int(m.derived.pixelWidth), Int(m.derived.pixelHeight))
}

// IOKit display-mode flags (bits in modes_D4.flags at offset 0x4).
let kDisplayModeDefaultFlag: UInt32 = 0x4
let kDisplayModeNativeFlag: UInt32 = 0x0200_0000

func isDefaultMode(_ m: modes_D4) -> Bool { (m.derived.flags & kDisplayModeDefaultFlag) != 0 }
func isNativeMode(_ m: modes_D4) -> Bool { (m.derived.flags & kDisplayModeNativeFlag) != 0 }

// The panel's true pixel resolution: the backing size macOS marks as default,
// else the largest native-flagged backing, else the largest backing overall.
func nativePixels(_ modes: [modes_D4]) -> (w: Int, h: Int) {
    if let d = modes.first(where: isDefaultMode) { return pixelSize(d) }
    let native = modes.filter(isNativeMode).map(pixelSize)
    let pool = native.isEmpty ? modes.map(pixelSize) : native
    return pool.max { $0.w * $0.h < $1.w * $1.h } ?? (0, 0)
}

// How a HiDPI render maps onto the panel: exact 2x (sharp), supersampled
// (rendered above native and downscaled), or soft (below native). Empty for
// non-HiDPI or when the native size is unknown.
func sharpnessLabel(pixelW: Int, pixelH: Int, native: (w: Int, h: Int)) -> String {
    guard native.w > 0 else { return "" }
    if pixelW == native.w && pixelH == native.h { return "sharp" }
    return pixelW * pixelH > native.w * native.h ? "supersampled" : "soft"
}

func describe(_ m: modes_D4) -> String {
    let hidpi = m.derived.density >= 2.0 ? "  [HiDPI]" : ""
    let p = pixelSize(m)
    let render = m.derived.density >= 2.0 ? "  → \(p.w)x\(p.h)" : ""
    return String(
        format: "%dx%d  scale=%.1f%@  %dHz  %dbpp%@",
        m.derived.width, m.derived.height, m.derived.density, render,
        m.derived.freq, bitsPerPixel(m), hidpi)
}

// MARK: - Argument parsing

let args = Array(CommandLine.arguments.dropFirst())

func optionValue(_ names: [String]) -> String? {
    for name in names {
        if let i = args.firstIndex(of: name), i + 1 < args.count {
            let next = args[i + 1]
            // Don't consume another flag as the value.
            if next.hasPrefix("-") { continue }
            return next
        }
    }
    return nil
}

func hasFlag(_ names: [String]) -> Bool { names.contains { args.contains($0) } }

func intOption(_ names: [String]) -> Int? { optionValue(names).flatMap { Int($0) } }
func doubleOption(_ names: [String]) -> Double? { optionValue(names).flatMap { Double($0) } }

func resolveDisplay() -> CGDirectDisplayID? {
    let displays = onlineDisplays()
    guard !displays.isEmpty else {
        errWrite("Error: no online displays\n")
        return nil
    }
    let idx = intOption(["-d", "--display"]) ?? 0
    guard idx >= 0, idx < displays.count else {
            errWrite("Error: display index \(idx) out of range (0..\(displays.count - 1))\n")
        return nil
    }
    return displays[idx]
}

func usage() {
    print("""
    hidpi — enable HiDPI on a physical display via private CoreGraphics API

    USAGE:
      hidpi                            Interactive: pick a HiDPI resolution
      hidpi pick [--all]               Same; --all shows every mode
      hidpi list                       List online displays
      hidpi modes [-d N] [--hidpi]     List modes for display N (default 0)
      hidpi set  -d N -w W -h H [-s S] [-b BITS]
      hidpi set  -d N --mode IDX       Switch to mode by index
      hidpi reset [-d N]               Restore the macOS default mode
      hidpi override list [-d N]       Show the display's EDID override
      hidpi override add -d N -w W -h H [--no-hidpi] [--retina] [--dry-run]
                                       Inject a scaled resolution (sudo, reboot)
      hidpi override clear [-d N]      Remove the override we wrote (sudo)
      hidpi install                    Copy binary to /usr/local/bin (needs sudo)

    OPTIONS:
      -d, --display N    Display index (default 0)
      -w, --width  W     Target width in pixels
      -h, --height H     Target height in pixels
      -s, --scale  S     Scale factor (default 2.0 = HiDPI)
      -b, --bits   B     Color depth 16 or 32 (default: keep current)
          --mode  IDX    Select a mode by its list index directly
          --hidpi        (modes only) show only HiDPI modes
      -a, --all          (pick only) include non-HiDPI and tiny modes
    """)
}

// MARK: - Commands

func cmdList() {
    let displays = onlineDisplays()
    if displays.isEmpty { print("No online displays."); return }
    for (i, d) in displays.enumerated() {
        let cur = Int(hidpi_current_mode(d))
        var m = modes_D4()
        hidpi_get_mode(d, Int32(cur), &m)
        let main = CGDisplayIsMain(d) != 0 ? "  (main)" : ""
        let name = displayName(d).map { "\($0)  " } ?? ""
        print("Display \(i): \(name)id=\(d)\(main)  \(describe(m))")
    }
}

func cmdModes() {
    guard let display = resolveDisplay() else { exit(1) }
    let onlyHidpi = hasFlag(["--hidpi"])
    let modes = allModes(display)
    if modes.isEmpty { print("No modes reported for this display."); return }
    for (i, m) in modes.enumerated() {
        if onlyHidpi && m.derived.density < 2.0 { continue }
        print(String(format: "  [%3d] %@", i, describe(m)))
    }
}

func cmdSet() {
    guard let display = resolveDisplay() else { exit(1) }
    let modes = allModes(display)
    guard !modes.isEmpty else {
        errWrite("Error: no modes for this display\n")
        exit(1)
    }

    var target = -1

    if let idx = intOption(["--mode"]) {
        guard idx >= 0, idx < modes.count else {
            errWrite("Error: mode index out of range\n")
            exit(1)
        }
        target = idx
    } else {
        // Defaults pulled from the current mode where unspecified.
        let cur = Int(hidpi_current_mode(display))
        var curMode = modes_D4()
        hidpi_get_mode(display, Int32(cur), &curMode)

        let width = intOption(["-w", "--width"]) ?? Int(curMode.derived.width)
        let height = intOption(["-h", "--height"]) ?? Int(curMode.derived.height)
        let scale = doubleOption(["-s", "--scale"]) ?? 2.0
        let bits = intOption(["-b", "--bits"])

        for (i, m) in modes.enumerated() {
            if Int(m.derived.width) != width { continue }
            if Int(m.derived.height) != height { continue }
            if abs(Double(m.derived.density) - scale) > 0.01 { continue }
            if let b = bits, bitsPerPixel(m) != b { continue }
            target = i
            break
        }

        if target == -1 {
            errWrite(
                "Error: no matching mode \(width)x\(height) scale=\(scale). Run 'hidpi modes -d ... --hidpi' to see what's available.\n")
            exit(1)
        }
    }

    let err = hidpi_set_mode(display, Int32(target))
    if err != 0 {
        errWrite("Error: CGCompleteDisplayConfiguration returned \(err)\n")
        exit(1)
    }
    var m = modes_D4()
    hidpi_get_mode(display, Int32(target), &m)
    print("Set mode [\(target)]: \(describe(m))")
}

func cmdReset() {
    guard let display = resolveDisplay() else { exit(1) }
    let modes = allModes(display)
    guard !modes.isEmpty else {
        errWrite("Error: no modes for this display\n")
        exit(1)
    }
    guard let target = modes.firstIndex(where: isDefaultMode) else {
        errWrite("Error: no default mode reported for this display\n")
        exit(1)
    }
    let err = hidpi_set_mode(display, Int32(target))
    if err != 0 {
        errWrite("Error: CGCompleteDisplayConfiguration returned \(err)\n")
        exit(1)
    }
    var m = modes_D4()
    hidpi_get_mode(display, Int32(target), &m)
    print("Reset to default mode [\(target)]: \(describe(m))")
}

// MARK: - Interactive picker

// A resolution+scale, with every refresh rate it supports.
struct ResGroup {
    let width: Int
    let height: Int
    let density: Double
    let bpp: Int
    let pixelW: Int
    let pixelH: Int
    var isNative: Bool
    var freqs: [(freq: Int, index: Int)]  // highest first

    var area: Int { width * height }
    var isHiDPI: Bool { density >= 2.0 }
}

// Group modes by resolution+scale, collect refresh rates, sort so the biggest
// workspace comes first. HiDPI variants sort above their 1x twin.
func groupModes(_ modes: [modes_D4]) -> [ResGroup] {
    var byKey: [String: ResGroup] = [:]
    for (i, m) in modes.enumerated() {
        let w = Int(m.derived.width), h = Int(m.derived.height)
        let d = Double(m.derived.density)
        // Round to 2 decimal places to avoid phantom groups from float noise.
        let dKey = String(format: "%.2f", d)
        let key = "\(w)x\(h)@\(dKey)"
        let p = pixelSize(m)
        if byKey[key] == nil {
            byKey[key] = ResGroup(width: w, height: h, density: d, bpp: bitsPerPixel(m),
                                  pixelW: p.w, pixelH: p.h, isNative: false, freqs: [])
        }
        if isNativeMode(m) { byKey[key]!.isNative = true }
        byKey[key]!.freqs.append((Int(m.derived.freq), i))
    }
    for key in byKey.keys {
        // Sort by rate desc, then drop duplicate rates (keep first index).
        let sorted = byKey[key]!.freqs.sorted { $0.freq > $1.freq }
        var seen = Set<Int>()
        byKey[key]!.freqs = sorted.filter { seen.insert($0.freq).inserted }
    }
    return byKey.values.sorted {
        if $0.area != $1.area { return $0.area > $1.area }
        return $0.density > $1.density
    }
}

// MARK: - Arrow-key menu

// Global terminal state for signal-safe restore (SIGTERM/SIGINT).
private var savedTermios: termios?
private var altScreenActive = false
// Set by SIGWINCH handler so the main loop knows to re-render.
private var resizePending = false

private func emergencyRestoreTerminal() {
    if altScreenActive {
        FileHandle.standardError.write("\u{1B}[?25h\u{1B}[?1049l".data(using: .utf8) ?? Data())
        fflush(stderr)
    }
    if var orig = savedTermios {
        tcsetattr(STDIN_FILENO, TCSANOW, &orig)
    }
}

private func handleSignal(_ sig: Int32) {
    if sig == SIGWINCH {
        resizePending = true
        return
    }
    emergencyRestoreTerminal()
    // Re-raise with default handler so the process exits with the correct status.
    signal(sig, SIG_DFL)
    raise(sig)
}

// Install a signal handler without SA_RESTART so that blocking read() calls
// are interrupted (return -1/EINTR) when the signal is delivered.
private func installSignalHandler(_ sig: Int32) {
    var sa = sigaction()
    sa.__sigaction_u.__sa_handler = handleSignal
    sigemptyset(&sa.sa_mask)
    sa.sa_flags = 0  // No SA_RESTART — interrupt read().
    sigaction(sig, &sa, nil)
}

// Terminal size (falls back to 80x24 if it can't be queried).
func termSize() -> (cols: Int, rows: Int) {
    var w = winsize()
    if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w) == 0, w.ws_col > 0 {
        return (Int(w.ws_col), Int(w.ws_row) > 0 ? Int(w.ws_row) : 24)
    }
    return (80, 24)
}

func termCols() -> Int { termSize().cols }

// Visible length of a string, ignoring ANSI escape sequences.
func visibleLength(_ s: String) -> Int {
    var count = 0, inEsc = false
    for ch in s {
        if inEsc {
            if ch.isLetter { inEsc = false }
            continue
        }
        if ch == "\u{1B}" { inEsc = true; continue }
        count += 1
    }
    return count
}

// Pip-Boy palette: phosphor green on black, with a brighter tone for accents.
enum Pip {
    static let green = "\u{1B}[38;5;40m"
    static let bright = "\u{1B}[1;38;5;46m"
    static let dim = "\u{1B}[38;5;34m"
    static let inverse = "\u{1B}[7m"
    static let reset = "\u{1B}[0m"
}

// Interactive single-choice menu: ↑/↓ or k/j to move, Enter to select,
// Esc/q to cancel. Returns the chosen index, or nil if cancelled.
// Falls back to numeric prompt when stdin/stdout isn't a TTY (pipe, script).
func arrowMenu(title: String, items: [String], initial: Int = 0) -> Int? {
    let interactive = isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
    if !interactive {
        print(title)
        for (i, s) in items.enumerated() { print("  \(i + 1)) \(s)") }
        print("Enter number (blank to cancel): ", terminator: "")
        guard let raw = readLine()?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let n = Int(raw), n >= 1, n <= items.count else { return nil }
        return n - 1
    }

    var orig = termios()
    tcgetattr(STDIN_FILENO, &orig)
    savedTermios = orig
    var raw = orig
    // Clear ISIG too, so Ctrl-C arrives as a byte (0x03) we can handle and
    // restore the terminal, instead of SIGINT killing us mid-alt-screen.
    raw.c_lflag &= ~(UInt(ECHO | ICANON | ISIG))
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    // Enter the alternate screen buffer (like vim/less) and hide the cursor.
    // This isolates the menu from the scrollback, so redraws can't drift or
    // duplicate the header, and the terminal is left clean on exit.
    print("\u{1B}[?1049h\u{1B}[?25l", terminator: "")
    altScreenActive = true

    // Restore terminal on SIGTERM/SIGINT so a kill or shutdown doesn't leave
    // the user in alt-screen with a hidden cursor.
    // Use sigaction() without SA_RESTART so blocking read() is interrupted.
    var prevTermAction = sigaction()
    sigaction(SIGTERM, nil, &prevTermAction)
    var prevIntAction = sigaction()
    sigaction(SIGINT, nil, &prevIntAction)
    var prevWinchAction = sigaction()
    sigaction(SIGWINCH, nil, &prevWinchAction)
    installSignalHandler(SIGTERM)
    installSignalHandler(SIGINT)
    installSignalHandler(SIGWINCH)

    func restore() {
        // Leave alt screen, show cursor, restore terminal mode.
        print("\u{1B}[?25h\u{1B}[?1049l", terminator: "")
        fflush(stdout)
        tcsetattr(STDIN_FILENO, TCSANOW, &orig)
        // Restore previous signal handlers.
        sigaction(SIGTERM, &prevTermAction, nil)
        sigaction(SIGINT, &prevIntAction, nil)
        sigaction(SIGWINCH, &prevWinchAction, nil)
        altScreenActive = false
        savedTermios = nil
    }

    // True if a byte is available on stdin within timeoutMs. Lets us tell a
    // bare Esc (no follow-up bytes) from an arrow escape sequence, whose bytes
    // arrive together, without blocking on a second read.
    func stdinReady(_ timeoutMs: Int32) -> Bool {
        var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        return poll(&fds, 1, timeoutMs) > 0
    }

    var sel = min(max(initial, 0), items.count - 1)
    var off = 0  // index of the first visible item (scroll offset)

    func render() {
        // Home the cursor to (1,1) and clear the whole alt screen each frame.
        print("\u{1B}[H\u{1B}[2J", terminator: "")

        let g = Pip.green, b = Pip.bright, d = Pip.dim, r = Pip.reset
        let header = "Enable macOS HiDPI"
        let subheader = "Reveal hidden 2x HiDPI resolutions your Mac keeps out of Settings"
        let footer = "[↑/↓] MOVE   [ENTER] SELECT   [ESC] EXIT"
        let titleLines = title.components(separatedBy: "\n")

        // Inner width fits the widest line; capped to the terminal, floored so
        // the frame never collapses on tiny windows.
        var content = max(visibleLength(header), visibleLength(subheader), footer.count)
        for t in titleLines { content = max(content, visibleLength(t)) }
        for s in items { content = max(content, visibleLength(s) + 2) }  // + marker
        let (cols, rows) = termSize()
        let inner = min(content + 2, max(24, cols - 2))
        let avail = inner - 2

        // Scrolling viewport: reserve rows for the fixed chrome, show as many
        // items as fit, and keep the selection in view. Markers on the item
        // separators signal that more items exist above/below.
        let chrome = 8 + titleLines.count  // borders, header, title, footer
        let maxVisible = max(3, rows - chrome)
        if items.count > maxVisible {
            if sel < off { off = sel }
            if sel >= off + maxVisible { off = sel - maxVisible + 1 }
            off = min(max(0, off), items.count - maxVisible)
        } else {
            off = 0
        }
        let end = min(items.count, off + maxVisible)

        func bar(_ l: String, _ fill: Character, _ rt: String, label: String = "") -> String {
            var chars = Array(String(repeating: fill, count: inner))
            if !label.isEmpty {
                for (i, ch) in Array(" \(label) ").enumerated() where 2 + i < chars.count {
                    chars[2 + i] = ch
                }
            }
            return b + l + String(chars) + rt + r
        }
        // Row whose content is plain (no ANSI): pad/truncate to fit exactly.
        func row(_ text: String, selected: Bool = false, color: String = g) -> String {
            var c = text
            if c.count > avail { c = String(c.prefix(avail)) }
            let pad = String(repeating: " ", count: avail - c.count)
            let body = selected ? "\(Pip.inverse)\(b) \(c)\(pad) \(r)" : "\(color) \(c)\(pad) "
            return "\(b)║\(r)\(body)\(b)║\(r)"
        }
        // Row whose content may contain ANSI (title/banner): measure visibly.
        func rowANSI(_ text: String) -> String {
            let vlen = visibleLength(text)
            let pad = vlen < avail ? String(repeating: " ", count: avail - vlen) : ""
            return "\(b)║\(r) \(g)\(text)\(g)\(pad) \(b)║\(r)"
        }

        print(bar("╔", "═", "╗"))
        print(row(header, color: b))
        print(row(subheader, color: d))
        print(bar("╠", "═", "╣"))
        for t in titleLines { print(rowANSI(t)) }
        print(bar("╟", "─", "╢", label: off > 0 ? "▲ \(off) more" : ""))
        for i in off..<end {
            print(row((i == sel ? "▶ " : "  ") + items[i], selected: i == sel))
        }
        let belowCount = items.count - end
        print(bar("╠", "═", "╣", label: belowCount > 0 ? "▼ \(belowCount) more" : ""))
        print(row(footer, color: d))
        print(bar("╚", "═", "╝"), terminator: "")
        fflush(stdout)
    }

    render()
    var buf = [UInt8](repeating: 0, count: 3)
    while true {
        let n = read(STDIN_FILENO, &buf, 1)
        if n <= 0 {
            // EINTR means a signal was delivered (e.g. SIGWINCH).
            if resizePending { resizePending = false; render(); continue }
            restore(); print(); return nil
        }
        if resizePending { resizePending = false; render(); continue }
        let c = buf[0]
        switch c {
        case 0x1B:  // ESC — bare Esc, or the start of an arrow-key sequence
            // Arrow sequences deliver their bytes together; a lone Esc has
            // nothing following. Poll briefly so a bare Esc exits at once
            // instead of blocking on a second read until the next keypress.
            if !stdinReady(30) { restore(); print(); return nil }
            let n2 = read(STDIN_FILENO, &buf, 1)
            if n2 <= 0 { restore(); print(); return nil }
            if buf[0] == UInt8(ascii: "[") {
                let n3 = read(STDIN_FILENO, &buf, 1)
                if n3 <= 0 { restore(); print(); return nil }
                if buf[0] == UInt8(ascii: "A") { sel = (sel - 1 + items.count) % items.count }
                if buf[0] == UInt8(ascii: "B") { sel = (sel + 1) % items.count }
                render()
            } else {
                restore(); print(); return nil  // bare Esc
            }
        case UInt8(ascii: "k"): sel = (sel - 1 + items.count) % items.count; render()
        case UInt8(ascii: "j"): sel = (sel + 1) % items.count; render()
        case UInt8(ascii: "q"), 0x03: restore(); print(); return nil  // q or Ctrl-C
        case 0x0A, 0x0D: restore(); print(); return sel  // Enter
        default: break
        }
    }
}

func applyMode(_ display: CGDirectDisplayID, _ index: Int) {
    print(applyModeStatus(display, index))
}

// Applies a mode and returns a human-readable status line (no printing, so it
// can be shown inside the interactive menu's alt-screen).
@discardableResult
func applyModeStatus(_ display: CGDirectDisplayID, _ index: Int) -> String {
    let err = hidpi_set_mode(display, Int32(index))
    if err != 0 {
        return "Error: CGCompleteDisplayConfiguration returned \(err)"
    }
    var m = modes_D4()
    hidpi_get_mode(display, Int32(index), &m)
    return "Applied: \(describe(m))"
}

func cmdInteractive() {
    let showAll = hasFlag(["--all", "-a"])
    let displays = onlineDisplays()
    if displays.isEmpty { print("No online displays."); return }

    // Pick display: auto if one, otherwise ask.
    let displayIdx: Int
    if displays.count == 1 {
        displayIdx = 0
    } else {
        print("Displays:")
        for (i, d) in displays.enumerated() {
            let cur = Int(hidpi_current_mode(d))
            var m = modes_D4()
            hidpi_get_mode(d, Int32(cur), &m)
            let main = CGDisplayIsMain(d) != 0 ? " (main)" : ""
            let name = displayName(d).map { "\($0)  " } ?? ""
            print("  \(i)) \(name)id=\(d)\(main)  \(describe(m))")
        }
        print("Select display [0]: ", terminator: "")
        displayIdx = Int(readLine()?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        guard displayIdx >= 0, displayIdx < displays.count else {
            print("Invalid display."); exit(1)
        }
    }
    let display = displays[displayIdx]

    let all = allModes(display)
    guard !all.isEmpty else { print("No modes for this display."); exit(1) }

    var groups = groupModes(all)
    // Default view: every HiDPI mode. --all also includes non-HiDPI (1x) modes.
    if !showAll {
        groups = groups.filter { $0.isHiDPI }
    }
    guard !groups.isEmpty else {
        print("No HiDPI modes found. Try 'hidpi pick --all' to see every mode.")
        return
    }

    let hint = showAll ? "" : "  (--all for every mode)"
    let dispLabel = displayName(display).map { "\u{1B}[32m\($0)\u{1B}[0m, " } ?? ""
    // Panel's true pixel resolution, used to classify each HiDPI render as
    // exact 2x, supersampled (downscaled), or below native.
    let native = nativePixels(all)

    // Loop: after applying a mode, return to the list so several can be tried.
    // Esc/q exits. Labels are rebuilt each pass so ← current stays accurate.
    var banner: String? = nil
    while true {
        let cur = Int(hidpi_current_mode(display))
        var curPick = 0
        let labels: [String] = groups.enumerated().map { (n, g) in
            let isCurrent = g.freqs.contains { $0.index == cur }
            if isCurrent { curPick = n }
            let hidpi = g.isHiDPI ? "  [HiDPI]" : ""
            let render = g.isHiDPI ? "  → \(g.pixelW)x\(g.pixelH)" : ""
            var quality = ""
            if g.isHiDPI {
                let s = sharpnessLabel(pixelW: g.pixelW, pixelH: g.pixelH, native: native)
                if !s.isEmpty { quality = "  \(s)" }
            }
            var tag = ""
            if g.isHiDPI && g.isNative { tag = "  ★ sharp 2x" }
            if isCurrent { tag += "  ← current" }
            let hz = g.freqs.count > 1
                ? "up to \(g.freqs.first!.freq)Hz (\(g.freqs.count) rates)"
                : "\(g.freqs.first!.freq)Hz"
            return String(format: "%dx%d  scale=%.1f%@  %@  %dbpp%@%@%@",
                          g.width, g.height, g.density, render, hz, g.bpp, hidpi, quality, tag)
        }

        var title = "Resolution for \(dispLabel)display \(displayIdx):\(hint)"
        if let b = banner { title = "\u{1B}[32m\(b)\u{1B}[0m\n\n" + title }

        guard let choice = arrowMenu(title: title, items: labels, initial: curPick) else {
            if let b = banner { print(b) }  // echo last result to normal screen
            print("Done."); return
        }
        let group = groups[choice]

        let targetIndex: Int
        if group.freqs.count == 1 {
            targetIndex = group.freqs[0].index
        } else {
            let rateLabels = group.freqs.enumerated().map { (n, f) in
                n == 0 ? "\(f.freq)Hz  (highest)" : "\(f.freq)Hz"
            }
            guard let rchoice = arrowMenu(
                title: "Refresh rate for \(group.width)x\(group.height):",
                items: rateLabels, initial: 0)
            else { continue }  // back to resolution list
            targetIndex = group.freqs[rchoice].index
        }
        banner = applyModeStatus(display, targetIndex)
    }
}

func cmdInstall() {
    let src = CommandLine.arguments[0]
    let dest = "/usr/local/bin/hidpi"
    // Resolve the real binary path (arguments[0] may be relative).
    let resolved = URL(fileURLWithPath: src).standardizedFileURL.path
    print("Installing to \(dest) ...")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    p.arguments = ["install", "-m", "755", resolved, dest]
    do {
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus == 0 {
            print("Done. Run 'hidpi' from anywhere.")
        } else {
            print("Install failed (exit \(p.terminationStatus)).")
            exit(1)
        }
    } catch {
        print("Could not launch installer: \(error.localizedDescription)")
        exit(1)
    }
}

// MARK: - Dispatch

switch args.first {
case "list":
    cmdList()
case "modes":
    cmdModes()
case "set":
    cmdSet()
case "reset":
    cmdReset()
case "override":
    cmdOverride()
case "pick", .none:
    cmdInteractive()
case "install":
    cmdInstall()
case "help", "-h", "--help":
    usage()
default:
    errWrite("Unknown command: \(args.first!)\n")
    usage()
    exit(1)
}
