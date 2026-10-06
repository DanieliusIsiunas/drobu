import Testing
import CoreGraphics
import Foundation
@testable import DrobuCore

@MainActor
@Suite("ImageEditSession")
struct ImageEditSessionTests {

    /// Captures which save route fired.
    final class Outcome {
        var saved: Data?
        var savedAsNew: Data?
        var discarded = false
    }

    private func makeSession(width: Int = 200, height: Int = 120) async -> (ImageEditSession, Outcome, UserDefaults, String) {
        let suite = "com.danielius.ClipboardHistory.edit-session-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let session = ImageEditSession(
            data: ImageCropTests.makePNG(width: width, height: height),
            contentHash: "hash",
            defaults: defaults,
            fallbackDensity: { 1 }
        )
        let outcome = Outcome()
        session.onSave = { outcome.saved = $0 }
        session.onSaveAsNew = { outcome.savedAsNew = $0 }
        session.onDiscard = { outcome.discarded = true }
        await session.load().value
        return (session, outcome, defaults, suite)
    }

    @Test func loadSetsFullFrameCropFromPixelSize() async {
        let (session, _, defaults, suite) = await makeSession(width: 200, height: 120)
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(session.cgImage != nil)
        #expect(session.cropGeometry.contentWidth == 200 && session.cropGeometry.contentHeight == 120)
        #expect(session.cropGeometry.isFullFrame)
    }

    @Test func untouchedSaveDiscards() async {
        let (session, outcome, defaults, suite) = await makeSession()
        defer { defaults.removePersistentDomain(forName: suite) }
        await session.save()?.value
        #expect(outcome.discarded)
        #expect(outcome.saved == nil && outcome.savedAsNew == nil)
    }

    @Test func cropOnlySaveReplacesInPlace() async throws {
        let (session, outcome, defaults, suite) = await makeSession()
        defer { defaults.removePersistentDomain(forName: suite) }
        session.cropGeometry.drag(corner: .bottomRight, toContentPoint: CGPoint(x: 100, y: 60))
        await session.save()?.value
        let png = try #require(outcome.saved)
        #expect(outcome.savedAsNew == nil && !outcome.discarded)
        let image = try #require(ImageCrop.decodeBitmap(from: png))
        #expect(image.width == 100 && image.height == 60)
    }

    @Test func markupSaveCreatesNewItem() async throws {
        let (session, outcome, defaults, suite) = await makeSession()
        defer { defaults.removePersistentDomain(forName: suite) }
        session.annotations = [MarkupAnnotation(shape: .box(CGRect(x: 10, y: 10, width: 50, height: 50)), color: .red)]
        await session.save()?.value
        #expect(try #require(outcome.savedAsNew).isEmpty == false)
        #expect(outcome.saved == nil && !outcome.discarded)
    }

    @Test func pickRecoloursOnlyTheSelectionAndPersists() async {
        let (session, _, defaults, suite) = await makeSession()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = MarkupAnnotation(shape: .box(CGRect(x: 0, y: 0, width: 20, height: 20)), color: .red)
        let b = MarkupAnnotation(shape: .box(CGRect(x: 40, y: 0, width: 20, height: 20)), color: .red)
        session.annotations = [a, b]
        session.selectedID = b.id
        session.pick(.green)
        #expect(session.annotations.map(\.color) == [.red, .green])
        #expect(session.color == .green)
        #expect(MarkupDefaults.loadColor(from: defaults) == .green)
    }

    @Test func undoAndDeleteClearSelection() async {
        let (session, _, defaults, suite) = await makeSession()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = MarkupAnnotation(shape: .box(CGRect(x: 0, y: 0, width: 20, height: 20)), color: .red)
        let b = MarkupAnnotation(shape: .box(CGRect(x: 40, y: 0, width: 20, height: 20)), color: .red)
        session.annotations = [a, b]
        session.selectedID = b.id
        session.undoLast()
        #expect(session.annotations.map(\.id) == [a.id])
        #expect(session.selectedID == nil)

        session.selectedID = a.id
        session.deleteSelected()
        #expect(session.annotations.isEmpty && session.selectedID == nil)
    }

    @Test func secondSaveWhileSavingIsIgnored() async {
        let (session, outcome, defaults, suite) = await makeSession()
        defer { defaults.removePersistentDomain(forName: suite) }
        session.annotations = [MarkupAnnotation(shape: .box(CGRect(x: 10, y: 10, width: 50, height: 50)), color: .red)]
        var newItems = 0
        session.onSaveAsNew = { _ in newItems += 1 }
        let first = session.save()
        #expect(session.isSaving)
        #expect(session.save() == nil)   // re-entrant ⌘↩ while encoding
        session.discard()                // Esc while encoding is ignored too
        await first?.value
        #expect(newItems == 1)
        #expect(!outcome.discarded)
    }

    @Test func undecodableImageDiscards() async {
        let session = ImageEditSession(data: Data("not an image".utf8), contentHash: "x", fallbackDensity: { 1 })
        var discarded = false
        session.onDiscard = { discarded = true }
        await session.load().value
        #expect(discarded)
        #expect(session.cgImage == nil)
    }
}
