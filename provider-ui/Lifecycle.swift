import AppKit
import Darwin
import Foundation
import Security

// Shared by the UI and the nested launcher: session identity, process identity, the state
// files they exchange, advisory locks and the launcher's process scan.

struct AuditSessionKey: Codable, Equatable {
    let bootSessionUUID: String
    let securitySessionID: UInt32
    let uid: UInt32

    static func current() -> AuditSessionKey? {
        var sessionID: SecuritySessionId = noSecuritySession
        guard SessionGetInfo(callerSecuritySession, &sessionID, nil) == errSecSuccess,
              sessionID != noSecuritySession, sessionID != callerSecuritySession else { return nil }
        var bytes = [CChar](repeating: 0, count: 128)
        var length = bytes.count
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &length, nil, 0) == 0 else { return nil }
        let boot = String(cString: bytes)
        guard UUID(uuidString: boot) != nil else { return nil }
        return AuditSessionKey(bootSessionUUID: boot.uppercased(), securitySessionID: UInt32(sessionID), uid: UInt32(getuid()))
    }
}

struct ProcessIdentity: Codable, Equatable, Hashable, Comparable {
    let provider: String
    let pid: Int32
    let executablePath: String
    let bundleIdentifier: String?
    let startSeconds: Int64
    let startMicroseconds: Int64

    var startTime: TimeInterval {
        TimeInterval(startSeconds) + TimeInterval(startMicroseconds) / 1_000_000
    }

    static func < (lhs: ProcessIdentity, rhs: ProcessIdentity) -> Bool {
        if lhs.provider != rhs.provider { return lhs.provider < rhs.provider }
        if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
        if lhs.startSeconds != rhs.startSeconds { return lhs.startSeconds < rhs.startSeconds }
        if lhs.startMicroseconds != rhs.startMicroseconds { return lhs.startMicroseconds < rhs.startMicroseconds }
        return lhs.executablePath < rhs.executablePath
    }

    static func read(pid: pid_t, provider: String, bundleIdentifier: String?) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let needed = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, needed) == needed,
              info.pbi_uid == getuid() else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return ProcessIdentity(
            provider: provider,
            pid: pid,
            executablePath: URL(fileURLWithPath: String(cString: path)).standardizedFileURL.path,
            bundleIdentifier: bundleIdentifier,
            startSeconds: Int64(info.pbi_start_tvsec),
            startMicroseconds: Int64(info.pbi_start_tvusec)
        )
    }

    func isRunning() -> Bool {
        guard let current = Self.read(pid: pid, provider: provider, bundleIdentifier: bundleIdentifier) else { return false }
        return current.startSeconds == startSeconds
            && current.startMicroseconds == startMicroseconds
            && current.executablePath == executablePath
    }
}

struct QuitIntent: Codable, Equatable {
    let instanceID: String
    let at: TimeInterval
    let baselineIdentities: [ProcessIdentity]
}

struct UIInstanceRecord: Codable, Equatable {
    let schemaVersion: Int
    let session: AuditSessionKey
    let instanceID: String
    let process: ProcessIdentity
    let createdAt: TimeInterval
    let launchMode: String
    let launchToken: String?
    var observedGeneration: Int
    var activeIdentities: [ProcessIdentity]
    var quitIntent: QuitIntent?
}

struct LaunchRequest: Codable, Equatable {
    let token: String
    let requestedAt: TimeInterval
    let reason: String
}

struct QuitSuppression: Codable, Equatable {
    let instanceID: String
    let at: TimeInterval
    let baselineIdentities: [ProcessIdentity]
}

struct QuitIntentAcknowledgement: Codable, Equatable {
    let instanceID: String
    let at: TimeInterval
}

struct LifecycleState: Codable, Equatable {
    let schemaVersion: Int
    let session: AuditSessionKey
    var generation: Int
    var updatedAt: TimeInterval
    var sessionActive: Bool
    var identities: [ProcessIdentity]
    var activeProviders: [String]
    var uiInstanceID: String?
    var uiProcess: ProcessIdentity?
    var uiStartedAt: TimeInterval?
    var intentionalQuit: QuitSuppression?
    var acknowledgedQuitIntent: QuitIntentAcknowledgement?
    var launchRequest: LaunchRequest?
    var lastUILaunchAt: TimeInterval?
    var recoveryAttempts: [TimeInterval]
    var exhaustedAt: TimeInterval?

