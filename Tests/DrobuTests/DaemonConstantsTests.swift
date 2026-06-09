import Foundation
import Testing
@testable import DrobuShared

/// Pins the daemon launchd plist against `DaemonConstants`. The whole point of
/// `DrobuShared` is that the plist, the Mach-service name, and the code-sign
/// identity are one source of truth — these tests fail loudly if the plist and
/// the constants drift apart.
@Suite("DaemonConstants")
struct DaemonConstantsTests {

    /// Resolve the daemon plist from the repo source tree via `#filePath`. SPM
    /// resources are target-scoped, so the daemon's plist cannot be a
    /// `DrobuTests` resource (review amendment U2); it is read from its real
    /// `Sources/DrobuDaemon/` location instead.
    private func loadDaemonPlist() throws -> [String: Any] {
        let repoRoot = URL(fileURLWithPath: #filePath) // …/Tests/DrobuTests/DaemonConstantsTests.swift
            .deletingLastPathComponent()               // …/Tests/DrobuTests
            .deletingLastPathComponent()               // …/Tests
            .deletingLastPathComponent()               // repo root
        let plistURL = repoRoot
            .appendingPathComponent("Sources/DrobuDaemon")
            .appendingPathComponent(DaemonConstants.plistName)
        let data = try Data(contentsOf: plistURL)
        let obj = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try #require(obj as? [String: Any])
    }

    @Test("plist Label matches the daemon label constant")
    func plistLabelMatchesConstant() throws {
        let plist = try loadDaemonPlist()
        #expect(plist["Label"] as? String == DaemonConstants.daemonLabel)
    }

    @Test("plist MachServices contains exactly the mach-service constant")
    func plistMachServiceMatchesConstant() throws {
        let plist = try loadDaemonPlist()
        let mach = try #require(plist["MachServices"] as? [String: Any])
        #expect(mach[DaemonConstants.machServiceName] != nil)
        #expect(mach.count == 1) // exactly one service — catches stray drift
    }

    @Test("plist BundleProgram points at the daemon binary path constant")
    func plistBundleProgramMatchesConstant() throws {
        let plist = try loadDaemonPlist()
        #expect(plist["BundleProgram"] as? String == DaemonConstants.bundleProgramPath)
    }

    @Test("plist AssociatedBundleIdentifiers references the app bundle id")
    func plistAssociatesWithApp() throws {
        let plist = try loadDaemonPlist()
        let assoc = try #require(plist["AssociatedBundleIdentifiers"] as? [String])
        #expect(assoc.contains(DaemonConstants.appBundleIdentifier))
    }

    @Test("legacy artifact paths match the documented set exactly, sudoers first")
    func legacyArtifactPathsExact() {
        #expect(DaemonConstants.legacyArtifactPaths == [
            "/etc/sudoers.d/clipboardhistory-cleanup",
            "/Library/Application Support/ClipboardHistory/cleanup-disablesleep.sh",
            "/Library/LaunchDaemons/com.clipboardhistory.disablesleep-reversal.plist",
        ])
        // The sudoers entry is removed FIRST in any cleanup ordering (R9).
        #expect(DaemonConstants.legacyArtifactPaths.first == DaemonConstants.legacySudoersPath)
        // The fourth documented artifact is the launchd label (a `bootout`
        // target, not a file) — verified separately from the path list.
        #expect(DaemonConstants.legacyLaunchdLabel == "com.clipboardhistory.disablesleep-reversal")
    }

    @Test("protocol version is a positive integer")
    func protocolVersionPositive() {
        #expect(drobuDaemonProtocolVersion > 0)
    }

    @Test("daemon identity is distinct from the app, and the client requirement pins the app (M3)")
    func daemonIdentityDistinctFromApp() {
        #expect(DaemonConstants.daemonLabel != DaemonConstants.appBundleIdentifier)
        // The pinned requirement names the APP id + Team ID — the daemon's own
        // identifier (…​.daemon) must therefore NOT satisfy it.
        #expect(DaemonConstants.clientCodeSigningRequirement.contains("\"\(DaemonConstants.appBundleIdentifier)\""))
        #expect(DaemonConstants.clientCodeSigningRequirement.contains(DaemonConstants.teamIdentifier))
        #expect(DaemonConstants.clientCodeSigningRequirement.contains("anchor apple generic"))
    }
}
