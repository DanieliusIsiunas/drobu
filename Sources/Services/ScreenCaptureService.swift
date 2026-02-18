import AppKit
import CoreImage
import CoreMedia
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
final class ScreenCaptureService {

    enum State: Sendable { case idle, selecting, recording, encoding }

    private(set) var state: State = .idle

    var onCaptureComplete: ((Data) -> Void)?
    var onCaptureError: ((String) -> Void)?
    var onStateChange: ((State) -> Void)?

    private var selectionPanel: RegionSelectionPanel?
    private var indicatorWindow: RecordingIndicatorWindow?
    private var stream: SCStream?
    private var frameOutput: FrameCaptureOutput?
    private var autoStopTimer: Timer?
    private var captureScreen: NSScreen?
    private var captureRect: CGRect = .zero // Screen coordinates (AppKit)

    private static let maxDuration: TimeInterval = 15
    private static let fps: Int = 10
    private static let maxGIFBytes = 20_000_000

    // MARK: - Public API

    func startRegionSelection() {
        guard state == .idle else { return }

        // Trigger system permission dialog on first attempt (no-op if already granted).
        // Don't gate on CGPreflightScreenCaptureAccess() — it returns false on macOS 15
        // even when permission is granted. Instead, we handle permission errors when
        // SCStream actually fails to start in beginRecording().
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }

        setState(.selecting)

        // Show overlay on the screen with the mouse cursor
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main!

