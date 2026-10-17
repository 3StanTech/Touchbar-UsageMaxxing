import Foundation
import UserNotifications

func usageWarningAuthorized(_ status: UNAuthorizationStatus) -> Bool {
    status == .authorized || status == .provisional
}

struct UsageWarningWindow: Codable {
    var provider: String
    var kind: String
    var percent: Double?
    var reset: Double?
    var acquired: Double?
    var basis: String
    var interval: Double
    var fresh: Bool

    func warningID(now: Double) -> String? {
        let threshold: Double
        switch kind {
        case "five_hour": threshold = 90
        case "seven_day": threshold = 98
        default: return nil
        }
        guard ["claude", "codex"].contains(provider), fresh, basis == "api_acquisition",
              interval == 30 || interval == 60,
              let percent, percent.isFinite, percent >= threshold, percent <= 100,
              let reset, reset.isFinite, reset > now,
              let acquired, acquired.isFinite, acquired > 0, acquired <= now,
              now - acquired <= interval + 5 else { return nil }
        return "usage-limit.\(provider).\(kind).\(Int(reset))"
    }
}

struct MonitoringReading: Codable {
    var percent: Double
    var acquired: Double
    var reset: Double
}

struct MonitoringEpisode: Codable {
    var id: String
    var affected: [String: Double]
    var sent: Bool = false
}