    static func fresh(session: AuditSessionKey) -> LifecycleState {
        LifecycleState(
            schemaVersion: 1,
            session: session,
            generation: 0,
            updatedAt: Date().timeIntervalSince1970,
            sessionActive: true,
            identities: [],
            activeProviders: [],
            uiInstanceID: nil,
            uiProcess: nil,
            uiStartedAt: nil,
            intentionalQuit: nil,
            acknowledgedQuitIntent: nil,
            launchRequest: nil,
            lastUILaunchAt: nil,
            recoveryAttempts: [],
            exhaustedAt: nil
        )
    }
}

enum LifecycleNotification {
    static let stateChanged = Notification.Name("local.agents.usagetouchbar.lifecycle.state")
    static let uiChanged = Notification.Name("local.agents.usagetouchbar.lifecycle.ui")
    #if PROVIDER_TEST
    static let testQuit = Notification.Name("local.agents.usagetouchbar.lifecycle.test.quit")
    #endif

    static func post(_ name: Notification.Name) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: nil, deliverImmediately: true)
    }
}

enum LifecycleEnvironment {
    // Production paths are fixed; only verification builds read overrides from the environment.
    static var stateRoot: URL {
        #if PROVIDER_TEST
        // Launcher runs set USAGETOUCHBAR_STATE_ROOT; UI-only verifiers keep using their USAGE_TEST_STATE folder.
        let environment = ProcessInfo.processInfo.environment
        guard let value = environment["USAGETOUCHBAR_STATE_ROOT"] ?? environment["USAGE_TEST_STATE"], value.hasPrefix("/") else {
            fatalError("USAGETOUCHBAR_STATE_ROOT must be an absolute path in verification builds")
        }
        return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        #else
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/UsageTouchBar", isDirectory: true)
        #endif
    }

    static var logRoot: URL {
        #if PROVIDER_TEST
        return stateRoot.appendingPathComponent("logs", isDirectory: true)
        #else
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Logs/UsageTouchBar", isDirectory: true)
        #endif
    }

    static var ignoredPIDs: Set<pid_t> {
        #if PROVIDER_TEST
        guard let raw = ProcessInfo.processInfo.environment["USAGETOUCHBAR_TEST_IGNORED_PIDS"] else { return [] }
        return Set(raw.split(separator: ",").compactMap { pid_t($0) })
        #else
        return []
        #endif
    }

    // Verification builds can name one extra desktop bundle that counts as Codex, so the
    // desktop (KVO) path is testable without opening a real provider app.
    static var testDesktopBundle: String? {
        #if PROVIDER_TEST
        return ProcessInfo.processInfo.environment["USAGETOUCHBAR_TEST_DESKTOP_BUNDLE"]
        #else
        return nil
        #endif
    }
}

enum LifecyclePaths {
    static var state: URL { LifecycleEnvironment.stateRoot.appendingPathComponent("state.json") }
    static var ui: URL { LifecycleEnvironment.stateRoot.appendingPathComponent("ui-instance.json") }
    static var uiLock: URL { LifecycleEnvironment.stateRoot.appendingPathComponent("ui-instance.lock") }
    static var launcherLock: URL { LifecycleEnvironment.stateRoot.appendingPathComponent("launcher.lock") }
    static var launcherLog: URL { LifecycleEnvironment.logRoot.appendingPathComponent("launcher.jsonl") }
}

final class AdvisoryFileLock {
    private let descriptor: Int32

    private init(_ descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(_ url: URL) throws -> AdvisoryFileLock? {
        try LifecycleFiles.ensureDirectories()
        let fd = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK || code == EAGAIN { return nil }
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        _ = fchmod(fd, S_IRUSR | S_IWUSR)
        return AdvisoryFileLock(fd)
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }
}

enum LifecycleFiles {
    static func ensureDirectories() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: LifecycleEnvironment.stateRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.createDirectory(at: LifecycleEnvironment.logRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = chmod(LifecycleEnvironment.stateRoot.path, 0o700)
        _ = chmod(LifecycleEnvironment.logRoot.path, 0o700)
    }

