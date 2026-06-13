import Foundation
import Testing
@testable import DrobuCore

@Suite("DataEraser")
struct DataEraserTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("drobu-erase-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("removes the whole app-support directory and the UserDefaults domain")
    func erasesDirAndDefaults() throws {
        let dir = makeTempDir()
        try Data("db".utf8).write(to: dir.appendingPathComponent("clipboard.sqlite"))
        try Data("wal".utf8).write(to: dir.appendingPathComponent("clipboard.sqlite-wal"))
        let videos = dir.appendingPathComponent("videos")
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        try Data("v".utf8).write(to: videos.appendingPathComponent("a.mp4"))

        let suite = "com.danielius.ClipboardHistory.test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "someSetting")

        let eraser = DataEraser(directory: dir, defaults: defaults, defaultsDomain: suite)
        try eraser.eraseAllUserData()

        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(defaults.object(forKey: "someSetting") == nil)

        defaults.removePersistentDomain(forName: suite)   // belt-and-suspenders cleanup
    }

    @Test("tolerates a missing directory without throwing")
    func toleratesMissingDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("drobu-erase-missing-\(UUID().uuidString)")
        let suite = "com.danielius.ClipboardHistory.test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!

        let eraser = DataEraser(directory: dir, defaults: defaults, defaultsDomain: suite)
        try eraser.eraseAllUserData()   // must not throw on an absent directory

        #expect(!FileManager.default.fileExists(atPath: dir.path))
        defaults.removePersistentDomain(forName: suite)
    }
}