        let panel = RegionSelectionPanel(screen: screen)
        panel.onRegionSelected = { [weak self] rect, screen in
            self?.selectionPanel = nil
            self?.beginRecording(rect: rect, screen: screen)
        }
        panel.onCancelled = { [weak self] in
            self?.selectionPanel = nil
            self?.setState(.idle)
        }
        selectionPanel = panel
        panel.showAndActivate()
    }

    func cancelSelection() {
        selectionPanel?.close()
        selectionPanel = nil
        setState(.idle)
    }

    func stopRecording() {
        guard state == .recording else { return }
        autoStopTimer?.invalidate()
        autoStopTimer = nil
        indicatorWindow?.dismiss()
        indicatorWindow = nil

        Task {
            try? await stream?.stopCapture()
            stream = nil
            await encodeCapture()
        }
    }

    func cancelRecording() {
        guard state == .recording else { return }
        autoStopTimer?.invalidate()
        autoStopTimer = nil
        indicatorWindow?.dismiss()
        indicatorWindow = nil

        Task {
            try? await stream?.stopCapture()
            stream = nil
            frameOutput = nil
            setState(.idle)
        }
    }

    // MARK: - Recording

    private func beginRecording(rect: CGRect, screen: NSScreen) {
        captureRect = rect
        captureScreen = screen

        Task {
            do {
                try await startStream(rect: rect, screen: screen)
                setState(.recording)

                // Show recording indicator
                let indicator = RecordingIndicatorWindow()
                indicator.show(relativeTo: rect, on: screen)
                indicatorWindow = indicator

                // Auto-stop timer
                autoStopTimer = Timer.scheduledTimer(withTimeInterval: Self.maxDuration, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.stopRecording()
                    }
                }
            } catch {
                NSLog("Screen capture failed to start: \(error)")
                setState(.idle)
                // ScreenCaptureKit errors when permission is denied
                let desc = error.localizedDescription
                if desc.contains("permission") || desc.contains("denied") || desc.contains("not authorized") {
                    showPermissionAlert()
                } else {
                    onCaptureError?("Failed to start recording: \(desc)")
                }
            }
        }
    }

    private func startStream(rect: CGRect, screen: NSScreen) async throws {
        let availableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        // Find the display matching this screen
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let targetDisplay = availableContent.displays.first(where: {
            displayID != nil ? $0.displayID == displayID! : true
        }) else {
            throw CaptureError.displayNotFound
        }

        let filter = SCContentFilter(
            display: targetDisplay,
            excludingApplications: [],
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()

        // Convert AppKit screen coordinates to display coordinates for sourceRect
        // AppKit: origin at bottom-left. SCStream sourceRect: origin at top-left.
        let displayHeight = CGFloat(targetDisplay.height)
        let screenFrame = screen.frame
        let localRect = CGRect(
            x: rect.origin.x - screenFrame.origin.x,
            y: rect.origin.y - screenFrame.origin.y,
            width: rect.width,
            height: rect.height
        )
        let sourceRect = CGRect(
            x: localRect.origin.x,
            y: displayHeight - localRect.origin.y - localRect.height,
            width: localRect.width,
            height: localRect.height
        )

        config.sourceRect = sourceRect
        config.width = Int(rect.width)
        config.height = Int(rect.height)
        config.destinationRect = CGRect(x: 0, y: 0, width: Int(rect.width), height: Int(rect.height))
        config.scalesToFit = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.fps))
        config.queueDepth = 5
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.captureResolution = .nominal
        config.capturesAudio = false

        let output = FrameCaptureOutput()
        frameOutput = output

        let captureStream = SCStream(filter: filter, configuration: config, delegate: nil)
        stream = captureStream

        try captureStream.addStreamOutput(
            output,
            type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "com.clipboard.screenCapture", qos: .userInteractive)
        )

        try await captureStream.startCapture()
    }

    // MARK: - Encoding

    private func encodeCapture() async {
        setState(.encoding)

        guard let output = frameOutput else {
            NSLog("[ScreenCapture] encodeCapture: no frameOutput")
            setState(.idle)
            return
        }

        let compressedFrames = output.compressedFrames
        frameOutput = nil
        NSLog("[ScreenCapture] encodeCapture: \(compressedFrames.count) frames captured")

        guard !compressedFrames.isEmpty else {
            setState(.idle)
            onCaptureError?("No frames captured.")
            return
        }

        // Encode on a background thread to avoid blocking UI
        let delay = 1.0 / Double(Self.fps)
        let maxBytes = Self.maxGIFBytes

        let gifData: Data? = await Task.detached {
            // Full quality attempt
            if let data = GIFFrameEngine.encodeFromCompressedFrames(compressedFrames, delay: delay) {
                NSLog("[ScreenCapture] encoded GIF: \(data.count) bytes (\(data.count / 1024)KB)")
                if data.count <= maxBytes {
                    return data
                }
                NSLog("[ScreenCapture] GIF exceeds \(maxBytes) bytes, trying half framerate")
            } else {
                NSLog("[ScreenCapture] encodeFromCompressedFrames returned nil")
            }

            // Half frame rate attempt
            let everyOther = compressedFrames.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
            if let data = GIFFrameEngine.encodeFromCompressedFrames(everyOther, delay: delay * 2),
               data.count <= maxBytes {
                NSLog("[ScreenCapture] half-rate GIF: \(data.count) bytes")
                return data
            }

            return nil
        }.value

        if let gifData {
            NSLog("[ScreenCapture] success: \(gifData.count) bytes, calling onCaptureComplete")
            setState(.idle)
            onCaptureComplete?(gifData)
        } else {
            NSLog("[ScreenCapture] encoding failed or too large")
            setState(.idle)
            onCaptureError?("Recording too large — try a smaller region or shorter duration.")
        }
    }

    // MARK: - State

    private func setState(_ newState: State) {
        state = newState
        onStateChange?(newState)
    }

    // MARK: - Permission

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = """
            ClipboardHistory needs Screen Recording permission to capture GIFs. \
            Click 'Open System Settings' and toggle on ClipboardHistory.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    enum CaptureError: Error {
        case displayNotFound
    }
}

// MARK: - Frame Capture Output

/// Receives frames from SCStream, compresses to JPEG for memory efficiency.
/// Thread-safe: callbacks arrive on a background DispatchQueue.
final class FrameCaptureOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var _compressedFrames: [Data] = []
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    var compressedFrames: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return _compressedFrames
    }

    private var frameCount = 0

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else { return }
        guard sampleBuffer.isValid else { return }

        // Check frame status
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRawValue = attachments[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue),
              status == .complete
        else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        frameCount += 1
        if frameCount <= 3 || frameCount % 10 == 0 {
            NSLog("[ScreenCapture] frame \(frameCount): \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
        }

        // Convert to CGImage via CIImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        // Compress to JPEG immediately to save memory (~200KB vs ~8MB per frame)
        // Uses CoreGraphics directly — thread-safe unlike NSImage/NSBitmapImageRep
        let jpegData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            jpegData as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }

        lock.lock()
        _compressedFrames.append(jpegData as Data)
        lock.unlock()
    }
}
