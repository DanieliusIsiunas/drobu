import Foundation
import Testing
@testable import DrobuCore

@Suite("EditAction")
struct EditActionTests {

    // MARK: - editVerb(forKind:) — kind-only, no availability gate

    // The verb is uniformly "edit" — ⌘→ opens edit mode; crop/trim/text-edit happen inside.
    @Test("kind-only verb is 'edit' for every editable kind, nil otherwise")
    func kindOnlyVerb() {
        #expect(editVerb(forKind: ClipboardRecord.kindText) == "edit")
        #expect(editVerb(forKind: ClipboardRecord.kindImage) == "edit")
        #expect(editVerb(forKind: ClipboardRecord.kindGif) == "edit")
        #expect(editVerb(forKind: ClipboardRecord.kindVideo) == "edit")
        #expect(editVerb(forKind: ClipboardRecord.kindFile) == nil)
        #expect(editVerb(forKind: "something-unknown") == nil)
    }

    // MARK: - editActionVerb — data-gated (the ⌘→ entry gate's source of truth)

    @Test("text edits when plainText present, not when absent")
    func textGate() {
        let present = makeRecord(kind: ClipboardRecord.kindText, plainText: "hello")
        #expect(editActionVerb(for: present, isBitmapImage: false, videoFileExists: false) == "edit")
        let absent = makeRecord(kind: ClipboardRecord.kindText, plainText: nil)
        #expect(editActionVerb(for: absent, isBitmapImage: false, videoFileExists: false) == nil)
    }

    @Test("image is editable only when bitmap")
    func imageGate() {
        let img = makeRecord(kind: ClipboardRecord.kindImage, plainText: nil, imageData: Data([0x1, 0x2]))
        #expect(editActionVerb(for: img, isBitmapImage: true, videoFileExists: false) == "edit")
        #expect(editActionVerb(for: img, isBitmapImage: false, videoFileExists: false) == nil)
    }

    @Test("gif is editable when imageData present, not when nil")
    func gifGate() {
        let withData = makeRecord(kind: ClipboardRecord.kindGif, plainText: nil, imageData: Data([0x1]))
        #expect(editActionVerb(for: withData, isBitmapImage: false, videoFileExists: false) == "edit")
        let noData = makeRecord(kind: ClipboardRecord.kindGif, plainText: nil, imageData: nil)
        #expect(editActionVerb(for: noData, isBitmapImage: false, videoFileExists: false) == nil)
    }

    @Test("video is editable only when file exists")
    func videoGate() {
        let vid = makeRecord(kind: ClipboardRecord.kindVideo, plainText: nil)
        #expect(editActionVerb(for: vid, isBitmapImage: false, videoFileExists: true) == "edit")
        #expect(editActionVerb(for: vid, isBitmapImage: false, videoFileExists: false) == nil)
    }

    @Test("file kind is never editable, regardless of facts")
    func fileNeverEditable() {
        let file = makeRecord(kind: ClipboardRecord.kindFile, plainText: "/tmp/a.txt")
        #expect(editActionVerb(for: file, isBitmapImage: true, videoFileExists: true) == nil)
    }
}
