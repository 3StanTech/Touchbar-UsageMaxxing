import AppKit
import Darwin
import Foundation

// The launcher lives at UsageTouchBar.app/Contents/Library/LoginItems/UsageTouchBarLauncher.app.
// It alone detects provider work, starts the UI through LaunchServices, honours Quit and bounds
// crash recovery; the UI consumes its state file.
private let uiBundleURL: URL = Bundle.main.bundleURL
    .deletingLastPathComponent()   // LoginItems
    .deletingLastPathComponent()   // Library
    .deletingLastPathComponent()   // Contents
    .deletingLastPathComponent()   // the UI .app

@MainActor
final class LifecycleLauncher: NSObject, NSApplicationDelegate {
    private let session: AuditSessionKey
    private let timer: DispatchSourceTimer
    private let workspace = NSWorkspace.shared
    private let scanner = ProcessScanner()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var applicationsObservation: NSKeyValueObservation?
    private var instanceLock: AdvisoryFileLock?
    private var state: LifecycleState
    private var started = false

    init(session: AuditSessionKey, state: LifecycleState, lock: AdvisoryFileLock) {
        self.session = session
        self.state = state
        self.instanceLock = lock
        self.timer = DispatchSource.makeTimerSource(queue: .main)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !started else { return }
        started = true
        // A launcher start (login, install, launchctl) is deliberate, not a UI crash: the crash
        // budget starts over, while a recorded Quit still holds.
        if !state.recoveryAttempts.isEmpty || state.exhaustedAt != nil {
            state.recoveryAttempts.removeAll()
            state.exhaustedAt = nil
            LifecycleFiles.appendLauncherLog(event: "recovery-budget-reset", generation: state.generation, providers: state.activeProviders, detail: "launcher-start")
        }
        do {
            try LifecycleFiles.ensureDirectories()
            try LifecycleFiles.writeState(state)
        } catch {
            LifecycleFiles.appendLauncherLog(event: "state-start-failed", generation: state.generation, providers: [], detail: String(describing: error))
            NSApp.terminate(nil)
            return
        }
        observeWorkspace()
        timer.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in Task { @MainActor in self?.scanAndReconcile() } }
        timer.resume()
        LifecycleFiles.appendLauncherLog(event: "launcher-start", generation: state.generation, providers: state.activeProviders)
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer.cancel()
        for observer in workspaceObservers { workspace.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        applicationsObservation = nil
    }

