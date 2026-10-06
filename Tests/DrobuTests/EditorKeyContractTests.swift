import AppKit
import Testing
@testable import DrobuCore

/// The image editor's key contract — also what the large preview uses to hand keys
/// back to the editor after Live Text takes focus.
@MainActor
@Suite("EditorKeyContract")
struct EditorKeyContractTests {

    private func key(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        )!
    }

    @Test func ownsTheEditorKeys() {
        #expect(ImageEditorKeyNSView.ownsKey(key("\u{1b}", code: 53)))               // Esc
        #expect(ImageEditorKeyNSView.ownsKey(key("\r", code: 36, .command)))         // ⌘↩
        #expect(ImageEditorKeyNSView.ownsKey(key("\r", code: 36, [.command, .shift]))) // ⌘⇧↩ saves too
        #expect(ImageEditorKeyNSView.ownsKey(key("1", code: 18)))
        #expect(ImageEditorKeyNSView.ownsKey(key("4", code: 21)))
        #expect(ImageEditorKeyNSView.ownsKey(key("\u{7f}", code: 51)))               // Delete
        #expect(ImageEditorKeyNSView.ownsKey(key("\u{f728}", code: 117)))            // Forward Delete
        #expect(ImageEditorKeyNSView.ownsKey(key("z", code: 6, .command)))           // ⌘Z
    }

    @Test func leavesOtherKeysAlone() {
        #expect(!ImageEditorKeyNSView.ownsKey(key("c", code: 8, .command)))  // ⌘C copies Live Text
        #expect(!ImageEditorKeyNSView.ownsKey(key("\r", code: 36)))          // plain Return confirms a label
        #expect(!ImageEditorKeyNSView.ownsKey(key("5", code: 23)))           // beyond the palette
        #expect(!ImageEditorKeyNSView.ownsKey(key("1", code: 18, .command))) // ⌘1 is not a colour
        #expect(!ImageEditorKeyNSView.ownsKey(key("a", code: 0)))
    }

    @Test func digitsMapToPaletteOrder() {
        #expect(ImageEditorKeyNSView.paletteColor(for: key("1", code: 18)) == MarkupColor.allCases[0])
        #expect(ImageEditorKeyNSView.paletteColor(for: key("4", code: 21)) == MarkupColor.allCases[3])
    }

    @Test func saveContractMatchesBaseEditor() {
        #expect(EditorKeyNSView.isSaveKey(key("\r", code: 36, [.command, .option])))
        #expect(!EditorKeyNSView.isSaveKey(key("\r", code: 36)))
        #expect(EditorKeyNSView.isDiscardKey(key("\u{1b}", code: 53)))
    }
}