struct UsageWarningLedger: Codable {
    var version = 2
    var scheduled: [String: Double] = [:]
    var readings: [String: MonitoringReading] = [:]
    var episodes: [String: MonitoringEpisode] = [:]
    enum CodingKeys: String, CodingKey { case version, scheduled, readings, episodes }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode(Int.self, forKey: .version)
        guard v == 1 || v == 2 else { throw CocoaError(.fileReadCorruptFile) }
        scheduled = try c.decode([String: Double].self, forKey: .scheduled)
        if v == 2 {
            readings = try c.decode([String: MonitoringReading].self, forKey: .readings)
            episodes = try c.decode([String: MonitoringEpisode].self, forKey: .episodes)
        }
        guard scheduled.values.allSatisfy({ $0.isFinite && $0 > 0 }),
              readings.values.allSatisfy({ $0.percent.isFinite && (0...100).contains($0.percent) && $0.acquired.isFinite && $0.acquired > 0 && $0.reset.isFinite }),
              episodes.allSatisfy({ ["claude", "codex"].contains($0.key) && $0.value.id.hasPrefix("usage-monitoring-gap/" + $0.key + "/") && !$0.value.affected.isEmpty && $0.value.affected.allSatisfy({ ["five_hour", "seven_day"].contains($0.key) && $0.value.isFinite && $0.value > 0 }) })
        else { throw CocoaError(.fileReadCorruptFile) }
    }
    static func load(_ url: URL) throws -> UsageWarningLedger {
        guard FileManager.default.fileExists(atPath: url.path) else { return UsageWarningLedger() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
    mutating func remember(_ id: String, now: Double) {
        scheduled[id] = now
        scheduled = scheduled.filter { now - $0.value < 8 * 86400 }
    }
    mutating func observe(_ windows: [UsageWarningWindow], now: Double) {
        for w in windows {
            guard ["claude", "codex"].contains(w.provider), ["five_hour", "seven_day"].contains(w.kind), w.basis == "api_acquisition",
                  let pct = w.percent, pct.isFinite, (0...100).contains(pct),
                  let acquired = w.acquired, acquired.isFinite, acquired > 0, acquired <= now,
                  let reset = w.reset, reset.isFinite, reset > now else { continue }
            let key = w.provider + "/" + w.kind
            if acquired > (readings[key]?.acquired ?? 0) { readings[key] = MonitoringReading(percent: pct, acquired: acquired, reset: reset) }
        }
        readings = readings.filter { $0.value.reset > now && now - $0.value.acquired < 8 * 86400 }
        scheduled = scheduled.filter { now - $0.value < 8 * 86400 }
        for (provider, episode) in episodes {
            let remaining = episode.affected.filter { kind, acquired in
                guard let reading = readings[provider + "/" + kind] else { return false }
                return reading.acquired <= acquired && reading.reset > now
            }
            if remaining.isEmpty { episodes.removeValue(forKey: provider) }
        }
    }
    func eligible(_ provider: String, now: Double, activeAge: Double?) -> [String: MonitoringReading] {
        guard let activeAge, activeAge >= 180 else { return [:] }
        var result: [String: MonitoringReading] = [:]
        for kind in ["five_hour", "seven_day"] {
            if let r = readings[provider + "/" + kind], r.acquired <= now, now - r.acquired >= 180,
               r.reset > now, r.percent >= (kind == "five_hour" ? 88 : 97) { result[kind] = r }
        }
        return result
    }
    mutating func prepare(_ provider: String, eligible: [String: MonitoringReading]) -> String? {
        guard !eligible.isEmpty else { return nil }
        var episode = episodes[provider] ?? MonitoringEpisode(id: "usage-monitoring-gap/" + provider + "/" + UUID().uuidString, affected: [:])
        for (kind, reading) in eligible where episode.affected[kind] == nil { episode.affected[kind] = reading.acquired }
        episodes[provider] = episode
        return episode.sent ? nil : episode.id
    }
}

@MainActor
final class UsageNotifications: NSObject, UNUserNotificationCenterDelegate {
    let center = UNUserNotificationCenter.current()
    let ledgerURL: URL
    var ledger = UsageWarningLedger()
    var inFlight = Set<String>()
    var ready = false
    var status = "Usage notifications: checking permission"
    var changed: (() -> Void)?
    var report: ((String, String) -> Void)?
    private var ledgerError = false
    private var windows: [UsageWarningWindow] = []
    private var activeSince: TimeInterval?
    private var retries: [String: Double] = [:]
    private var generation = 0
    private var gapTimer: Timer?
    private var gapPermission: UNAuthorizationStatus = .notDetermined
    private var reportedPermission: UNAuthorizationStatus?
    var permissionDenied: Bool { gapPermission == .denied }

    init(ledgerURL: URL) {
        self.ledgerURL = ledgerURL
        super.init()
        center.delegate = self
        do { ledger = try UsageWarningLedger.load(ledgerURL) }
        catch { ledgerError = true; status = "Usage notifications: ledger unreadable" }
    }
    @discardableResult private func save() -> Bool {
        guard !ledgerError else { return false }
        do { try ledger.save(ledgerURL); return true }
        catch {
            ledgerError = true; gapTimer?.invalidate()
            status = "Usage notifications: ledger write failed"; changed?()
            report?("notification-ledger-error", "write failed; scheduling stopped")
            return false
        }
    }
    func start() {
        Task { @MainActor in
            let pending = await center.pendingNotificationRequests()
            let delivered = await center.deliveredNotifications()
            let ids = pending.map(\.identifier) + delivered.map { $0.request.identifier }
            for id in ids where id.hasPrefix("usage-limit.") || id.hasPrefix("usage-monitoring-gap/") {
                ledger.remember(id, now: Date().timeIntervalSince1970)
                for provider in ["claude", "codex"] where ledger.episodes[provider]?.id == id { ledger.episodes[provider]?.sent = true }
            }
            if !ids.isEmpty && !ledgerError { save() }
            ready = true
            refreshPermission()
        }
    }
    func refreshPermission() {
        Task { @MainActor in
            let settings = await center.notificationSettings()
            gapPermission = settings.authorizationStatus
            // Every app switch re-checks permission; log only changes so the capped
            // diagnostic history keeps its refresh events.
            if reportedPermission != settings.authorizationStatus {
                reportedPermission = settings.authorizationStatus
                report?("notification-authorization", String(settings.authorizationStatus.rawValue))
            }
            if !ledgerError {
                switch settings.authorizationStatus {
                case .authorized, .provisional: status = "Usage notifications: enabled"
                case .denied: status = "Usage notifications: off — open System Settings…"
                default: status = "Enable usage notifications…"
                }
            }
            changed?()
            evaluateCurrent()
        }
    }
    func requestPermission() {
        Task { @MainActor in
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { refreshPermission(); return }
            do { _ = try await center.requestAuthorization(options: [.alert]) }
            catch { report?("notification-permission-error", "request failed") }
            refreshPermission()
        }
    }
    func evaluate(_ windows: [UsageWarningWindow], activeSince: TimeInterval?, retries: [String: Double]) {
        self.windows = windows; self.activeSince = activeSince; self.retries = retries
        generation += 1
        evaluateCurrent()
    }
    private func evaluateCurrent() {
        gapTimer?.invalidate(); gapTimer = nil
        guard ready, !ledgerError else { return }
        let now = Date().timeIntervalSince1970
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try? encoder.encode(ledger)
        ledger.observe(windows, now: now)
        if before != (try? encoder.encode(ledger)), !save() { return }
        for window in windows {
            guard let id = window.warningID(now: now), ledger.scheduled[id] == nil, !inFlight.contains(id) else { continue }
            inFlight.insert(id)
            Task { @MainActor in
                let settings = await center.notificationSettings()
                guard usageWarningAuthorized(settings.authorizationStatus), !ledgerError,
                      self.windows.contains(where: { $0.warningID(now: Date().timeIntervalSince1970) == id }), ledger.scheduled[id] == nil else { inFlight.remove(id); return }
                let content = UNMutableNotificationContent()
                content.title = "\(window.provider.capitalized) \(window.kind == "five_hour" ? "5-hour" : "weekly") usage warning"
                content.body = "\(String(format: "%.1f", window.percent!))% used. Resets \(Date(timeIntervalSince1970: window.reset!).formatted(date: .abbreviated, time: .shortened))."
                await schedule(id, content: content, provider: nil)
            }
        }
        guard let activeSince else { return }
        let activeAge = ProcessInfo.processInfo.systemUptime - activeSince
        for provider in ["claude", "codex"] {
            let eligible = ledger.eligible(provider, now: now, activeAge: activeAge)
            let beforeEpisode = try? encoder.encode(ledger)
            let prepared = ledger.prepare(provider, eligible: eligible)
            // Membership must persist even when this provider's episode was already
            // sent or permission is temporarily unavailable.
            if beforeEpisode != (try? encoder.encode(ledger)), !save() { return }
            guard usageWarningAuthorized(gapPermission), let id = prepared, !inFlight.contains(id) else { continue }
            inFlight.insert(id)
            let captured = generation
            Task { @MainActor in
                let settings = await center.notificationSettings()
                let currentNow = Date().timeIntervalSince1970
                let age = self.activeSince.map { ProcessInfo.processInfo.systemUptime - $0 }
                let current = ledger.eligible(provider, now: currentNow, activeAge: age)
                if captured != generation { inFlight.remove(id); evaluateCurrent(); return }
                guard !ledgerError, usageWarningAuthorized(settings.authorizationStatus),
                      !current.isEmpty, ledger.episodes[provider]?.id == id, ledger.episodes[provider]?.sent == false else { inFlight.remove(id); return }
                let content = UNMutableNotificationContent()
                content.title = "\(provider.capitalized) usage monitoring delayed"
                let details = current.keys.sorted().map { kind in
                    let r = current[kind]!
                    return "\(kind == "five_hour" ? "5-hour" : "weekly") last known \(String(format: "%.1f", r.percent))% (\(Int(currentNow-r.acquired))s ago)"
                }.joined(separator: "; ")
                let retry = retries[provider].map { "; next retry \(Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .standard))" } ?? "; next retry unknown"
                content.body = details + retry + ". Current usage is unknown."
                await schedule(id, content: content, provider: provider)
            }
        }
        // One one-shot timer, independent of reader deadlines. No due-now spin when
        // permission is absent or an episode has already been sent.
        var delays = [Double]()
        for provider in ["claude", "codex"] {
            for kind in ["five_hour", "seven_day"] {
                guard let r = ledger.readings[provider + "/" + kind], r.reset > now,
                      r.percent >= (kind == "five_hour" ? 88 : 97) else { continue }
                delays.append(r.reset - now)
                let due = max(r.acquired + 180 - now, 180 - activeAge)
                if due > 0 && (ledger.episodes[provider]?.sent != true || ledger.episodes[provider]?.affected[kind] == nil) { delays.append(due) }
            }
        }
        if let delay = delays.filter({ $0 > 0 }).min() {
            gapTimer = Timer.scheduledTimer(withTimeInterval: max(0.01, delay), repeats: false) { [weak self] _ in
                Task { @MainActor in self?.evaluateCurrent() }
            }
            gapTimer?.tolerance = 0.05
        }
    }
    private func schedule(_ id: String, content: UNMutableNotificationContent, provider: String?) async {
        defer { inFlight.remove(id) }
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            ledger.remember(id, now: Date().timeIntervalSince1970)
            if let provider { ledger.episodes[provider]?.sent = true }
            guard save() else { return }
            report?("notification-scheduled", id)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                let delivered = await center.deliveredNotifications()
                let pending = await center.pendingNotificationRequests()
                let ids = delivered.map { $0.request.identifier } + pending.map(\.identifier)
                report?("notification-native-state", ids.sorted().joined(separator: ","))
            }
        } catch { report?("notification-error", "native scheduling failed") }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

#if PROVIDER_TEST
// Exercise the shipping eligibility and atomic ledger via the real built executable.
func runNotificationRules(input: URL, output: URL) throws {
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: input)) as! [String: Any]
    let cases = raw["cases"] as! [[String: Any]]
    let ledgerURL = output.deletingLastPathComponent().appendingPathComponent("rules-ledger.json")
    var ledger = try UsageWarningLedger.load(ledgerURL)
    var results = [[String: Any]]()
    for row in cases {
        let now = row["now"] as! Double
        let data = try JSONSerialization.data(withJSONObject: row["window"]!)
        let window = try JSONDecoder().decode(UsageWarningWindow.self, from: data)
        let id = window.warningID(now: now)
        let authorization = UNAuthorizationStatus(rawValue: (row["authorization"] as? Int) ?? 2) ?? .notDetermined
        let schedules = usageWarningAuthorized(authorization) && id != nil && ledger.scheduled[id!] == nil
        if schedules { ledger.remember(id!, now: now); try ledger.save(ledgerURL) }
        ledger = try UsageWarningLedger.load(ledgerURL)
        results.append(["case": row["case"]!, "eligible": id != nil, "schedules": schedules])
    }
    try JSONSerialization.data(withJSONObject: results, options: .prettyPrinted).write(to: output, options: .atomic)
}
#endif