    static func atomicWrite(_ data: Data, to destination: URL) throws {
        try ensureDirectories()
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(getpid()).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var failure: Int32 = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var offset = 0
            while offset < raw.count {
                let result = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if result < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    break
                }
                offset += result
            }
        }
        if failure == 0 && fsync(fd) != 0 { failure = errno }
        _ = close(fd)
        guard failure == 0 else {
            _ = unlink(temporary.path)
            throw POSIXError(.init(rawValue: failure) ?? .EIO)
        }
        guard rename(temporary.path, destination.path) == 0 else {
            let code = errno
            _ = unlink(temporary.path)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        _ = chmod(destination.path, S_IRUSR | S_IWUSR)
        let directoryFD = open(destination.deletingLastPathComponent().path, O_RDONLY)
        if directoryFD >= 0 { _ = fsync(directoryFD); _ = close(directoryFD) }
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    static func readState(for session: AuditSessionKey) -> LifecycleState? {
        guard let state = try? decode(LifecycleState.self, from: LifecyclePaths.state),
              state.schemaVersion == 1, state.session == session else { return nil }
        return state
    }

    static func readUI(for session: AuditSessionKey) -> UIInstanceRecord? {
        guard let record = try? decode(UIInstanceRecord.self, from: LifecyclePaths.ui),
              record.schemaVersion == 1, record.session == session else { return nil }
        return record
    }

    static func writeState(_ state: LifecycleState) throws {
        try atomicWrite(encode(state), to: LifecyclePaths.state)
    }

    static func writeUI(_ record: UIInstanceRecord) throws {
        try atomicWrite(encode(record), to: LifecyclePaths.ui)
    }

    static func appendLauncherLog(event: String, generation: Int, providers: [String], detail: String = "") {
        let row: [String: Any] = ["time": Date().timeIntervalSince1970, "event": event, "generation": generation,
                                  "providers": providers.sorted(), "detail": String(detail.prefix(160))]
        let url = LifecyclePaths.launcherLog
        var lines = (try? String(contentsOf: url, encoding: .utf8))?.split(whereSeparator: \.isNewline).suffix(199).map(String.init) ?? []
        guard let data = try? JSONSerialization.data(withJSONObject: row), let line = String(data: data, encoding: .utf8) else { return }
        lines.append(line)
        try? atomicWrite(Data((lines.suffix(200).joined(separator: "\n") + "\n").utf8), to: url)
    }
}

struct ProcessScanner {
    private let desktopProviders: [String: String] = {
        var map = [
            "com.anthropic.claudefordesktop": "claude",
            "com.openai.codex": "codex",
            "com.openai.chat": "codex",
        ]
        if let bundle = LifecycleEnvironment.testDesktopBundle { map[bundle] = "codex" }
        return map
    }()
    private let cliNames: Set<String> = ["claude", "codex", "grok"]

    // Desktop apps by bundle id; CLIs by the name they were started under (argv[0]), the same
    // signal `ps -o comm` gives. The executable path alone is not enough: Claude Code runs helpers
    // such as `ugrep` from the `claude` binary, and counting those would undo Quit. A CLI process
    // that a provider desktop app started itself (its own Claude Code sessions, ChatGPT's codex
    // app-servers) is that app's work, already counted by the app, never new work (D28).
    func scan() throws -> [ProcessIdentity] {
        let ignored = LifecycleEnvironment.ignoredPIDs
        var identities: [pid_t: ProcessIdentity] = [:]
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard !ignored.contains(pid), let bundle = app.bundleIdentifier,
                  let provider = desktopProviders[bundle],
                  let identity = ProcessIdentity.read(pid: pid, provider: provider, bundleIdentifier: bundle) else { continue }
            identities[pid] = identity
        }
        let desktopPIDs = Set(identities.keys)
        for pid in try processIDs() where !ignored.contains(pid) && identities[pid] == nil {
            guard let name = Self.launchName(pid), cliNames.contains(name),
                  !Self.descends(pid, fromAnyOf: desktopPIDs),
                  let identity = ProcessIdentity.read(pid: pid, provider: name, bundleIdentifier: nil) else { continue }
            identities[pid] = identity
        }
        return identities.values.sorted()
    }

