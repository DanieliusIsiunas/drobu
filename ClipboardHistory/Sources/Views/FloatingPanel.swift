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

    init<Content: View>(contentRect: NSRect = NSRect(x: 0, y: 0, width: 620, height: 460),
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

        animationBehavior = .utilityWindow
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        contentView = NSHostingView(rootView:
            content()
                .ignoresSafeArea()
                .environment(\.floatingPanel, self)
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

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

        // Close panel immediately
        close()

        // Fire paste after target app regains focus
        if checkAccessibility() {
            observeActivationThenPaste()
        }
    }

    private func observeActivationThenPaste() {
        // Observe frontmost app activation, then fire Cmd+V
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.removeActivationObserver()
                self?.firePaste()
            }
        }

        // Fallback: if no activation within 200ms, fire paste anyway
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                guard self?.activationObserver != nil else { return }
                self?.removeActivationObserver()
                self?.firePaste()
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

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }

    private nonisolated func checkAccessibility() -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt"
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

// MARK: - Environment Key

private struct FloatingPanelKey: EnvironmentKey {
    static let defaultValue: FloatingPanel? = nil
}

extension EnvironmentValues {
    var floatingPanel: FloatingPanel? {
        get { self[FloatingPanelKey.self] }
        set { self[FloatingPanelKey.self] = newValue }
    }
}