#if PROVIDER_TEST
func runMonitoringRules(input: URL, output: URL) throws {
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: input)) as! [String: Any]
    let ledgerURL = output.deletingLastPathComponent().appendingPathComponent("monitoring-ledger.json")
    if let seed = raw["seed"] { try JSONSerialization.data(withJSONObject: seed).write(to: ledgerURL, options: .atomic) }
    var ledger = try UsageWarningLedger.load(ledgerURL)
    var results = [[String: Any]]()
    for row in raw["cases"] as! [[String: Any]] {
        let now = row["now"] as! Double
        let windows = try JSONDecoder().decode([UsageWarningWindow].self, from: JSONSerialization.data(withJSONObject: row["windows"] ?? []))
        ledger.observe(windows, now: now)
        var scheduled = [String]()
        var eligibleKinds = [String: [String]]()
        for provider in ["claude", "codex"] {
            let eligible = ledger.eligible(provider, now: now, activeAge: row["active_age"] as? Double)
            eligibleKinds[provider] = eligible.keys.sorted()
            let prepared = ledger.prepare(provider, eligible: eligible)
            if row["authorized"] as? Bool == true, let id = prepared {
                try ledger.save(ledgerURL)
                ledger.episodes[provider]?.sent = true
                ledger.remember(id, now: now)
                scheduled.append(id)
            }
        }
        try ledger.save(ledgerURL)
        ledger = try UsageWarningLedger.load(ledgerURL)
        results.append(["case": row["case"]!, "eligible": eligibleKinds, "scheduled": scheduled, "ledger": try JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger))])
    }
    try JSONSerialization.data(withJSONObject: results, options: .prettyPrinted).write(to: output, options: .atomic)
}
#endif
