import AppKit
import Darwin
import Foundation
import UserNotifications

private let stripID = NSTouchBarItem.Identifier("local.agents.usagetouchbar.strip")
private enum Runtime {
    // Test mode only: the absolute folder that holds verification artifacts, from USAGE_TEST_ROOT.
    static let work = ProcessInfo.processInfo.environment["USAGE_TEST_ROOT"] ?? ""
    static func guarded(_ path: String) -> String {
        guard work.hasPrefix("/") else { fatalError("USAGE_TEST_ROOT must be an absolute path") }
        let root = URL(fileURLWithPath: work).resolvingSymlinksInPath().standardizedFileURL.path
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard path.hasPrefix("/"), url.path.hasPrefix(root + "/") else { fatalError("Verification paths must be inside execution artifacts") }
        return url.path
    }
    #if PROVIDER_TEST
    static let script = guarded(ProcessInfo.processInfo.environment["USAGE_TEST_READER"] ?? "")
    static let config = guarded(ProcessInfo.processInfo.environment["USAGE_TEST_CONFIG"] ?? "")
    static let state = guarded(ProcessInfo.processInfo.environment["USAGE_TEST_STATE"] ?? "")
    static let cache: String = {
        let data = try! Data(contentsOf: URL(fileURLWithPath: config))
        let row = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        return guarded(row["cache_dir"] as! String)
    }()
    #else
    // build-provider.sh records the reader's absolute path; the reader keeps its cache beside itself.
    static let script = Bundle.main.object(forInfoDictionaryKey: "UsageReaderPath") as? String ?? ""
    static let state = NSHomeDirectory() + "/Library/Application Support/UsageTouchBar"
    static let cache = (script as NSString).deletingLastPathComponent + "/cache"
    #endif
    static let ledger = URL(fileURLWithPath: state + "/notifications.json")
    static var events: URL {
        #if PROVIDER_TEST
        return URL(fileURLWithPath: state + "/events.json")
        #else
        return URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/UsageTouchBar/events.json")
        #endif
    }
}
private let scriptPath = Runtime.script
private let harnessPollSeconds: TimeInterval = 2
// Re-presenting the system modal bar dismisses native HUD popups (brightness, volume, sliders),
// so only reclaim the overlay after it has stayed covered for this long.
private let reclaimGraceSeconds: TimeInterval = 10
private let harnessNames: Set<String> = ["grok", "claude", "codex"]
private let harnessBundles: Set<String> = [
    "com.anthropic.claudefordesktop",
    "com.openai.codex",
    "com.openai.chat",
]

private func loadDFR() -> Bool {
    let path = "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation"
    return dlopen(path, RTLD_NOW) != nil
}

private func dfrSetPresence(_ identifier: NSTouchBarItem.Identifier, _ on: Bool) {
    typealias Fn = @convention(c) (CFString, Bool) -> Void
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "DFRElementSetControlStripPresenceForIdentifier")
            ?? {
                let handle = dlopen(
                    "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation",
                    RTLD_NOW
                )
                return handle.flatMap { dlsym($0, "DFRElementSetControlStripPresenceForIdentifier") }
            }()
    else { return }
    let fn = unsafeBitCast(sym, to: Fn.self)
    fn(identifier.rawValue as CFString, on)
}

private func dfrCloseBox(_ on: Bool) {
    typealias Fn = @convention(c) (Bool) -> Void
    guard let handle = dlopen(
        "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation",
        RTLD_NOW
    ), let sym = dlsym(handle, "DFRSystemModalShowsCloseBoxWhenFrontMost") else { return }
    unsafeBitCast(sym, to: Fn.self)(on)
}

private func addSystemTrayItem(_ item: NSTouchBarItem) {
    let sel = NSSelectorFromString("addSystemTrayItem:")
    guard NSTouchBarItem.responds(to: sel) else { return }
    NSTouchBarItem.perform(sel, with: item)
}

private func presentBar(_ bar: NSTouchBar, strip: NSTouchBarItem.Identifier) {
    let sel = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
    guard NSTouchBar.responds(to: sel) else { return }
    NSTouchBar.perform(sel, with: bar, with: strip.rawValue)
}

private func dismissBar(_ bar: NSTouchBar) {
    let sel = NSSelectorFromString("dismissSystemModalTouchBar:")
    guard NSTouchBar.responds(to: sel) else { return }
    NSTouchBar.perform(sel, with: bar)
}

private func parseColor(_ raw: String?) -> NSColor {
    let parts = (raw ?? "")
        .split(separator: ",")
        .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count >= 3 else {
        return NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)
    }
    let alpha = parts.count > 3 ? parts[3] / 255.0 : 1
    return NSColor(srgbRed: parts[0] / 255.0, green: parts[1] / 255.0, blue: parts[2] / 255.0, alpha: alpha)
}

private struct Meter {
    var pct: Double?
    var end: String
    var resetsAt: TimeInterval?
    var color: NSColor
    var fetchedAt: Date? = nil
    var observedAt: Date? = nil
    var freshnessBasis = "unknown"
    var isFresh = false
}

