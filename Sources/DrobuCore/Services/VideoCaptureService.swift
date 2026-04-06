import AppKit
import AVFoundation
import CoreMedia
import CryptoKit
import ScreenCaptureKit

@MainActor
final class VideoCaptureService {

    enum State: Sendable { case idle, selecting, recording, finalizing }

    private(set) var state: State = .idle

    var onCaptureComplete: ((URL, Data, TimeInterval) -> Void)?  // (videoFileURL, thumbnailJPEG, duration)
    var onCaptureError: ((String) -> Void)?
    var onStateChange: ((State) -> Void)?

    private var selectionPanel: RegionSelectionPanel?
    private var indicatorWindow: RecordingIndicatorWindow?
    private var stream: SCStream?
    private var frameWriter: VideoFrameWriter?
    private var autoStopTimer: Timer?

    private var recordingStartTime: Date?
    private var tempFileURL: URL?

    private static let maxDuration: TimeInterval = 300
    private static let fps: Int = 15

    // MARK: - Public API

    func startRegionSelection() {
        guard state == .idle else { return }

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }

        setState(.selecting)

        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else {
            Log.error("VideoCaptureService: no screen available")
            setState(.idle)
            return
        }

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
        setState(.finalizing) // Must be first — prevents re-entrancy from escape monitor

        autoStopTimer?.invalidate()
        autoStopTimer = nil

        indicatorWindow?.dismiss()
        indicatorWindow = nil

        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0