    static func descends(_ pid: pid_t, fromAnyOf ancestors: Set<pid_t>) -> Bool {
        guard !ancestors.isEmpty else { return false }
        var current = pid
        for _ in 0..<64 {
            var info = proc_bsdinfo()
            let needed = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, needed) == needed else { return false }
            let parent = pid_t(info.pbi_ppid)
            if ancestors.contains(parent) { return true }
            if parent <= 1 || parent == current { return false }
            current = parent
        }
        return false
    }

    // Lowercased basename of argv[0] from KERN_PROCARGS2 (argc, exec path, padding, argv...).
    static func launchName(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 }   // exec path
        while index < size && buffer[index] == 0 { index += 1 }   // padding
        let start = index
        while index < size && buffer[index] != 0 { index += 1 }
        guard index > start, let argv0 = String(bytes: buffer[start..<index], encoding: .utf8) else { return nil }
        return URL(fileURLWithPath: argv0).lastPathComponent.lowercased()
    }

    private func processIDs() throws -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return Array(pids.prefix(min(Int(count), pids.count))).filter { $0 > 0 }
    }
}

final class UIRuntime {
    let session: AuditSessionKey
    let lock: AdvisoryFileLock
    let instanceID: String
    let process: ProcessIdentity
    private(set) var record: UIInstanceRecord

    private init(session: AuditSessionKey, lock: AdvisoryFileLock, record: UIInstanceRecord) {
        self.session = session
        self.lock = lock
        self.instanceID = record.instanceID
        self.process = record.process
        self.record = record
    }

    /// Takes the single-UI lock before anything else; nil means another UI already owns it.
    static func start() throws -> UIRuntime? {
        guard let session = AuditSessionKey.current() else { throw RuntimeFailure.invalidSession }
        guard let lock = try AdvisoryFileLock.acquire(LifecyclePaths.uiLock) else { return nil }
        guard let process = ProcessIdentity.read(pid: getpid(), provider: "usage-touchbar", bundleIdentifier: Bundle.main.bundleIdentifier) else {
            throw RuntimeFailure.processIdentityUnavailable
        }
        let state = LifecycleFiles.readState(for: session)
        let token = ProcessInfo.processInfo.environment["USAGETOUCHBAR_LAUNCH_TOKEN"]
        let matchedToken = state?.launchRequest?.token == token ? token : nil
        let record = UIInstanceRecord(
            schemaVersion: 1,
            session: session,
            instanceID: UUID().uuidString,
            process: process,
            createdAt: Date().timeIntervalSince1970,
            launchMode: matchedToken == nil ? "manual" : "launcher",
            launchToken: matchedToken,
            observedGeneration: state?.generation ?? 0,
            activeIdentities: state?.identities ?? [],
            quitIntent: nil
        )
        try LifecycleFiles.writeUI(record)
        LifecycleNotification.post(LifecycleNotification.uiChanged)
        return UIRuntime(session: session, lock: lock, record: record)
    }

    func consume(_ state: LifecycleState) {
        guard state.session == session else { return }
        let identities = state.identities.sorted()
        guard record.observedGeneration != state.generation || record.activeIdentities != identities else { return }
        record.observedGeneration = state.generation
        record.activeIdentities = identities
        try? LifecycleFiles.writeUI(record)
        LifecycleNotification.post(LifecycleNotification.uiChanged)
    }

    func recordQuit() throws {
        let state = LifecycleFiles.readState(for: session)
        if let state { record.activeIdentities = state.identities.sorted(); record.observedGeneration = state.generation }
        // Keep the intent out of memory unless it reached disk: a cancelled Quit must not be
        // published later by consume().
        var updated = record
        updated.quitIntent = QuitIntent(instanceID: instanceID, at: Date().timeIntervalSince1970, baselineIdentities: updated.activeIdentities)
        try LifecycleFiles.writeUI(updated)
        record = updated
        LifecycleNotification.post(LifecycleNotification.uiChanged)
    }
}

enum RuntimeFailure: Error {
    case invalidSession
    case processIdentityUnavailable
}
