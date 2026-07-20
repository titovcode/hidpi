import CoreGraphics
import Foundation

// MARK: - Display override (EDID scale-resolutions)
//
// macOS reads per-display override plists from
//   /Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<vid>/DisplayProductID-<pid>
// A `scale-resolutions` array there lets us inject extra logical resolutions
// (including HiDPI ones the runtime never generated). This is the same method
// RDM's "Edit..." menu uses. It requires root and a reboot, and on Apple
// Silicon it is not guaranteed to be honored by the display pipeline.

// Encoding flags, matching RDM's Resolution.swift.
private let kFlagHiDPI: UInt64 = 0x0000_0001_0000_0000
private let kFlagUnknown1: UInt64 = 0x0000_0000_0020_0000
private let kFlagRetina: UInt64 = 0x0000_0008_0000_0000

struct DisplayOverride {
    let vendorID: UInt32
    let productID: UInt32
    let name: String

    static let base = "/Library/Displays/Contents/Resources/Overrides"

    var dir: String { "\(Self.base)/DisplayVendorID-\(String(vendorID, radix: 16))" }
    var path: String { "\(dir)/DisplayProductID-\(String(productID, radix: 16))" }

    init(_ display: CGDirectDisplayID) {
        vendorID = CGDisplayVendorNumber(display)
        productID = CGDisplayModelNumber(display)
        name = displayName(display) ?? "Display"
    }
}

private func be(_ n: UInt32) -> [UInt8] {
    [UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]
}

// Build a scale-resolutions entry for a logical WxH. For HiDPI the stored
// pixel size is doubled and the HiDPI flags are appended.
func encodeScaleResolution(width: Int, height: Int, hidpi: Bool, retina: Bool) -> Data {
    var w = UInt32(width), h = UInt32(height)
    var flags: UInt64 = 0
    if hidpi {
        w *= 2; h *= 2
        flags |= kFlagHiDPI | kFlagUnknown1
        if retina { flags |= kFlagRetina }
    }
    var bytes = be(w) + be(h)
    if flags != 0 {
        bytes += be(UInt32(flags >> 32))
        if flags & 0xffff_ffff != 0 { bytes += be(UInt32(flags & 0xffff_ffff)) }
    }
    return Data(bytes)
}

// Inverse of encode: report the logical size and whether it is HiDPI.
func decodeScaleResolution(_ data: Data) -> (w: Int, h: Int, hidpi: Bool, retina: Bool)? {
    let bytes = [UInt8](data)
    guard bytes.count >= 8 else { return nil }
    func u32(_ o: Int) -> UInt32 {
        (UInt32(bytes[o]) << 24) | (UInt32(bytes[o + 1]) << 16)
            | (UInt32(bytes[o + 2]) << 8) | UInt32(bytes[o + 3])
    }
    let pw = Int(u32(0)), ph = Int(u32(4))
    var flags: UInt64 = 0
    if bytes.count >= 12 { flags |= UInt64(u32(8)) << 32 }
    if bytes.count >= 16 { flags |= UInt64(u32(12)) }
    let hidpi = flags & kFlagHiDPI != 0
    let retina = flags & kFlagRetina != 0
    return (hidpi ? pw / 2 : pw, hidpi ? ph / 2 : ph, hidpi, retina)
}

private func loadOverride(_ path: String) -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: path),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
          let dict = plist as? [String: Any]
    else { return [:] }
    return dict
}

private func scaleResolutions(_ dict: [String: Any]) -> [Data] {
    (dict["scale-resolutions"] as? [Any])?.compactMap { $0 as? Data } ?? []
}

// MARK: - Commands

func cmdOverride() {
    switch args.dropFirst().first {
    case "list", .none:
        overrideList()
    case "add":
        overrideAdd()
    case "clear":
        overrideClear()
    default:
        errWrite("Unknown override subcommand. Use: list | add | clear\n")
        exit(1)
    }
}

private func overrideList() {
    guard let display = resolveDisplay() else { exit(1) }
    let ov = DisplayOverride(display)
    print("Display: \(ov.name)")
    print("VendorID: 0x\(String(ov.vendorID, radix: 16))  ProductID: 0x\(String(ov.productID, radix: 16))")
    print("Override: \(ov.path)")

    guard FileManager.default.fileExists(atPath: ov.path) else {
        print("No override file yet.")
        return
    }
    let entries = scaleResolutions(loadOverride(ov.path))
    if entries.isEmpty { print("scale-resolutions: (none)"); return }
    print("scale-resolutions (\(entries.count)):")
    for d in entries {
        if let r = decodeScaleResolution(d) {
            var tags = r.hidpi ? "  [HiDPI]" : ""
            if r.retina { tags += "  [Retina]" }
            print(String(format: "  %dx%d%@", r.w, r.h, tags))
        }
    }
}

