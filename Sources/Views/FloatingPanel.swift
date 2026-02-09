import AppKit
import SwiftUI
import ApplicationServices
import Carbon.HIToolbox

/// A non-activating floating panel that hosts SwiftUI content.
/// Behaves like Alfred/Spotlight: appears without stealing focus, receives keyboard input,
/// dismisses on click outside or app switch.
final class FloatingPanel: NSPanel {
    private var previousApp: NSRunningApplication?
    private var activationObserver: Any?
    private var bufferedKeystrokes: String = ""

    init<Content: View>(contentRect: NSRect = NSRect(x: 0, y: 0, width: 780, height: 460),
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
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func close() {
        removeActivationObserver()
        super.close()
    }

    override func resignKey() {
        super.resignKey()
        close()
    }

    /// Buffer keystrokes that arrive before SwiftUI focus is established.
    override func keyDown(with event: NSEvent) {
        if let chars = event.characters, !chars.isEmpty {
            bufferedKeystrokes.append(chars)
        }
        super.keyDown(with: event)
    }

    /// Consume buffered keystrokes and clear the buffer.
    func consumeBufferedKeystrokes() -> String {
        let buffer = bufferedKeystrokes
        bufferedKeystrokes = ""
        return buffer
    }

    // MARK: - Show / Hide / Toggle

    func showCentered() {
        // Capture the frontmost app before we appear
        previousApp = NSWorkspace.shared.frontmostApplication

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
        case ClipboardRecord.kindImage:
            if let data = record.imageData {
                pasteboard.setData(data, forType: .tiff)
            }
        default:
            break
        }

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
    }

    func pasteItems(_ records: [ClipboardRecord]) {
        guard !records.isEmpty else { return }

        // Single item — use existing fast path
        if records.count == 1 {
            pasteItem(records[0])
            return
        }

        // Calculate how many pasteboard writes we'll make for suppression
        let imageCount = records.filter { $0.kind == ClipboardRecord.kindImage }.count
        let textItems = records.filter { $0.kind == ClipboardRecord.kindText }
        let suppressCount = (textItems.isEmpty ? 0 : 1) + imageCount

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
        let imageItems = records.filter { $0.kind == ClipboardRecord.kindImage }
        for img in imageItems {
            if let data = img.imageData {
                operations.append(.image(data))
            }
        }

        // Execute sequentially with delay
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
            pb.setData(data, forType: .tiff)
        }

        firePaste()

        // Schedule next operation after delay.
        // Image pastes need a longer delay — apps like Claude Code CLI
        // require time to process each image before accepting the next paste.
        if index + 1 < ops.count {
            let nextIsImage: Bool
            if case .image = ops[index + 1] { nextIsImage = true } else { nextIsImage = false }
            let delay: TimeInterval = nextIsImage ? 0.5 : 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.executePasteSequence(ops, index: index + 1)
            }
        }
    }

    private func removeActivationObserver() {
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activationObserver = nil
        }
    }

    private func firePaste() {
        let vKeyCode: CGKeyCode = CGKeyCode(kVK_ANSI_V)
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                           state: .eventSuppressionStateSuppressionInterval)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
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