private struct Provider {
    var name: String
    var five: Meter
    var week: Meter
    var fetchedAt: Date? = nil
    var error: String? = nil
    var retryAt: Date? = nil
    var source: String? = nil
    var fetchError: String? = nil
    var readingSource: String? = nil
    var pollInterval: TimeInterval = 60
    var nextRefreshAt: Date? = nil
    var recoveryState = "normal"
    var recoverySuccesses = 0
    var currentFailure: String? = nil
    var loading = false
}

private func providerDate(_ provider: Provider) -> Date? {
    let meters = [provider.five, provider.week].filter { $0.pct != nil }
    guard !meters.isEmpty, meters.allSatisfy({ $0.fetchedAt != nil }) else { return nil }
    return meters.compactMap { $0.fetchedAt }.min()
}

private func healthLabel(_ provider: Provider, now: TimeInterval) -> String? {
    if provider.loading && providerDate(provider) == nil { return "Loading" }
    switch provider.currentFailure ?? provider.fetchError ?? provider.error {
    case "access_denied": return "Access denied"
    case "sign_in_required", "sign_in_expired": return "Reader"
    case "rate_limited": return "Wait"
    default: break
    }
    guard let date = providerDate(provider) else { return "↻" }
    let age = max(0, now - date.timeIntervalSince1970)
    guard age > provider.pollInterval + 5 || !provider.five.isFresh || !provider.week.isFresh else { return nil }
    let minutes = Int(age / 60)
    return minutes >= 60 ? "↻ \(minutes / 60)h" : "↻ \(minutes)m"
}

private func healthDescription(_ provider: Provider, now: TimeInterval) -> String {
    if provider.loading && providerDate(provider) == nil { return "\(provider.name): loading usage" }
    let state: String
    switch provider.currentFailure ?? provider.fetchError ?? provider.error {
    case "sign_in_required": state = "usage reader credential unavailable"
    case "sign_in_expired": state = "usage reader credential expired"
    case "access_denied": state = "usage access denied"
    case "rate_limited":
        state = "usage endpoint throttled; retry in \(countdown(to: [provider.retryAt, provider.nextRefreshAt].compactMap { $0 }.max()?.timeIntervalSince1970, now: now) ?? "a moment")"
    case "transport_timeout", "renewal_transport_timeout": state = "usage request timed out; retained reading"
    case "malformed_response", "renewal_malformed_response", "partial_response": state = "usage response incomplete or invalid"
    case "operation_timeout", "budget_timeout", "app_timeout": state = "usage read timed out; result uncertain"
    case "network_error": state = "connection failed; retrying"
    case "usage_unavailable": state = "usage unavailable; retrying"
    default: state = healthLabel(provider, now: now) == nil ? "up to date" : "waiting for fresh usage"
    }
    let ages = [("5-hour", provider.five), ("weekly", provider.week)].map { label, meter in
        guard meter.freshnessBasis == "api_acquisition", let date = meter.fetchedAt, date.timeIntervalSince1970 <= now else { return "\(label) age unknown" }
        return "\(label) \(Int(now-date.timeIntervalSince1970))s old"
    }.joined(separator: "; ")
    let next = [provider.retryAt, provider.nextRefreshAt].compactMap { $0 }.max()
    let retry = next.map { "; next attempt in \(Int(max(0, $0.timeIntervalSince1970 - now)))s" } ?? "; next attempt unknown"
    let recovery = provider.recoveryState == "recovering" ? "; stabilizing (\(provider.recoverySuccesses)/3 complete readings)" : ""
    return "\(provider.name): \(state); \(ages)\(recovery)\(retry)"
}

private func emptyMeter() -> Meter {
    Meter(pct: nil, end: "", resetsAt: nil, color: NSColor(srgbRed: 0.60, green: 0.60, blue: 0.60, alpha: 1))
}

private func snapshotDate(_ raw: Any?) -> Date? {
    guard let value = raw as? Double, value.isFinite, value > 0 else { return nil }
    return Date(timeIntervalSince1970: value)
}

private let touchStripWidth: CGFloat = 900
private let weekSeconds: TimeInterval = 7 * 86400
private let limitRed = NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1)
private let staleAmber = NSColor(srgbRed: 1.0, green: 0.80, blue: 0.0, alpha: 1)

private func markColor(_ name: String) -> NSColor {
    name.lowercased() == "claude"
        ? NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        : NSColor(white: 0.91, alpha: 1)
}

private func countdown(to stamp: TimeInterval?, now: TimeInterval) -> String? {
    guard let stamp else { return nil }
    let seconds = max(0, Int(stamp - now))
    let hours = seconds / 3600
    let minutes = seconds % 3600 / 60
    return hours > 0 ? String(format: "%dh %02dm", hours, minutes) : "\(minutes)m"
}

private let weekdayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE h:mma"
    formatter.amSymbol = "am"
    formatter.pmSymbol = "pm"
    return formatter
}()