private func overrideAdd() {
    guard let display = resolveDisplay() else { exit(1) }
    guard let w = intOption(["-w", "--width"]), let h = intOption(["-h", "--height"]) else {
        errWrite("Error: -w and -h are required (logical resolution to add)\n")
        exit(1)
    }
    guard w > 0, h > 0, w <= 15360, h <= 8640 else {
        errWrite("Error: width and height must be between 1 and 15360 (got \(w)x\(h))\n")
        exit(1)
    }
    let hidpi = !hasFlag(["--no-hidpi"])
    let retina = hasFlag(["--retina"])
    let dryRun = hasFlag(["--dry-run"])

    let ov = DisplayOverride(display)
    var dict = loadOverride(ov.path)
    dict["DisplayProductName"] = ov.name
    dict["DisplayVendorID"] = Int(ov.vendorID)
    dict["DisplayProductID"] = Int(ov.productID)

    let entry = encodeScaleResolution(width: w, height: h, hidpi: hidpi, retina: retina)
    var entries = scaleResolutions(dict)
    if entries.contains(entry) {
        print("Already present: \(w)x\(h)\(hidpi ? " HiDPI" : "")")
        return
    }
    entries.append(entry)
    dict["scale-resolutions"] = entries

    let hex = entry.map { String(format: "%02x", $0) }.joined()
    print("Adding \(w)x\(h)\(hidpi ? " HiDPI" : "") to \(ov.name)")
    print("  entry bytes: \(hex)")
    print("  file: \(ov.path)")

    guard let out = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    else {
        errWrite("Error: could not serialize plist\n")
        exit(1)
    }

    if dryRun {
        print("--- dry run, plist that WOULD be written ---")
        print(String(data: out, encoding: .utf8) ?? "(binary)")
        return
    }

    guard geteuid() == 0 else {
        errWrite(
            "Error: writing \(ov.path) needs root.\n  Re-run: sudo hidpi override add -d \(intOption(["-d", "--display"]) ?? 0) -w \(w) -h \(h)\(hidpi ? "" : " --no-hidpi")\(retina ? " --retina" : "")\n")
        exit(1)
    }

    do {
        if FileManager.default.fileExists(atPath: ov.path) {
            let bak = ov.path + ".hidpi-backup"
            if !FileManager.default.fileExists(atPath: bak) {
                do {
                    try FileManager.default.copyItem(atPath: ov.path, toPath: bak)
                } catch {
                    errWrite("Warning: could not create backup \(bak): \(error.localizedDescription)\n")
                    // Continue anyway — the user explicitly asked for this.
                }
            }
        }
        try FileManager.default.createDirectory(
            atPath: ov.dir, withIntermediateDirectories: true)
        try out.write(to: URL(fileURLWithPath: ov.path), options: .atomic)
        print("Written. Reboot to apply, then run 'hidpi modes -d 0 --hidpi'.")
        print("Revert with: sudo hidpi override clear -d \(intOption(["-d", "--display"]) ?? 0)")
    } catch {
        errWrite("Error: \(error.localizedDescription)\n")
        exit(1)
    }
}

private func overrideClear() {
    guard let display = resolveDisplay() else { exit(1) }
    let ov = DisplayOverride(display)

    guard FileManager.default.fileExists(atPath: ov.path) else {
        print("No override file to remove: \(ov.path)")
        return
    }
    guard geteuid() == 0 else {
        errWrite(
            "Error: removing \(ov.path) needs root.\n  Re-run: sudo hidpi override clear -d \(intOption(["-d", "--display"]) ?? 0)\n")
        exit(1)
    }
    do {
        let bak = ov.path + ".hidpi-backup"
        if FileManager.default.fileExists(atPath: bak) {
            try FileManager.default.removeItem(atPath: ov.path)
            try FileManager.default.moveItem(atPath: bak, toPath: ov.path)
            print("Restored original override from backup: \(ov.path)")
        } else {
            try FileManager.default.removeItem(atPath: ov.path)
            print("Removed \(ov.path)")
        }
        print("Reboot to apply.")
    } catch {
        errWrite("Error: \(error.localizedDescription)\n")
        exit(1)
    }
}
