import Foundation

@MainActor
final class ClosedLidService {
    enum State: Equatable {
        case idle
        case active(startDate: Date, duration: TimeInterval)
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    var onStateChange: ((State) -> Void)?

    private var caffeinateProcess: Process?
    private var reconciliationTimer: Timer?
    private var isActivating = false

    // MARK: - Paths

    private static let daemonLabel = "com.clipboardhistory.disablesleep-reversal"
    private static let daemonPlistPath = "/Library/LaunchDaemons/\(daemonLabel).plist"
    private static let cleanupScriptPath = "/Library/Application Support/ClipboardHistory/cleanup-disablesleep.sh"
    private static let sudoersPath = "/etc/sudoers.d/clipboardhistory-cleanup"

    // MARK: - Public API

    var isActive: Bool {
        if case .idle = state { return false }
        return true
    }

    var remainingTime: TimeInterval? {
        guard case .active(let startDate, let duration) = state else { return nil }
        let remaining = startDate.addingTimeInterval(duration).timeIntervalSinceNow
        return max(0, remaining)
    }

    /// Activate Closed Lid mode. Shows macOS admin auth dialog.
    /// Throws `PrivilegedCommandError.userCancelled` if user cancels auth.
    func start(duration: TimeInterval) throws {
        guard !isActivating else { return }
        isActivating = true
        defer { isActivating = false }

        // Stop any existing session first
        if isActive { stopInternal() }

        let durationInt = Int(duration)
        let username = NSUserName()

        // 1. Generate LaunchDaemon plist XML
        let plistXML = generateDaemonPlist(sleepSeconds: durationInt)

        // 2. Write plist to /tmp first (no privileges needed)
        let tmpPlistPath = "/tmp/\(Self.daemonLabel).plist"
        try? plistXML.write(toFile: tmpPlistPath, atomically: true, encoding: .utf8)

        // 3. Build the privileged batch command
        let batch = buildActivationCommand(
            tmpPlistPath: tmpPlistPath,
            username: username,
            durationInt: durationInt
        )

        // 4. Run with admin auth (shows password dialog)
        _ = try runPrivileged(batch)

        // 5. Start companion caffeinate process
        startCaffeinate(duration: duration)

        // 6. Update state and start reconciliation
        state = .active(startDate: Date(), duration: duration)
        startReconciliationTimer()
    }

    /// Deactivate Closed Lid mode. No auth prompt needed (uses sudoers entry).
    func stop() {
        stopInternal()
    }

    /// Best-effort cleanup for applicationWillTerminate / signal handlers.
    func cleanup() {
        // Kill caffeinate
        if let proc = caffeinateProcess, proc.isRunning {
            proc.terminate()
        }
        caffeinateProcess = nil
        reconciliationTimer?.invalidate()
        reconciliationTimer = nil

        // Run cleanup script via sudo (no auth needed due to sudoers entry)
        guard isActive else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        proc.arguments = [Self.cleanupScriptPath]
        try? proc.run()
        proc.waitUntilExit()
        state = .idle
    }

    /// Check if pmset disablesleep is currently enabled (no root needed).
    func isDisableSleepActive() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        proc.arguments = ["-g"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.contains("SleepDisabled") && output.contains("1")
        } catch {
            return false
        }
    }

    // MARK: - Private

    private func stopInternal() {
        // Kill caffeinate first
        if let proc = caffeinateProcess {
            caffeinateProcess = nil
            if proc.isRunning { proc.terminate() }
        }

        reconciliationTimer?.invalidate()
        reconciliationTimer = nil

        // Run cleanup script via sudo (no auth prompt due to NOPASSWD entry)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        proc.arguments = [Self.cleanupScriptPath]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            NSLog("ClosedLidService: cleanup script failed: \(error)")
        }

        state = .idle
    }

    private func startCaffeinate(duration: TimeInterval) {
        if let old = caffeinateProcess, old.isRunning {
            old.terminate()
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        proc.arguments = ["-dims", "-t", "\(Int(duration))"]

        proc.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor in
                guard let self, self.caffeinateProcess === terminatedProcess else { return }
                // Caffeinate exited (timer expired or killed externally).
                // Check if pmset is still active and reverse it.
                if self.isActive {
                    self.stopInternal()
                }
            }
        }

        do {
            try proc.run()
            caffeinateProcess = proc
        } catch {
            NSLog("ClosedLidService: failed to launch caffeinate: \(error)")
        }
    }

    private func startReconciliationTimer() {
        reconciliationTimer?.invalidate()
        reconciliationTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                // If pmset was reversed externally, clear our state
                if !self.isDisableSleepActive() {
                    NSLog("ClosedLidService: pmset disablesleep was reversed externally")
                    if let proc = self.caffeinateProcess, proc.isRunning {
                        proc.terminate()
                    }
                    self.caffeinateProcess = nil
                    self.reconciliationTimer?.invalidate()
                    self.reconciliationTimer = nil
                    self.state = .idle
                }
            }
        }
    }

    // MARK: - Command Building

    private func buildActivationCommand(tmpPlistPath: String, username: String, durationInt: Int) -> String {
        let escapedCleanupPath = Self.cleanupScriptPath.replacingOccurrences(of: " ", with: "\\\\ ")
        let escapedCleanupDir = "/Library/Application\\\\ Support/ClipboardHistory"

        return """
        /usr/bin/pmset disablesleep 1 && \
        mkdir -p /Library/Application\\ Support/ClipboardHistory && \
        cat > '\(Self.cleanupScriptPath)' << 'CLEANUP_SCRIPT'
        #!/bin/sh
        /usr/bin/pmset disablesleep 0
        /bin/launchctl bootout system/\(Self.daemonLabel) 2>/dev/null
        /bin/rm -f '\(Self.daemonPlistPath)'
        /bin/rm -f '\(Self.cleanupScriptPath)'
        /bin/rm -f '\(Self.sudoersPath)'
        CLEANUP_SCRIPT
        chmod 755 '\(Self.cleanupScriptPath)' && \
        echo '\(username) ALL=(root) NOPASSWD: \(Self.cleanupScriptPath)' > '\(Self.sudoersPath)' && \
        chmod 440 '\(Self.sudoersPath)' && \
        /bin/launchctl bootout system/\(Self.daemonLabel) 2>/dev/null ; \
        cp '\(tmpPlistPath)' '\(Self.daemonPlistPath)' && \
        chown root:wheel '\(Self.daemonPlistPath)' && \
        chmod 644 '\(Self.daemonPlistPath)' && \
        /bin/launchctl bootstrap system '\(Self.daemonPlistPath)'
        """
    }

    private func generateDaemonPlist(sleepSeconds: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(Self.daemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/sh</string>
                <string>-c</string>
                <string>/bin/sleep \(sleepSeconds); /usr/bin/pmset disablesleep 0</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>StandardErrorPath</key>
            <string>/tmp/disablesleep-reversal.log</string>
        </dict>
        </plist>
        """
    }
}