private func stripGlyph(_ top: Meter, _ bottom: Meter) -> NSImage {
    NSImage(size: NSSize(width: 24, height: 14), flipped: false) { _ in
        for (meter, y) in [(top, CGFloat(8.5)), (bottom, CGFloat(1.5))] {
            let track = NSRect(x: 0, y: y, width: 24, height: 4)
            NSColor.white.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            guard let pct = meter.pct, pct > 0 else { continue }
            var fill = track
            fill.size.width = max(4, min(24, 24 * CGFloat(pct) / 100))
            meter.color.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
        }
        return true
    }
}

private final class UsageStripView: NSView {
    var claude = Provider(name: "Claude", five: emptyMeter(), week: emptyMeter())
    var codex = Provider(name: "Codex", five: emptyMeter(), week: emptyMeter())
    var onClick: (() -> Void)?
    private var pulsing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: touchStripWidth, height: 30))
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: touchStripWidth, height: 30)
    }

    func show(claude: Provider?, codex: Provider?) -> [TimeInterval] {
        if let claude { self.claude = claude }
        if let codex { self.codex = codex }
        needsDisplay = true
        return [self.claude.five.resetsAt, self.claude.week.resetsAt, self.codex.five.resetsAt, self.codex.week.resetsAt]
            .compactMap { $0 }
    }

    override func draw(_ dirtyRect: NSRect) {
        let fonts = stripFonts()
        let now = Date().timeIntervalSince1970
        // The system-modal bar is narrower than the item (the close box and collapsed
        // Control Strip take the ends), so lay out against what is actually on screen.
        let width = visibleRect.width > 0 ? min(bounds.width, visibleRect.width) : bounds.width
        let gap: CGFloat = 12
        let claudeFixed = layout(claude, x: 0, width: width, barW: 0, fonts: fonts, now: now, draw: false)
        let codexFixed = layout(codex, x: 0, width: width, barW: 0, fonts: fonts, now: now, draw: false)
        let bars = CGFloat(claudeFixed.bars + codexFixed.bars)
        let budget = width - gap - claudeFixed.width - codexFixed.width
        let barW = bars > 0 ? min(160, max(18, floor(budget / bars))) : 0
        let claudeW = claudeFixed.width + barW * CGFloat(claudeFixed.bars)
        let codexX = claudeW + gap
        layout(claude, x: 0, width: claudeW, barW: barW, fonts: fonts, now: now, draw: true)
        layout(codex, x: codexX, width: width - codexX, barW: barW, fonts: fonts, now: now, draw: true)
        if pulsing {
            NSColor.white.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        pulsing = true
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.pulsing = false
            self?.needsDisplay = true
        }
        onClick?()
    }

    private struct StripFonts {
        var name: NSFont
        var label: NSFont
        var number: NSFont
        var time: NSFont
        var limit: NSFont
    }

    private func stripFonts() -> StripFonts {
        StripFonts(
            name: NSFont.systemFont(ofSize: 12, weight: .semibold),
            label: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
            number: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold),
            time: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            limit: NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        )
    }

    /// Lays out one provider left to right. With `draw: false` it only measures:
    /// the returned width excludes the pills, and `bars` says how many pills share `barW`.
    @discardableResult
    private func layout(
        _ provider: Provider, x originX: CGFloat, width: CGFloat, barW: CGFloat,
        fonts: StripFonts, now: TimeInterval, draw: Bool
    ) -> (width: CGFloat, bars: Int) {
        let rect = NSRect(x: originX, y: 0, width: width, height: bounds.height)
        let health = healthLabel(provider, now: now)
        if draw {
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            if health != nil { NSGraphicsContext.current?.cgContext.setAlpha(0.55) }
        }
        defer { if draw { NSGraphicsContext.current?.restoreGraphicsState() } }
        let dim = NSColor.white.withAlphaComponent(0.62)
        let faint = NSColor.white.withAlphaComponent(0.42)
        let mid = rect.midY
        let barH: CGFloat = 6
        var bars = 0
        var x = originX + 4

        func text(_ string: String, _ font: NSFont, _ color: NSColor, kern: CGFloat = 0) -> CGFloat {
            if draw {
                return drawText(string, at: NSPoint(x: x, y: baseline(font, mid: mid)), font: font, color: color, kern: kern)
            }
            return textWidth(string, font, kern: kern)
        }

        if draw {
            markColor(provider.name).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: mid - 4, width: 8, height: 8), xRadius: 2, yRadius: 2).fill()
        }
        x += 12
        x += text(provider.name, fonts.name, .white) + 8
        for (index, (label, meter, weekly)) in [("5H", provider.five, false), ("7D", provider.week, true)].enumerated() {
            if index > 0 { x += 10 }
            // Segments vs. ticked pill already tell 5h from week; the label returns only when a meter is replaced by "Limit".
            if let pct = meter.pct, pct >= 100 {
                x += text(label, fonts.label, faint, kern: 0.6) + 4
                x += text("Limit", fonts.limit, limitRed) + 5
                x += text(backText(meter, weekly: weekly, now: now), fonts.time, dim)
            } else if !weekly {
                // 5h window: five thin segments, each 20% of the window, so the weekly pills get the width.
                if draw { drawSegments(meter, x: x, mid: mid) }
                x += segmentsWidth + 5
            } else {
                if draw {
                    drawBar(meter, in: NSRect(x: x, y: mid - barH / 2, width: barW, height: barH), tick: elapsedFraction(meter, now: now))
                }
                bars += 1
                x += barW + 5
            }
            if meter.pct.map({ $0 < 100 }) ?? true {
                x += text(percentText(meter), fonts.number, meter.pct == nil ? dim : meter.color)
                if let when = timeText(meter, weekly: weekly, now: now) {
                    x += 4
                    x += text(when, fonts.time, dim)
                }
            }
        }
        if let health {
            x += 6
            if draw { NSGraphicsContext.current?.cgContext.setAlpha(1) }
            x += text(health, fonts.time, staleAmber)
        }
        x += 4
        return (x - originX - barW * CGFloat(bars), bars)
    }

    private func timeText(_ meter: Meter, weekly: Bool, now: TimeInterval) -> String? {
        // An empty weekly `end` means the script hides that clock (Claude); keep it hidden.
        if weekly { return meter.end.isEmpty ? nil : meter.end }
        return countdown(to: meter.resetsAt, now: now) ?? (meter.end.isEmpty ? nil : meter.end)
    }

    private func backText(_ meter: Meter, weekly: Bool, now: TimeInterval) -> String {
        if !weekly, let left = countdown(to: meter.resetsAt, now: now) { return left }
        if !meter.end.isEmpty { return meter.end }
        guard let stamp = meter.resetsAt else { return "" }
        return weekdayFormatter.string(from: Date(timeIntervalSince1970: stamp))
    }

    private let segmentsWidth: CGFloat = 5 * 3 + 4 * 2

    private func drawSegments(_ meter: Meter, x: CGFloat, mid: CGFloat) {
        let lit = Int(ceil((meter.pct ?? 0) / 20))
        for i in 0..<5 {
            let rect = NSRect(x: x + CGFloat(i) * 5, y: mid - 6, width: 3, height: 12)
            (i < lit ? meter.color : NSColor.white.withAlphaComponent(0.16)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
    }

    private func elapsedFraction(_ meter: Meter, now: TimeInterval) -> CGFloat? {
        guard let stamp = meter.resetsAt else { return nil }
        return CGFloat(min(1, max(0, 1 - (stamp - now) / weekSeconds)))
    }

    /// Baseline that centers cap-height glyphs (digits, "5H", "Claude") on `mid`, the pills' center line.
    private func baseline(_ font: NSFont, mid: CGFloat) -> CGFloat {
        (mid - font.capHeight / 2).rounded()
    }

    private func percentText(_ meter: Meter) -> String {
        meter.pct.map { String(format: "%.0f%%", $0.rounded()) } ?? "—"
    }

    private func drawBar(_ meter: Meter, in rect: NSRect, tick: CGFloat?) {
        let radius = rect.height / 2
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        if let pct = meter.pct, pct > 0 {
            let fraction = CGFloat(min(100, max(0, pct))) / 100
            let fillW = min(rect.width, max(radius * 2, rect.width * fraction))
            meter.color.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: fillW, height: rect.height), xRadius: radius, yRadius: radius).fill()
        }
        guard let tick else { return }
        // Pace tick: how much of the week has passed. A fill past it is spending faster than the week.
        let tickRect = NSRect(x: rect.minX + rect.width * tick - 1, y: rect.minY - 3, width: 2, height: rect.height + 6)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: tickRect.insetBy(dx: -1, dy: -0.5), xRadius: 1.5, yRadius: 1.5).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: tickRect, xRadius: 1, yRadius: 1).fill()
    }

    private func textWidth(_ text: String, _ font: NSFont, kern: CGFloat = 0) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font, .kern: kern]).width)
    }

    @discardableResult
    private func drawText(_ text: String, at point: NSPoint, font: NSFont, color: NSColor, kern: CGFloat = 0) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
        // Without .usesLineFragmentOrigin the rect origin is the baseline; draw(at:) would use the line's bottom.
        (text as NSString).draw(with: NSRect(origin: point, size: .zero), options: [], attributes: attrs)
        return ceil((text as NSString).size(withAttributes: attrs).width)
    }
}