        Task {
            // Stop stream first — ensures no more callbacks to the writer
            try? await stream?.stopCapture()
            stream = nil

            guard let writer = frameWriter else {
                setState(.idle)
                return
            }
            frameWriter = nil

            // Finalize the .mp4 file
            await writer.finish()

            guard writer.assetWriter.status == .completed else {
                let errorDesc = writer.assetWriter.error?.localizedDescription ?? "Unknown error"
                Log.error("VideoCaptureService: writer failed: \(errorDesc)")
                cleanupTempFile()
                setState(.idle)
                onCaptureError?("Video encoding failed: \(errorDesc)")
                return
            }

            await finalizeRecording(duration: duration)
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

            if let writer = frameWriter {
                frameWriter = nil
                await writer.cancel()
            }

            cleanupTempFile()
            setState(.idle)
        }
    }

    // MARK: - Recording

    private func beginRecording(rect: CGRect, screen: NSScreen) {
        // Temp file in NSTemporaryDirectory — not in videos dir (orphan cleanup safety)
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).mp4")
        tempFileURL = tempURL

        // Ensure videos directory exists with restricted permissions
        let videosDir = ClipboardRecord.videosDirectory
        do {
            try FileManager.default.createDirectory(
                at: videosDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            Log.error("VideoCaptureService: failed to create videos directory: \(error)")
        }

        // Set up AVAssetWriter
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: tempURL, fileType: .mp4)
        } catch {
            Log.error("VideoCaptureService: AVAssetWriter init failed: \(error)")
            setState(.idle)
            onCaptureError?("Failed to initialize video writer: \(error.localizedDescription)")
            return
        }

        let width = Int(rect.width)
        let height = Int(rect.height)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_000_000,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = true

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )

        writer.add(writerInput)

        guard writer.startWriting() else {
            Log.error("VideoCaptureService: startWriting failed: \(writer.error?.localizedDescription ?? "unknown")")
            setState(.idle)
            onCaptureError?("Failed to start video writer.")
            return
        }

        writer.startSession(atSourceTime: .zero)

        let frameWriterObj = VideoFrameWriter(assetWriter: writer, writerInput: writerInput, adaptor: adaptor)
        frameWriter = frameWriterObj

        // Start SCStream
        Task {
            do {
                try await startStream(rect: rect, screen: screen, frameWriter: frameWriterObj)
                setState(.recording)
                recordingStartTime = Date()

                let indicator = RecordingIndicatorWindow()
                indicator.show(relativeTo: rect, on: screen)
                indicatorWindow = indicator

                autoStopTimer = Timer.scheduledTimer(withTimeInterval: Self.maxDuration, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.stopRecording()
                    }
                }

            } catch {
                Log.error("VideoCaptureService: failed to start stream: \(error)")
                frameWriter = nil
                await frameWriterObj.cancel()
                cleanupTempFile()
                setState(.idle)

                let desc = error.localizedDescription
                if desc.contains("permission") || desc.contains("denied") || desc.contains("not authorized") {
                    showPermissionAlert()
                } else {
                    onCaptureError?("Failed to start recording: \(desc)")
                }
            }
        }
    }

    private func startStream(rect: CGRect, screen: NSScreen, frameWriter: VideoFrameWriter) async throws {
        let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let targetDisplay = availableContent.displays.first(where: {
            if let displayID { return $0.displayID == displayID }
            return true
        }) else {
            throw CaptureError.displayNotFound
        }

        let filter = SCContentFilter(display: targetDisplay, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()

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

        let captureStream = SCStream(filter: filter, configuration: config, delegate: nil)
        stream = captureStream

        try captureStream.addStreamOutput(
            frameWriter,
            type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "com.clipboard.videoCapture", qos: .userInteractive)
        )

        try await captureStream.startCapture()
    }

    // MARK: - Finalize

    private func finalizeRecording(duration: TimeInterval) async {
        guard let tempURL = tempFileURL else {
            setState(.idle)
            return
        }

        // Compute SHA256 off main thread using streaming hash
        let hashResult: String? = await Task.detached { () -> String? in
            guard let fileHandle = try? FileHandle(forReadingFrom: tempURL) else { return nil }
            defer { try? fileHandle.close() }

            var hasher = SHA256()
            while true {
                let chunk = fileHandle.readData(ofLength: 1_048_576) // 1MB chunks
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            let digest = hasher.finalize()
            return digest.map { String(format: "%02x", $0) }.joined()
        }.value

        guard let contentHash = hashResult else {
            Log.error("VideoCaptureService: failed to hash video file")
            cleanupTempFile()
            setState(.idle)
            onCaptureError?("Failed to process video file.")
            return
        }

        // Move temp file to final location
        let finalURL = ClipboardRecord.videoPath(for: contentHash)

        do {
            // Delete existing file if hash collision (practically impossible)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: finalURL)
            // Set restricted permissions
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: finalURL.path)
        } catch {
            Log.error("VideoCaptureService: failed to move video file: \(error)")
            cleanupTempFile()
            setState(.idle)
            onCaptureError?("Failed to save video file.")
            return
        }

        tempFileURL = nil

        // Extract thumbnail at 0.5s
        let thumbnail = await Task.detached {
            Self.extractThumbnail(from: finalURL)
        }.value

        guard let thumbnailData = thumbnail else {
            Log.error("VideoCaptureService: failed to extract thumbnail")
            setState(.idle)
            onCaptureComplete?(finalURL, Data(), duration)
            return
        }

        Log.info("VideoCaptureService: capture complete — \(contentHash.prefix(8)).mp4, \(String(format: "%.1f", duration))s")
        setState(.idle)
        onCaptureComplete?(finalURL, thumbnailData, duration)
    }

    private nonisolated static func extractThumbnail(from url: URL) -> Data? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }


    // MARK: - Helpers

    private func cleanupTempFile() {
        if let url = tempFileURL {
            do { try FileManager.default.removeItem(at: url) }
            catch { Log.debug("VideoCaptureService: cleanup temp file failed: \(error)") }
            tempFileURL = nil
        }
    }

    private func setState(_ newState: State) {
        state = newState
        onStateChange?(newState)
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = """
            Drobu needs Screen Recording permission to capture video. \
            Click 'Open System Settings' and toggle on Drobu.
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

// MARK: - VideoFrameWriter

/// Receives frames from SCStream and writes them to AVAssetWriter in real-time.
/// Thread-safe: SCStream callbacks arrive on a background DispatchQueue.
final class VideoFrameWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let assetWriter: AVAssetWriter
    private let writerInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var firstTimestamp: CMTime?
    private let lock = NSLock()
    private var frameCount = 0

    init(assetWriter: AVAssetWriter, writerInput: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor) {
        self.assetWriter = assetWriter
        self.writerInput = writerInput
        self.adaptor = adaptor
    }

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

        // Don't block SCStream queue if writer can't keep up
        guard writerInput.isReadyForMoreMediaData else { return }

        // Check writer hasn't failed
        guard assetWriter.status == .writing else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        lock.lock()
        let first = firstTimestamp
        if first == nil { firstTimestamp = pts }
        frameCount += 1
        lock.unlock()

        // Normalize timestamp relative to first frame
        let relativeTime = CMTimeSubtract(pts, first ?? pts)

        adaptor.append(pixelBuffer, withPresentationTime: relativeTime)
    }

    func finish() async {
        writerInput.markAsFinished()
        await withCheckedContinuation { continuation in
            assetWriter.finishWriting {
                continuation.resume()
            }
        }
    }

    func cancel() async {
        writerInput.markAsFinished()
        assetWriter.cancelWriting()
    }
}
