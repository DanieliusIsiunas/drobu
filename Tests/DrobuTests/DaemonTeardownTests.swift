import Foundation
import Testing
@testable import DrobuShared

@Suite("DaemonTeardown")
struct DaemonTeardownTests {

    @Test("removes existing safe paths and returns them")
    func removesSafe() {
        var removed: [String] = []
        let result = DaemonTeardown.removeFiles(
            ["/a", "/b"],
            exists: { _ in true },
            isSafe: { _ in true },
            remove: { removed.append($0) })
        #expect(result == ["/a", "/b"])
        #expect(removed == ["/a", "/b"])
    }

    @Test("missing paths are tolerated — skipped, not removed")
    func skipsMissing() {
        var removed: [String] = []
        let result = DaemonTeardown.removeFiles(
            ["/a", "/b"],
            exists: { $0 == "/a" },     // only /a exists
            isSafe: { _ in true },
            remove: { removed.append($0) })
        #expect(result == ["/a"])
        #expect(removed == ["/a"])
    }

    @Test("unsafe paths are refused — never removed, reported via onRefused")
    func refusesUnsafe() {
        var removed: [String] = []
        var refused: [String] = []
        let result = DaemonTeardown.removeFiles(
            ["/safe", "/unsafe"],
            exists: { _ in true },
            isSafe: { $0 == "/safe" },  // /unsafe fails the symlink/ownership check
            remove: { removed.append($0) },
            onRefused: { refused.append($0) })
        #expect(result == ["/safe"])
        #expect(removed == ["/safe"])
        #expect(refused == ["/unsafe"])
    }

    @Test("a remove error is reported and does not stop later paths")
    func toleratesRemoveError() {
        struct RemoveError: Error {}
        var removed: [String] = []
        var errored: [String] = []
        let result = DaemonTeardown.removeFiles(
            ["/x", "/y"],
            exists: { _ in true },
            isSafe: { _ in true },
            remove: { path in if path == "/x" { throw RemoveError() }; removed.append(path) },
            onError: { path, _ in errored.append(path) })
        #expect(errored == ["/x"])
        #expect(removed == ["/y"])   // continued past the error
        #expect(result == ["/y"])
    }
}