private func lastComponent(_ path: String) -> String {
    URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
        .lastPathComponent
        .lowercased()
}

// Drain output while running, then terminate, kill if needed, and reap on timeout.
nonisolated private func runOutput(_ executable: String, _ arguments: [String], timeout: Double) -> Data? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executable)
    proc.arguments = arguments
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardInput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return nil }
    // asyncAfter adds proportional scheduling leeway (up to 9s at this 90s
    // utility deadline). A one-shot source keeps the watchdog's leeway explicit.
    let watchdog = DispatchSource.makeTimerSource(queue: .global())
    watchdog.setEventHandler {
        if proc.isRunning {
            proc.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
        }
    }
    watchdog.schedule(deadline: .now() + timeout, leeway: .milliseconds(50))
    watchdog.resume()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    watchdog.cancel()
    return proc.terminationStatus == 0 ? data : nil
}

nonisolated private func cliProviders() -> Set<String>? {
    guard let data = runOutput("/bin/ps", ["-axo", "comm="], timeout: 1.5) else { return nil }
    let text = String(data: data, encoding: .utf8) ?? ""
    return Set(text.split(whereSeparator: \.isNewline).map { lastComponent(String($0)) }.filter { harnessNames.contains($0) })
}

@MainActor
final class Agent: NSObject, NSApplicationDelegate, NSTouchBarDelegate {
    private var statusItem: NSStatusItem?
    private var bar: NSTouchBar?
    private var stripItem: NSCustomTouchBarItem?
    private var usageItem: NSCustomTouchBarItem?
    private var usageView: UsageStripView?
    private let usageID = NSTouchBarItem.Identifier("local.agents.usagetouchbar.usage")
    private var providerTimers: [String: Timer] = [:]
    private var cacheWatcher: DispatchSourceFileSystemObject?
    private var cacheDebounce: DispatchWorkItem?
    private var observingCache = false
    private var notifications = UsageNotifications(ledgerURL: Runtime.ledger)
    private var notificationItem: NSMenuItem?
    private var harnessTimer: Timer?
    private var visible = false
    private var autoSuppressed = false
    private var activeProviders: Set<String> = []
    private var activityKnown = false
    private var activeSince: TimeInterval?
    #if PROVIDER_TEST
    private var activityTimers: [Timer] = []
    #endif
    private var lastCLIProviders: Set<String> = []
    private var scanInFlight = false
    private var lifecycleGeneration = 0
    private var cacheReady = false
    private var inFlight: Set<String> = []
    private var pending: [String: String] = [:]
    private var runningReason: [String: String] = [:]
    private var observers: [NSObjectProtocol] = []
    private var diagnosticRows: [[String: Any]] = []