    private func observeWorkspace() {
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.willPowerOffNotification] {
            workspaceObservers.append(workspace.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let reason = note.name == NSWorkspace.didWakeNotification ? "wake" : "workspace-change"
                Task { @MainActor in self?.handleWorkspace(noteName: note.name, reason: reason) }
            })
        }
        applicationsObservation = workspace.observe(\.runningApplications, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.requestScan(reason: "running-applications-change") }
        }
    }

    private func handleWorkspace(noteName: Notification.Name, reason: String) {
        if noteName == NSWorkspace.sessionDidResignActiveNotification || noteName == NSWorkspace.willPowerOffNotification {
            if state.sessionActive {
                state.sessionActive = false
                commit(event: "session-suspended", detail: reason)
            }
            return
        }
        if noteName == NSWorkspace.sessionDidBecomeActiveNotification, !state.sessionActive {
            state.sessionActive = true
            commit(event: "session-resumed", detail: "same-session")
        }
        requestScan(reason: reason)
    }

    private func requestScan(reason: String) {
        Task { @MainActor [weak self] in self?.scanAndReconcile(reason: reason) }
    }

    private func scanAndReconcile(reason: String = "interval") {
        precondition(Thread.isMainThread)
        do {
            let identities = try scanner.scan()
            reconcile(identities: identities, reason: reason)
        } catch {
            LifecycleFiles.appendLauncherLog(event: "scan-failed", generation: state.generation, providers: state.activeProviders, detail: "native process scan unavailable")
        }
    }

    private func reconcile(identities: [ProcessIdentity], reason: String) {
        let now = Date().timeIntervalSince1970
        let before = state
        let previousIdentities = Set(state.identities)
        let currentIdentities = Set(identities)
        let newIdentities = currentIdentities.subtracting(previousIdentities)
        state.identities = identities
        state.activeProviders = Array(Set(identities.map(\.provider))).sorted()

        let uiRecord = LifecycleFiles.readUI(for: session)
        if let record = uiRecord,
           let intent = record.quitIntent,
           intent.instanceID == record.instanceID {
            let acknowledgement = QuitIntentAcknowledgement(instanceID: intent.instanceID, at: intent.at)
            if state.acknowledgedQuitIntent != acknowledgement {
                state.acknowledgedQuitIntent = acknowledgement
                if state.intentionalQuit?.instanceID != intent.instanceID || state.intentionalQuit?.at != intent.at {
                    state.intentionalQuit = QuitSuppression(instanceID: intent.instanceID, at: intent.at, baselineIdentities: intent.baselineIdentities.sorted())
                    state.uiInstanceID = intent.instanceID
                    state.uiProcess = record.process
                    state.uiStartedAt = record.createdAt
                    state.launchRequest = nil
                    LifecycleFiles.appendLauncherLog(event: "intentional-quit", generation: state.generation, providers: state.activeProviders)
                }
            }
        }

        if let suppression = state.intentionalQuit {
            let bornAfterQuit = identities.contains { $0.startTime > suppression.at }
            if bornAfterQuit {
                state.intentionalQuit = nil
                state.recoveryAttempts.removeAll()
                state.exhaustedAt = nil
                LifecycleFiles.appendLauncherLog(event: "quit-released-new-identity", generation: state.generation, providers: state.activeProviders)
            }
        }
        if !newIdentities.isEmpty {
            state.recoveryAttempts.removeAll()
            state.exhaustedAt = nil
        }

        if let record = uiRecord {
            let isCurrentInstance = state.uiInstanceID == record.instanceID
            let tokenMatches = record.launchMode == "launcher"
                && record.launchToken != nil
                && state.launchRequest?.token == record.launchToken
            if !isCurrentInstance {
                state.uiInstanceID = record.instanceID
                state.uiProcess = record.process
                state.uiStartedAt = record.createdAt
                state.lastUILaunchAt = record.createdAt
                state.launchRequest = nil
                if record.launchMode == "manual" {
                    state.intentionalQuit = nil
                    state.recoveryAttempts.removeAll()
                    state.exhaustedAt = nil
                    LifecycleFiles.appendLauncherLog(event: "manual-ui-launch", generation: state.generation, providers: state.activeProviders)
                } else if tokenMatches {
                    LifecycleFiles.appendLauncherLog(event: "ui-adopted", generation: state.generation, providers: state.activeProviders)
                } else {
                    // A stale launcher token cannot authorize an app instance; the UI classifies it as manual.
                    state.intentionalQuit = nil
                    LifecycleFiles.appendLauncherLog(event: "ui-adopted", generation: state.generation, providers: state.activeProviders)
                }
            }
        }

        if let request = state.launchRequest, now - request.requestedAt >= 20 {
            state.launchRequest = nil
            if request.reason != "recovery" { state.recoveryAttempts.append(now) }
            state.recoveryAttempts = state.recoveryAttempts.filter { now - $0 < 60 }
            if state.recoveryAttempts.count >= 3, state.exhaustedAt == nil {
                state.exhaustedAt = now
                LifecycleFiles.appendLauncherLog(event: "recovery-exhausted", generation: state.generation, providers: state.activeProviders)
            }
            LifecycleFiles.appendLauncherLog(event: "launch-timeout", generation: state.generation, providers: state.activeProviders, detail: request.reason)
        }

        if state != before { commit(event: "state-change", detail: reason) }
        evaluateLaunch(now: now)
    }

    private func evaluateLaunch(now: TimeInterval) {
        if !state.sessionActive || state.intentionalQuit != nil { return }
        if state.exhaustedAt != nil { return }
        if state.launchRequest != nil { return }
        if state.uiProcess?.isRunning() == true { return }

        let isRecovery = state.uiInstanceID != nil || !state.recoveryAttempts.isEmpty
        guard isRecovery || !state.activeProviders.isEmpty else { return }
        if let lastLaunch = state.lastUILaunchAt, now - lastLaunch < 10 { return }

        state.recoveryAttempts = state.recoveryAttempts.filter { now - $0 < 60 }
        if isRecovery {
            guard state.recoveryAttempts.count < 3 else {
                state.exhaustedAt = now
                LifecycleFiles.appendLauncherLog(event: "recovery-exhausted", generation: state.generation, providers: state.activeProviders)
                commit(event: "recovery-exhausted")
                return
            }
        }
        startUI(reason: isRecovery ? "recovery" : "activity", at: now)
    }

    private func startUI(reason: String, at now: TimeInterval) {
        precondition(Thread.isMainThread)
        guard state.launchRequest == nil else { return }
        let token = UUID().uuidString
        let request = LaunchRequest(token: token, requestedAt: now, reason: reason)
        state.launchRequest = request
        state.lastUILaunchAt = now
        if reason == "recovery" { state.recoveryAttempts.append(now) }
        commit(event: "launch-request", detail: reason)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = false
        var environment = ["USAGETOUCHBAR_LAUNCH_TOKEN": token]
        #if PROVIDER_TEST
        // Verification builds hand their isolated roots to the UI they start.
        for (key, value) in ProcessInfo.processInfo.environment
        where key.hasPrefix("USAGETOUCHBAR_") || key.hasPrefix("USAGE_TEST_") {
            environment[key] = environment[key] ?? value
        }
        #endif
        configuration.environment = environment
        workspace.openApplication(at: uiBundleURL, configuration: configuration) { [weak self] _, error in
            guard let self else { return }
            Task { @MainActor in
                guard self.state.launchRequest?.token == token else { return }
                if error != nil {
                    let failedAt = Date().timeIntervalSince1970
                    self.state.launchRequest = nil
                    if reason != "recovery" { self.state.recoveryAttempts.append(failedAt) }
                    self.state.recoveryAttempts = self.state.recoveryAttempts.filter { failedAt - $0 < 60 }
                    if self.state.recoveryAttempts.count >= 3, self.state.exhaustedAt == nil {
                        self.state.exhaustedAt = failedAt
                        LifecycleFiles.appendLauncherLog(event: "recovery-exhausted", generation: self.state.generation, providers: self.state.activeProviders)
                    }
                    LifecycleFiles.appendLauncherLog(event: "launch-failed", generation: self.state.generation, providers: self.state.activeProviders, detail: reason)
                    self.commit(event: "launch-failed")
                }
            }
        }
    }

    private func commit(event: String, detail: String = "") {
        state.generation += 1
        state.updatedAt = Date().timeIntervalSince1970
        do {
            try LifecycleFiles.writeState(state)
            LifecycleNotification.post(LifecycleNotification.stateChanged)
            LifecycleFiles.appendLauncherLog(event: event, generation: state.generation, providers: state.activeProviders, detail: detail)
        } catch {
            LifecycleFiles.appendLauncherLog(event: "state-write-failed", generation: state.generation, providers: state.activeProviders, detail: String(describing: error))
        }
    }
}

@main
enum UsageTouchBarLauncherMain {
    static func main() {
        guard let session = AuditSessionKey.current() else { exit(78) }
        do {
            guard let lock = try AdvisoryFileLock.acquire(LifecyclePaths.launcherLock) else { exit(0) }
            let state = LifecycleFiles.readState(for: session) ?? LifecycleState.fresh(session: session)
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            let launcher = LifecycleLauncher(session: session, state: state, lock: lock)
            app.delegate = launcher
            objc_setAssociatedObject(app, "launcher", launcher, .OBJC_ASSOCIATION_RETAIN)
            app.run()
        } catch {
            exit(78)
        }
    }
}
