// syshud: a small system overlay that sits under Apple's Metal Performance HUD while a game
// runs. Metal's HUD covers frame rate and GPU timing; this adds what it cannot show: CPU and
// GPU utilisation, memory, the OS, and the Wine runner and graphics backend in use.
//
//   syshud [--offset <points>] [--label <text>]... [--pid <pid>] [--app <bundle id>]
//
// --offset  distance from the top of the screen, so the panel lands below the Metal HUD
// --label   extra static lines (runner, backend)
// --pid     exit when this process goes away (the compat tool's run script)
// --app     only show while the game is frontmost (its launcher bundle id, or any Wine process)
//
// The window ignores the mouse, joins every Space and floats over full-screen windows.

import AppKit
import IOKit

// MARK: - samplers

final class CPUSampler {
    private var previous: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []

    // Busy share of all cores since the last call, 0...1.
    func sample() -> Double {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var current: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []
        for cpu in 0..<Int(count) {
            let base = cpu * Int(CPU_STATE_MAX)
            current.append((UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])),
                            UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])),
                            UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])),
                            UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))))
        }
        defer { previous = current }
        guard previous.count == current.count else { return 0 }
        var busy: UInt64 = 0, total: UInt64 = 0
        for (now, before) in zip(current, previous) {
            let b = (now.user &- before.user) &+ (now.system &- before.system) &+ (now.nice &- before.nice)
            busy &+= b
            total &+= b &+ (now.idle &- before.idle)
        }
        return total == 0 ? 0 : Double(busy) / Double(total)
    }
}

// GPU utilisation from the accelerator's PerformanceStatistics ("Device Utilization %").
func gpuUtilisation() -> Double? {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
    else { return nil }
    defer { IOObjectRelease(iterator) }
    var result: Double?
    var service = IOIteratorNext(iterator)
    while service != 0 {
        if let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                       kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
           let value = stats["Device Utilization %"] as? NSNumber {
            result = max(result ?? 0, value.doubleValue / 100)
        }
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
    return result
}

// Memory in use the way Activity Monitor counts it: app + wired + compressed.
func memoryUsed() -> UInt64 {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    let page = UInt64(vm_kernel_page_size)
    let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
    return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
}

func thermalLabel() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "?"
    }
}

func osLabel() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    var build = [CChar](repeating: 0, count: 32)
    var size = build.count
    sysctlbyname("kern.osversion", &build, &size, nil, 0)
    return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) (\(String(cString: build)))"
}

func chipLabel() -> String {
    var buf = [CChar](repeating: 0, count: 128)
    var size = buf.count
    sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
    let cores = ProcessInfo.processInfo.activeProcessorCount
    return "\(String(cString: buf)) · \(cores) cores"
}

// MARK: - window

final class HUDView: NSView {
    var lines: [(String, String)] = []
    private let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
    private let pad: CGFloat = 6
    private let lineHeight: CGFloat = 13

    var preferredSize: NSSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let width = lines.map { ($0.0 + "  " + $0.1).size(withAttributes: attrs).width }.max() ?? 100
        return NSSize(width: ceil(width) + pad * 2 + 8, height: CGFloat(lines.count) * lineHeight + pad * 2)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A layer-backed background: drawing it in draw(_:) leaves a borderless, non-opaque
        // panel see-through.
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.82).cgColor
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let key: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(calibratedWhite: 0.75, alpha: 1)]
        let val: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        for (i, line) in lines.enumerated() {
            let y = bounds.height - pad - CGFloat(i + 1) * lineHeight + 2
            line.0.draw(at: NSPoint(x: pad, y: y), withAttributes: key)
            let w = line.1.size(withAttributes: val).width
            line.1.draw(at: NSPoint(x: bounds.width - pad - w, y: y), withAttributes: val)
        }
    }
}

final class HUD: NSObject {
    private let window: NSPanel
    private let view = HUDView()
    private let cpu = CPUSampler()
    private let staticLines: [(String, String)]
    private let topOffset: CGFloat
    private let watchPid: pid_t?
    private let appID: String?
    private let memTotal = ProcessInfo.processInfo.physicalMemory

    init(offset: CGFloat, labels: [String], pid: pid_t?, app: String?) {
        topOffset = offset
        watchPid = pid
        appID = app
        var fixed: [(String, String)] = [("OS", osLabel()), ("Chip", chipLabel())]
        for l in labels {
            if let c = l.firstIndex(of: ":") {
                fixed.append((String(l[..<c]), String(l[l.index(after: c)...]).trimmingCharacters(in: .whitespaces)))
            }
        }
        staticLines = fixed
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = view
        _ = cpu.sample()
        refresh()
        window.orderFrontRegardless()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
    }

    // A Wine game is not the launcher bundle as far as AppKit is concerned: CrossOver's naming
    // hack runs it from a winetemp-* link named after the .exe, without a bundle identifier.
    private func gameIsFrontmost() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        if front.bundleIdentifier == appID { return true }
        let paths = [front.executableURL?.path, front.bundleURL?.path].compactMap { $0 }
        return paths.contains { $0.contains("/winetemp-") || $0.contains("/notproton/launchers/") }
    }

    private func refresh() {
        if let pid = watchPid, kill(pid, 0) != 0 { NSApp.terminate(nil) }
        if appID != nil, !gameIsFrontmost() {
            window.orderOut(nil)
            return
        }
        if !window.isVisible { window.orderFrontRegardless() }
        let gb = { (v: UInt64) in String(format: "%.1f", Double(v) / 1_073_741_824) }
        var lines: [(String, String)] = [
            ("CPU", String(format: "%3.0f %%", cpu.sample() * 100)),
            ("GPU", gpuUtilisation().map { String(format: "%3.0f %%", $0 * 100) } ?? "n/a"),
            ("RAM", "\(gb(memoryUsed())) / \(gb(memTotal)) GB"),
            ("Thermal", thermalLabel()),
        ]
        lines += staticLines
        view.lines = lines
        let size = view.preferredSize
        let screen = NSScreen.screens.first ?? NSScreen.main!
        let frame = screen.frame
        let origin = NSPoint(x: frame.maxX - size.width - 8, y: frame.maxY - topOffset - size.height)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        view.needsDisplay = true
    }
}

// MARK: - main

var offset: CGFloat = 40
var labels: [String] = []
var pid: pid_t?
var appID: String?
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--offset": offset = CGFloat(Double(args.next() ?? "") ?? 40)
    case "--label": if let l = args.next() { labels.append(l) }
    case "--pid": pid = pid_t(args.next() ?? "")
    case "--app": appID = args.next()
    default: break
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let hud = HUD(offset: offset, labels: labels, pid: pid, app: appID)
signal(SIGTERM) { _ in exit(0) }
app.run()