    private func event(_ name: String, provider: String = "", detail: String = "") {
        let url = Runtime.events
        if diagnosticRows.isEmpty, let data = try? Data(contentsOf: url),
           let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            diagnosticRows = Array(rows.suffix(199))
        }
        diagnosticRows.append(["time": Date().timeIntervalSince1970, "event": name, "provider": provider, "detail": detail])
        diagnosticRows = Array(diagnosticRows.suffix(200))
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: diagnosticRows) { try? data.write(to: url, options: .atomic) }
    }
    private var resetTimer: Timer?
    private var clockTimer: Timer?
    private var coveredSince: Date?
    private var healthItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if PROVIDER_TEST
        usageView = UsageStripView(frame: .zero)
        #else
        _ = loadDFR()
        dfrCloseBox(true)
        installStatusItem()
        installTouchBar()
        #endif
        notifications.changed = { [weak self] in
            guard let self else { return }
            self.notificationItem?.title = self.notifications.status
            self.evaluateWarnings()
        }
        notifications.report = { [weak self] name, detail in self?.event(name, detail: detail) }
        notifications.start()
        #if PROVIDER_TEST
        if CommandLine.arguments.contains("--notification-delivery") { notifications.requestPermission() }
        #endif
        #if PROVIDER_TEST
        installTestActivity()
        #endif
        event("launch")
        loadCache()
        watchCache()
        #if !PROVIDER_TEST
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in
                    guard let self else { return }
                    self.lifecycleGeneration += 1
                    self.applyHarness(self.desktopProviders().union(self.lastCLIProviders), force: false)
                    self.syncHarness(force: false)
                    if note.name == NSWorkspace.didWakeNotification { self.didWake() }
                    if note.name == NSWorkspace.didActivateApplicationNotification { self.notifications.refreshPermission() }
                }
            })
        }
        syncHarness(force: true)
        harnessTimer = Timer.scheduledTimer(withTimeInterval: harnessPollSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncHarness(force: false)
            }
        }
        harnessTimer?.tolerance = 0.5
        #endif
        // Countdowns, the pace tick and the stale label move with the clock, not with refreshes.
        clockTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.usageView?.needsDisplay = true
                self?.updateHealth()
            }
        }
        clockTimer?.tolerance = 5
    }

    private func didWake() {
        if !activeProviders.isEmpty { activeSince = ProcessInfo.processInfo.systemUptime }
        event("wake"); refresh(reason: "wake"); evaluateWarnings()
    }

    #if PROVIDER_TEST
    private func installTestActivity() {
        guard let path = ProcessInfo.processInfo.environment["USAGE_TEST_ACTIVITY"] else { return }
        let url = URL(fileURLWithPath: Runtime.guarded(path))
        guard let data = try? Data(contentsOf: url), let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { fatalError("Invalid activity script") }
        for row in rows {
            guard let after = row["after"] as? Double, after >= 0, after <= 1800 else { fatalError("Invalid activity timing") }
            let timer = Timer.scheduledTimer(withTimeInterval: max(0.001, after), repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if row["wake"] as? Bool == true { self.didWake() }
                    else if row["permission"] as? Bool == true { self.notifications.refreshPermission() }
                    else if let providers = row["providers"] as? [String], Set(providers).isSubset(of: harnessNames) { self.applyHarness(Set(providers), force: false) }
                }
            }
            activityTimers.append(timer)
        }
    }
    #endif

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Usage"
        item.button?.toolTip = "Usage Touch Bar"
        let menu = NSMenu()
        for name in ["Claude", "Codex"] {
            let row = NSMenuItem(title: "\(name): waiting for usage", action: nil, keyEquivalent: "")
            row.isEnabled = false
            menu.addItem(row)
            healthItems.append(row)
        }
        menu.addItem(.separator())
        let notificationRow = NSMenuItem(title: "Enable limit notifications…", action: #selector(enableNotifications), keyEquivalent: "")
        notificationRow.target = self
        menu.addItem(notificationRow)
        notificationItem = notificationRow
        menu.addItem(withTitle: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
        menu.addItem(withTitle: "Show on Touch Bar", action: #selector(showBar), keyEquivalent: "s")
        menu.addItem(withTitle: "Hide Touch Bar overlay", action: #selector(hideBar), keyEquivalent: "h")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit (restarts automatically)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    private func installTouchBar() {
        let usageView = UsageStripView(frame: .zero)
        usageView.onClick = { [weak self] in
            self?.refreshNow()
        }
        self.usageView = usageView
        let usageItem = NSCustomTouchBarItem(identifier: usageID)
        usageItem.view = usageView
        usageItem.visibilityPriority = .high
        self.usageItem = usageItem

        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [usageID]
        self.bar = bar

        let strip = NSCustomTouchBarItem(identifier: stripID)
        let button = NSButton(image: stripGlyph(emptyMeter(), emptyMeter()), target: self, action: #selector(showBar))
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel("Usage")
        strip.view = button
        stripItem = strip
        addSystemTrayItem(strip)
        dfrSetPresence(stripID, true)
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        identifier == usageID ? usageItem : nil
    }

    private func present() {
        guard let bar else { return }
        presentBar(bar, strip: stripID)
        visible = true
        autoSuppressed = false
        event("present")
    }

    @objc private func showBar() {
        refresh()
        present()
    }

    @objc private func hideBar() {
        guard let bar else { return }
        dismissBar(bar)
        visible = false
        autoSuppressed = true
        event("hide")
    }

    @objc private func enableNotifications() {
        // A denied app can no longer prompt; the only way back is its Notifications settings page.
        if notifications.permissionDenied,
           let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=local.agents.usagetouchbar") {
            NSWorkspace.shared.open(url)
            return
        }
        notifications.requestPermission()
    }

    @objc private func refreshNow() {
        refresh(reason: "manual")
    }

    private func desktopProviders() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier, harnessBundles.contains(id) else { return nil }
            if id == "com.anthropic.claudefordesktop" { return "claude" }
            return "codex"
        })
    }

    private func syncHarness(force: Bool) {
        guard !scanInFlight else { return }
        scanInFlight = true
        let generation = lifecycleGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let cli = cliProviders()
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanInFlight = false
                guard generation == self.lifecycleGeneration else { self.syncHarness(force: force); return }
                guard let cli else { self.activityKnown = false; self.evaluateWarnings(); self.event("scan-timeout"); return }
                self.lastCLIProviders = cli
                self.applyHarness(cli.union(self.desktopProviders()), force: force)
            }
        }
    }

    private func applyHarness(_ providers: Set<String>, force: Bool) {
        activityKnown = true
        let arrived = providers.subtracting(activeProviders)
        let wasActive = !activeProviders.isEmpty
        if providers != activeProviders { event("detection", detail: providers.sorted().joined(separator: ",")) }
        activeProviders = providers
        if providers.isEmpty { activeSince = nil }
        else if !wasActive { activeSince = ProcessInfo.processInfo.systemUptime; refresh(reason: "provider-start") }
        evaluateWarnings()
        for provider in arrived where provider != "grok" { refreshProvider(provider, reason: "provider-start") }
        if !providers.isEmpty && (!wasActive || force) && !autoSuppressed {
            refresh()
            present()
        } else if providers.isEmpty && (wasActive || force) {
            hideOverlay()
        } else if !providers.isEmpty && visible && !autoSuppressed {
            reclaimIfCovered()
        }
    }

    // Keep the overlay claimed while a harness is running, without cutting native popups short.
    private func reclaimIfCovered() {
        guard let bar else { return }
        if bar.isVisible {
            coveredSince = nil
            return
        }
        let since = coveredSince ?? Date()
        coveredSince = since
        guard Date().timeIntervalSince(since) >= reclaimGraceSeconds else { return }
        coveredSince = nil
        present()
    }

    private func hideOverlay() {
        guard let bar else { return }
        dismissBar(bar)
        visible = false
    }

    private func applySlots(_ slots: [String: Provider]) {
        guard let view = usageView else { return }
        let resets = view.show(claude: slots["week"], codex: slots["codex"])
        (stripItem?.view as? NSButton)?.image = stripGlyph(view.claude.week, view.codex.week)
        armReset(resets)
        for (key, row) in slots { scheduleProvider(key == "week" ? "claude" : "codex", row: row) }
        evaluateWarnings()
        updateHealth()
    }

    private func scheduleProvider(_ name: String, row: Provider?) {
        providerTimers[name]?.invalidate()
        let now = Date().timeIntervalSince1970
        let due = row?.nextRefreshAt?.timeIntervalSince1970 ?? now + 60
        let timer = Timer.scheduledTimer(withTimeInterval: max(0.1, due - now), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshProvider(name, reason: "automatic") }
        }
        timer.tolerance = 0.05
        providerTimers[name] = timer
    }

    private func evaluateWarnings() {
        guard let view = usageView else { return }
        let windows = [view.claude, view.codex].flatMap { row in
            [("five_hour", row.five), ("seven_day", row.week)].map { kind, meter in
                UsageWarningWindow(provider: row.name.lowercased(), kind: kind, percent: meter.pct, reset: meter.resetsAt,
                    acquired: meter.fetchedAt?.timeIntervalSince1970, basis: meter.freshnessBasis, interval: row.pollInterval, fresh: meter.isFresh)
            }
        }
        let retries = Dictionary(uniqueKeysWithValues: [view.claude, view.codex].compactMap { row -> (String, Double)? in
            guard let next = [row.retryAt, row.nextRefreshAt].compactMap({ $0 }).max() else { return nil }
            return (row.name.lowercased(), next.timeIntervalSince1970)
        })
        notifications.evaluate(windows, activeSince: activityKnown ? activeSince : nil, retries: retries)
    }

    private func watchCache() {
        try? FileManager.default.createDirectory(atPath: Runtime.cache, withIntermediateDirectories: true)
        let fd = open(Runtime.cache, O_EVTONLY)
        guard fd >= 0 else { event("cache-watch-unavailable"); return }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        watcher.setCancelHandler { close(fd) }
        watcher.setEventHandler { [weak self] in
            guard let self else { return }
            self.cacheDebounce?.cancel()
            let task = DispatchWorkItem { [weak self] in self?.observeCache() }
            self.cacheDebounce = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: task)
        }
        cacheWatcher = watcher
        watcher.resume()
    }

    private func observeCache() {
        guard cacheReady, !observingCache else { return }
        observingCache = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let slots = Self.readSlots(provider: "all", reason: "automatic", cacheOnly: true)
            DispatchQueue.main.async {
                guard let self else { return }
                self.observingCache = false
                if let slots { self.applySlots(slots); self.event("cache-observed") }
            }
        }
    }

    private func loadCache() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let slots = Self.readSlots(provider: "all", reason: "automatic", cacheOnly: true)
            DispatchQueue.main.async {
                guard let self else { return }
                if let slots { self.applySlots(slots); self.event("cache-render") }
                self.cacheReady = true
                let queued = self.pending
                self.pending.removeAll()
                for provider in ["claude", "codex"] { self.refreshProvider(provider, reason: queued[provider] ?? "automatic") }
            }
        }
    }

    private func refresh(reason: String = "automatic") {
        for provider in ["claude", "codex"] { refreshProvider(provider, reason: reason) }
    }

    private func refreshProvider(_ provider: String, reason: String) {
        let rank = ["automatic": 0, "wake": 1, "provider-start": 2, "manual": 3]
        if !cacheReady || inFlight.contains(provider) {
            if rank[reason, default: 0] > rank[runningReason[provider] ?? "automatic", default: 0]
                && rank[reason, default: 0] >= rank[pending[provider] ?? "automatic", default: 0] {
                pending[provider] = reason
            }
            return
        }
        providerTimers[provider]?.invalidate()
        inFlight.insert(provider)
        if provider == "claude" { usageView?.claude.loading = true } else { usageView?.codex.loading = true }
        usageView?.needsDisplay = true
        updateHealth()
        runningReason[provider] = reason
        event("refresh-start", provider: provider, detail: reason)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let slots = Self.readSlots(provider: provider, reason: reason)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(provider)
                self.runningReason.removeValue(forKey: provider)
                if provider == "claude" { self.usageView?.claude.loading = false } else { self.usageView?.codex.loading = false }
                self.usageView?.needsDisplay = true
                if let slots {
                    self.applySlots(slots)
                    let key = provider == "claude" ? "week" : "codex"
                    let row = slots[key]
                    self.event("refresh-complete", provider: provider, detail: "\(row?.error ?? "ok") source=\(row?.source ?? "cache") retry=\(row?.retryAt?.timeIntervalSince1970 ?? 0) interval=\(row?.pollInterval ?? 0) next=\(row?.nextRefreshAt?.timeIntervalSince1970 ?? 0) five=\(row?.five.pct ?? -1) week=\(row?.week.pct ?? -1)")
                } else {
                    if provider == "claude" { self.usageView?.claude.currentFailure = "app_timeout" }
                    else { self.usageView?.codex.currentFailure = "app_timeout" }
                    self.event("refresh-timeout", provider: provider, detail: "failed/unknown; cache retained")
                    self.scheduleProvider(provider, row: nil); self.updateHealth()
                }
                if let next = self.pending.removeValue(forKey: provider) {
                    // Let the shared successful-request cooldown expire before draining
                    // a queued manual request; failures keep their stronger backoff.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.1) { [weak self] in
                        self?.refreshProvider(provider, reason: next)
                    }
                }
            }
        }
    }

    private func updateHealth() {
        guard let view = usageView else { return }
        let now = Date().timeIntervalSince1970
        let descriptions = [view.claude, view.codex].map { healthDescription($0, now: now) }
        for (item, description) in zip(healthItems, descriptions) { item.title = description }
        statusItem?.button?.toolTip = descriptions.joined(separator: "\n")
    }

    private func armReset(_ stamps: [TimeInterval]) {
        resetTimer?.invalidate()
        resetTimer = nil
        let now = Date().timeIntervalSince1970
        guard let next = stamps.filter({ $0 > now && $0 - now < 6 * 3600 }).min() else { return }
        let delay = max(1, next - now + 1)
        resetTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    nonisolated private static func readSlots(provider selected: String, reason: String, cacheOnly: Bool = false) -> [String: Provider]? {
        var arguments = ["--format", "slots", "--provider", selected, "--refresh-reason", reason]
        if cacheOnly { arguments.append("--cache-only") }
        #if PROVIDER_TEST
        arguments += ["--test-config", Runtime.config]
        #endif
        guard let data = runOutput(scriptPath, arguments, timeout: cacheOnly ? 5 : (selected == "claude" ? 90 : 12)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var result: [String: Provider] = [:]
        for key in ["week", "codex"] { if let row = provider(obj[key]) { result[key] = row } }
        return result.isEmpty ? nil : result
    }

    nonisolated private static func provider(_ raw: Any?) -> Provider? {
        guard let row = raw as? [String: Any] else { return nil }
        let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { return nil }
        return Provider(
            name: name,
            five: meter(row["five_hour"]),
            week: meter(row["seven_day"]),
            fetchedAt: snapshotDate(row["fetched_at"]),
            error: row["error"] as? String,
            retryAt: snapshotDate(row["retry_at"]),
            source: row["source"] as? String,
            fetchError: row["fetch_error"] as? String,
            readingSource: row["reading_source"] as? String,
            pollInterval: (row["poll_interval_seconds"] as? Double) ?? 60,
            nextRefreshAt: snapshotDate(row["next_refresh_at"]),
            recoveryState: row["recovery_state"] as? String ?? "normal",
            recoverySuccesses: row["recovery_successes"] as? Int ?? 0,
            currentFailure: (row["diagnostics"] as? [String: Any])?["current_failure"] as? String
        )
    }

    nonisolated private static func meter(_ raw: Any?) -> Meter {
        guard let row = raw as? [String: Any] else { return emptyMeter() }
        let pct: Double?
        if let number = row["pct"] as? Double {
            pct = number
        } else if let number = row["pct"] as? Int {
            pct = Double(number)
        } else {
            pct = nil
        }
        let end = (row["end"] as? String) ?? ""
        let resets: TimeInterval?
        if let number = row["resets_at"] as? Double {
            resets = number
        } else if let number = row["resets_at"] as? Int {
            resets = TimeInterval(number)
        } else {
            resets = nil
        }
        return Meter(pct: pct, end: end, resetsAt: resets, color: parseColor(row["color"] as? String), fetchedAt: snapshotDate(row["fetched_at"]), observedAt: snapshotDate(row["observed_at"]), freshnessBasis: (row["freshness_basis"] as? String) ?? "unknown", isFresh: (row["is_fresh"] as? Bool) ?? false)
    }
}

@main
enum UsageTouchBarMain {
    static func main() {
        #if PROVIDER_TEST
        let args = CommandLine.arguments
        if args.count == 4 && ["--notification-rules", "--monitoring-rules"].contains(args[1]) {
            do {
                if args[1] == "--monitoring-rules" {
                    try runMonitoringRules(input: URL(fileURLWithPath: Runtime.guarded(args[2])), output: URL(fileURLWithPath: Runtime.guarded(args[3])))
                } else {
                try runNotificationRules(input: URL(fileURLWithPath: Runtime.guarded(args[2])), output: URL(fileURLWithPath: Runtime.guarded(args[3])))
                }
            } catch { fputs("Notification rules failed\n", stderr); exit(2) }
            return
        }
        #else
        guard !ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("USAGE_TEST_") }),
              !CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--notification-") || $0.hasPrefix("--monitoring-") }) else { exit(2) }
        #endif
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let agent = Agent()
        app.delegate = agent
        objc_setAssociatedObject(app, "agent", agent, .OBJC_ASSOCIATION_RETAIN)
        app.run()
    }
}
