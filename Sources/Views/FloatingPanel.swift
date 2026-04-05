import AppKit
import SwiftUI
import ApplicationServices
import Carbon.HIToolbox
/// A non-activating floating panel that hosts SwiftUI content.
/// Behaves like Alfred/Spotlight: appears without stealing focus, receives keyboard input,
/// dismisses on click outside or app switch.
final class FloatingPanel: NSPanel {
    private var bufferedKeystrokes: String = ""

    // Shift-tap detection: toggle preview on Shift release if no other key was pressed
    private var shiftDownWithoutKey = false
    private var flagsMonitor: Any?
    private var keyDownMonitor: Any?
    var onShiftTap: (() -> Void)?

    init<Content: View>(contentRect: NSRect = NSRect(x: 0, y: 0, width: 780, height: 500),
                        @ViewBuilder content: @escaping () -> Content) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        animationBehavior = .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        contentView = NSHostingView(rootView:
            content()
                .ignoresSafeArea()
                .environment(\.floatingPanel, WeakFloatingPanel(panel: self))
        )

        // Monitor modifier key changes for Shift-tap detection.
        // Using local monitors (not overrides) so they fire even when
        // an NSTextView (search field) has first responder, and even when
        // SwiftUI's onKeyPress consumes the event before it reaches keyDown.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.shiftDownWithoutKey = false
            return event
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func close() {
        // Remove event monitors
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownMonitor = nil
        }
        // Close child windows (e.g. large preview) before closing self
        childWindows?.forEach { $0.close() }
        super.close()
    }

    override func resignKey() {
        super.resignKey()
        close()
    }

    /// Buffer keystrokes that arrive before SwiftUI focus is established.
    override func keyDown(with event: NSEvent) {
        shiftDownWithoutKey = false   // any key cancels a pending shift-tap
        if let chars = event.characters, !chars.isEmpty {
            bufferedKeystrokes.append(chars)
        }
        super.keyDown(with: event)
    }

    // MARK: - Shift-Tap Detection

    private func handleFlagsChanged(_ event: NSEvent) {
        if event.modifierFlags.contains(.shift) {
            // Shift pressed down
            shiftDownWithoutKey = true
        } else if shiftDownWithoutKey {
            // Shift released with no intervening key → tap
            shiftDownWithoutKey = false
            onShiftTap?()
        }
    }

    /// Consume buffered keystrokes and clear the buffer.
    func consumeBufferedKeystrokes() -> String {
        let buffer = bufferedKeystrokes
        bufferedKeystrokes = ""
        return buffer
    }

    // MARK: - Show / Hide / Toggle

    func showCentered() {
        // Size window to fit SwiftUI content exactly (search bar + divider + list area).
        // This avoids hardcoding the panel height — it's computed from row constants.
        if let cv = contentView {
            cv.layoutSubtreeIfNeeded()
            let fitting = cv.fittingSize
            if fitting.width > 0 && fitting.height > 0 {
                setContentSize(fitting)
            }
        }

        // Center on screen containing the mouse cursor
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        guard let screen = screen else { return }

        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.midY - frame.height / 2 + 60
        setFrameOrigin(NSPoint(x: x, y: y))

        bufferedKeystrokes = ""
        makeKeyAndOrderFront(nil)
    }

    func toggle() {
        if isVisible {
            close()
        } else {
            showCentered()
        }
    }

    // MARK: - Auto-Paste via CGEvent

    func pasteItem(_ record: ClipboardRecord) {
        // Suppress monitor's next change detection to prevent self-capture
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.monitor?.suppressNextChange()
        }

        // 1. Close panel first (animationBehavior = .none makes this instant)
        // Matches Maccy's sequence: close → copy → paste
        close()

        // 2. Write to pasteboard (works without any permission)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch record.kind {
        case ClipboardRecord.kindText:
            if let text = record.plainText {
                pasteboard.setString(text, forType: .string)
            }
        case ClipboardRecord.kindGif:
            if let data = record.imageData {
                Self.writeGIFToPasteboard(data, pasteboard: pasteboard)
            }
        case ClipboardRecord.kindImage:
            if let data = record.imageData {
                pasteboard.setData(data, forType: .tiff)
            }
        case ClipboardRecord.kindVideo:
            let url = ClipboardRecord.videoPath(for: record.contentHash)
            if FileManager.default.fileExists(atPath: url.path) {
                pasteboard.writeObjects([url as NSURL])
            }
        default:
            break
        }

        Log.debug("FloatingPanel: pasted \(record.kind) (\(record.imageData?.count ?? record.plainText?.utf8.count ?? 0) bytes)")

        // 3. Auto-paste if we have Accessibility, otherwise show "Copied" notification
        if AXIsProcessTrusted() {
            firePaste()
        } else {
            showCopiedNotification()
        }
    }

    // MARK: - Multi-Item Paste

    private enum PasteOperation {
        case text(String)
        case image(Data)
        case gif(Data)
        case video(URL)
    }

    func pasteItems(_ records: [ClipboardRecord]) {
        guard !records.isEmpty else { return }

        // Single item — use existing fast path
        if records.count == 1 {
            pasteItem(records[0])
            return
        }

        // Calculate how many pasteboard writes we'll make for suppression
        let imageCount = records.filter { $0.kind == ClipboardRecord.kindImage || $0.kind == ClipboardRecord.kindGif }.count
        let videoCount = records.filter { $0.kind == ClipboardRecord.kindVideo }.count
        let textItems = records.filter { $0.kind == ClipboardRecord.kindText }
        let suppressCount = (textItems.isEmpty ? 0 : 1) + imageCount + videoCount

        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.monitor?.suppressChanges(count: suppressCount)
        }

        // Close panel first (instant)
        close()

        guard AXIsProcessTrusted() else {
            // Without accessibility, concatenate text and put on pasteboard (best effort)
            if !textItems.isEmpty {
                let combined = textItems.compactMap(\.plainText).joined(separator: "\n")
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(combined, forType: .string)
            }
            showCopiedNotification()
            return
        }

        // Build paste operations: text concatenated first, then images individually
        var operations: [PasteOperation] = []

        if !textItems.isEmpty {
            let combined = textItems.compactMap(\.plainText).joined(separator: "\n")
            operations.append(.text(combined))
        }
        let mediaItems = records.filter { $0.kind == ClipboardRecord.kindImage || $0.kind == ClipboardRecord.kindGif || $0.kind == ClipboardRecord.kindVideo }
        for item in mediaItems {
            if item.kind == ClipboardRecord.kindVideo {
                let url = ClipboardRecord.videoPath(for: item.contentHash)
                if FileManager.default.fileExists(atPath: url.path) {
                    operations.append(.video(url))
                }
            } else if let data = item.imageData {
                if item.kind == ClipboardRecord.kindGif {
                    operations.append(.gif(data))
                } else {
                    operations.append(.image(data))
                }
            }
        }

        // Execute sequentially with delay
        Log.debug("FloatingPanel: pasting \(operations.count) items sequentially")
        executePasteSequence(operations, index: 0)
    }

    private func executePasteSequence(_ ops: [PasteOperation], index: Int) {
        guard index < ops.count else { return }

        let pb = NSPasteboard.general
        pb.clearContents()

        switch ops[index] {
        case .text(let str):
            pb.setString(str, forType: .string)
        case .image(let data):
            // Write both TIFF and PNG representations for maximum app compatibility
            if let bitmapRep = NSBitmapImageRep(data: data),
               let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                pb.setData(pngData, forType: .png)
            }
            pb.setData(data, forType: .tiff)
        case .gif(let data):
            Self.writeGIFToPasteboard(data, pasteboard: pb)
        case .video(let url):
            pb.writeObjects([url as NSURL])
        }

        firePaste()

        // Schedule next operation after delay.
        // Image/video pastes need a longer delay — apps need time to
        // process each file before accepting the next paste.
        if index + 1 < ops.count {
            let nextIsMedia: Bool
            switch ops[index + 1] {
            case .image, .gif, .video: nextIsMedia = true
            default: nextIsMedia = false
            }
            let delay: TimeInterval = nextIsMedia ? 0.6 : 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.executePasteSequence(ops, index: index + 1)
            }
        }
    }

    private func firePaste() {
        let vKeyCode: CGKeyCode = CGKeyCode(kVK_ANSI_V)
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                           state: .eventSuppressionStateSuppressionInterval)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else {
            Log.error("FloatingPanel: CGEvent creation failed — paste will not fire")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
        Log.debug("FloatingPanel: fired Cmd+V")
    }

    /// Write GIF data to pasteboard as a temp file URL.
    /// Apps like Mattermost/Google Docs ignore raw `com.compuserve.gif` data
    /// and only treat images as GIF when provided as a file URL (like Finder does).
    static func writeGIFToPasteboard(_ gifData: Data, pasteboard: NSPasteboard) {
        // Write to a temp file so receiving apps detect the .gif format
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardHistory-\(UUID().uuidString).gif")
        do {
            try gifData.write(to: tempURL)
        } catch {
            // Fallback: write raw data types if temp file fails
            pasteboard.setData(gifData, forType: .gif)
            return
        }
        // File URL is the primary type (matches Finder behavior)
        pasteboard.writeObjects([tempURL as NSURL])
    }

    private func showCopiedNotification() {
        let hudWidth: CGFloat = 220
        let hudHeight: CGFloat = 36

        let hud = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: hudWidth, height: hudHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.level = .floating
        hud.ignoresMouseEvents = true
        hud.hasShadow = true

        let visual = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: hudWidth, height: hudHeight))
        visual.material = .hudWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 10

        let label = NSTextField(labelWithString: "Copied! Paste with \u{2318}V")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.frame = visual.bounds
        label.autoresizingMask = [.width, .height]
        visual.addSubview(label)

        hud.contentView = visual

        // Position near screen center
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - hudWidth / 2
            let y = screenFrame.midY - hudHeight / 2
            hud.setFrameOrigin(NSPoint(x: x, y: y))
        }

        hud.orderFront(nil)

        // Auto-dismiss after 1.5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.3
                    hud.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated {
                        hud.close()
                    }
                })
            }
        }
    }
}

// MARK: - Environment Key

struct WeakFloatingPanel {
    weak var panel: FloatingPanel?
}

private struct FloatingPanelKey: EnvironmentKey {
    static let defaultValue: WeakFloatingPanel = WeakFloatingPanel(panel: nil)
}

extension EnvironmentValues {
    var floatingPanel: WeakFloatingPanel {
        get { self[FloatingPanelKey.self] }
        set { self[FloatingPanelKey.self] = newValue }
    }
}
