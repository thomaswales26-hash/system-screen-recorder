import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

private enum RecorderError: Error, LocalizedError {
    case noDisplay
    case outputExists(URL)
    case writer(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display is available for recording."
        case .outputExists(let url):
            return "The output file already exists: \(url.path)"
        case .writer(let message):
            return message
        }
    }
}

private final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let outputQueue = DispatchQueue(label: "system-screen-recorder.capture")

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let errorLock = NSLock()
    private var firstVideoSample: CMSampleBuffer?
    private var firstAudioSample: CMSampleBuffer?
    private var hasStartedWriting = false
    private var sessionStartTime = CMTime.invalid
    private var storedCaptureError: String?

    init(outputURL: URL, display: SCDisplay) throws {
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw RecorderError.outputExists(outputURL)
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: display.width,
                AVVideoHeightKey: display.height
            ]
        )
        audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]
        )
        videoInput.expectsMediaDataInRealTime = true
        audioInput.expectsMediaDataInRealTime = true

        super.init()

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw RecorderError.writer("The MP4 writer cannot accept video and audio inputs.")
        }
        writer.add(videoInput)
        writer.add(audioInput)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }

        if type == .screen {
            guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
            guard hasStartedWriting else {
                firstVideoSample = sampleBuffer
                startIfReady()
                return
            }
            append(sampleBuffer, to: videoInput)
        } else if type == .audio {
            guard hasStartedWriting else {
                firstAudioSample = sampleBuffer
                startIfReady()
                return
            }
            if CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), sessionStartTime) >= 0 {
                append(sampleBuffer, to: audioInput)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        setCaptureError(error.localizedDescription)
    }

    func finish() async throws {
        outputQueue.sync {
            if hasStartedWriting {
                videoInput.markAsFinished()
                audioInput.markAsFinished()
            }
        }
        guard hasStartedWriting else {
            throw RecorderError.writer("No screen and audio samples were received.")
        }

        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        if let captureError = getCaptureError() {
            throw RecorderError.writer(captureError)
        }
        guard writer.status == .completed else {
            throw RecorderError.writer(writer.error?.localizedDescription ?? "The recording could not be saved.")
        }
    }

    private func startIfReady() {
        guard !hasStartedWriting, let videoSample = firstVideoSample else { return }

        guard writer.startWriting() else {
            setCaptureError(writer.error?.localizedDescription ?? "The MP4 writer could not start.")
            return
        }

        let videoTime = CMSampleBufferGetPresentationTimeStamp(videoSample)
        writer.startSession(atSourceTime: videoTime)
        sessionStartTime = videoTime
        hasStartedWriting = true
        append(videoSample, to: videoInput)
        if let audioSample = firstAudioSample,
           CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(audioSample), sessionStartTime) >= 0 {
            append(audioSample, to: audioInput)
        }
        firstVideoSample = nil
        firstAudioSample = nil
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput) {
        if !input.append(sampleBuffer) {
            setCaptureError(writer.error?.localizedDescription ?? "A captured sample could not be written.")
        }
    }

    private func setCaptureError(_ message: String) {
        errorLock.lock()
        storedCaptureError = message
        errorLock.unlock()
    }

    private func getCaptureError() -> String? {
        errorLock.lock()
        defer { errorLock.unlock() }
        return storedCaptureError
    }
}

@MainActor
private final class RecorderController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var outputURL: URL?
    @Published var errorMessage: String?

    private var stream: SCStream?
    private var recorder: Recorder?
    private var recordingStartDate: Date?
    private var timer: Timer?

    func startRecording() async {
        guard !isRecording, !isStarting else { return }
        errorMessage = nil

        guard let outputURL = chooseOutputURL() else { return }
        isStarting = true
        defer { isStarting = false }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else {
                throw RecorderError.noDisplay
            }

            let recorder = try Recorder(outputURL: outputURL, display: display)
            let configuration = SCStreamConfiguration()
            configuration.width = display.width
            configuration.height = display.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 5
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.capturesAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            if #available(macOS 15.0, *) {
                configuration.captureMicrophone = false
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: configuration, delegate: recorder)
            try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.outputQueue)
            try stream.addStreamOutput(recorder, type: .audio, sampleHandlerQueue: recorder.outputQueue)
            try await stream.startCapture()

            self.recorder = recorder
            self.stream = stream
            self.outputURL = outputURL
            self.recordingStartDate = Date()
            elapsedSeconds = 0
            isRecording = true
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.recordingStartDate else { return }
                    self.elapsedSeconds = Int(Date().timeIntervalSince(start))
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording() async {
        guard isRecording, !isStopping else { return }
        isStopping = true
        timer?.invalidate()
        timer = nil

        var finalizationError: Error?
        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                finalizationError = error
            }
        }
        if let recorder {
            do {
                try await recorder.finish()
            } catch {
                if finalizationError == nil {
                    finalizationError = error
                }
            }
        }

        isRecording = false
        isStopping = false
        stream = nil
        recorder = nil
        recordingStartDate = nil

        if let finalizationError {
            errorMessage = finalizationError.localizedDescription
        }
    }

    private func chooseOutputURL() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Screen Recording"
        panel.nameFieldStringValue = "ScreenRecording-\(Self.timestamp()).mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
}

private struct RecorderView: View {
    @StateObject private var controller = RecorderController()

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "record.circle")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(controller.isRecording ? .red : .accentColor)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("System Screen Recorder")
                    .font(.title2.weight(.semibold))
                Text("Captures your display and system audio only")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(controller.isRecording ? .red : .secondary.opacity(0.5))
                    .frame(width: 9, height: 9)
                Text(statusText)
                    .font(.callout.weight(.medium))
            }

            Text(formattedDuration)
                .font(.system(size: 34, weight: .light, design: .monospaced))
                .monospacedDigit()
                .accessibilityLabel("Recording duration \(formattedDuration)")

            Button(action: recordingButtonTapped) {
                Label(buttonTitle, systemImage: buttonSymbol)
                    .frame(minWidth: 150)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(controller.isRecording ? .red : .accentColor)
            .disabled(controller.isStarting || controller.isStopping)

            if let outputURL = controller.outputURL {
                Text(outputURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
            } else {
                Text("Choose where to save when you start recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = controller.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        }
        .padding(32)
        .frame(minWidth: 440, minHeight: 420)
    }

    private var statusText: String {
        if controller.isStarting { return "Starting…" }
        if controller.isStopping { return "Saving recording…" }
        return controller.isRecording ? "Recording" : "Ready"
    }

    private var buttonTitle: String {
        if controller.isStarting { return "Starting…" }
        if controller.isStopping { return "Saving…" }
        return controller.isRecording ? "Stop Recording" : "Start Recording"
    }

    private var buttonSymbol: String {
        controller.isRecording ? "stop.fill" : "record.circle"
    }

    private var formattedDuration: String {
        let hours = controller.elapsedSeconds / 3_600
        let minutes = (controller.elapsedSeconds % 3_600) / 60
        let seconds = controller.elapsedSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private func recordingButtonTapped() {
        Task {
            if controller.isRecording {
                await controller.stopRecording()
            } else {
                await controller.startRecording()
            }
        }
    }
}

@main
private struct SystemScreenRecorderApp: App {
    var body: some Scene {
        WindowGroup {
            RecorderView()
        }
        .windowResizability(.contentSize)
    }
}
