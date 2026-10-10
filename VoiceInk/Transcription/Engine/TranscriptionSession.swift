import Foundation
import os

/// Encapsulates a single recording-to-transcription lifecycle (streaming or file-based).
@MainActor
protocol TranscriptionSession: AnyObject {
    /// Prepares the session. Returns an audio chunk callback for streaming, or nil for file-based.
    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)?

    /// Called after recording stops. Returns the final transcribed text.
    func transcribe(audioURL: URL) async throws -> String

    /// Cancel the session and clean up resources.
    func cancel()
}

// MARK: - File-Based Session

/// File-based session: records to file, uploads after stop.
@MainActor
final class FileTranscriptionSession: TranscriptionSession {
    private let service: TranscriptionService
    private var model: (any TranscriptionModel)?
    private var context: TranscriptionRequestContext = .currentDefaults

    init(service: TranscriptionService) {
        self.service = service
    }

    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)? {
        self.model = configuration.model
        self.context = configuration.requestContext.scoped(to: configuration.model)
        return nil
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard let model = model else {
            throw VoiceInkEngineError.transcriptionFailed
        }
        return try await service.transcribe(audioURL: audioURL, model: model, context: context)
    }

    func cancel() {
        // No-op for file-based transcription
    }
}

// MARK: - Streaming Session

/// Streaming session with automatic fallback to file-based upload on failure.
@MainActor
final class StreamingTranscriptionSession: TranscriptionSession {
    private let streamingService: StreamingTranscriptionService
    private let fallbackService: TranscriptionService
    private var model: (any TranscriptionModel)?
    private var context: TranscriptionRequestContext = .currentDefaults
    private var streamingFailed = false
    private var startupTask: Task<Void, Never>?
    private var startupTaskID: UUID?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "StreamingTranscriptionSession")

    init(streamingService: StreamingTranscriptionService, fallbackService: TranscriptionService) {
        self.streamingService = streamingService
        self.fallbackService = fallbackService
    }

    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)? {
        let model = configuration.model
        let context = configuration.requestContext.scoped(to: model)

        self.model = model
        self.context = context
        logger.notice("Streaming session prepare model=\(model.displayName, privacy: .public)")

        // Return callback immediately; WebSocket connects in background
        let service = streamingService
        let callback: (Data) -> Void = { [weak service] data in
            service?.sendAudioChunk(data)
        }

        startupTask?.cancel()
        let taskID = UUID()
        startupTaskID = taskID
        startupTask = Task { [weak self] in
            guard let self = self else { return }
            defer {
                if self.startupTaskID == taskID {
                    self.startupTask = nil
                    self.startupTaskID = nil
                }
            }
            guard !Task.isCancelled else { return }

            do {
                let start = Date()
                try await self.streamingService.startStreaming(model: model, context: context)
                guard !Task.isCancelled else {
                    self.streamingService.cancel()
                    return
                }
                self.logger.notice("Streaming session connected model=\(model.displayName, privacy: .public) elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s")
            } catch is CancellationError {
                self.streamingService.cancel()
            } catch {
                guard !Task.isCancelled else { return }
                let desc = error.localizedDescription
                self.logger.error("❌ Failed to start streaming, will fall back to batch: \(desc, privacy: .public)")
                self.streamingFailed = true
            }
        }

        return callback
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard let model = model else {
            throw VoiceInkEngineError.transcriptionFailed
        }

        if !streamingFailed {
            do {
                let start = Date()
                logger.notice("Streaming stop/transcribe started model=\(model.displayName, privacy: .public)")
                let text = try await streamingService.stopAndGetFinalText()
                logger.notice("Streaming transcript received elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s chars=\(text.count, privacy: .public)")
                return await recheckWithFullRecordingIfNeeded(streamingText: text, audioURL: audioURL, model: model)
            } catch {
                logger.error("❌ Streaming failed, falling back to batch: \(error, privacy: .public)")
                startupTask?.cancel()
                startupTask = nil
                startupTaskID = nil
                streamingService.cancel()
            }
        } else {
            startupTask?.cancel()
            startupTask = nil
            startupTaskID = nil
            streamingService.cancel()
        }

        let fallbackStart = Date()
        logger.notice("Using batch fallback for \(model.displayName, privacy: .public) file=\(audioURL.lastPathComponent, privacy: .public)")
        let text = try await fallbackService.transcribe(audioURL: audioURL, model: model, context: context)
        logger.notice("Batch fallback completed elapsed=\(Date().timeIntervalSince(fallbackStart), format: .fixed(precision: 3), privacy: .public)s chars=\(text.count, privacy: .public)")
        return text
    }

    /// The live (streaming) pass can come back blank or clipped: speech that landed before the
    /// streaming model was ready, a last phrase lost at stop, or a session that never produced
    /// a partial. When that happens the whole recording is still on disk, so run the full
    /// (batch) model over it and keep whichever result has more words. Nothing here can make a
    /// good transcript worse: the batch text is only used when it is longer.
    private func recheckWithFullRecordingIfNeeded(
        streamingText: String,
        audioURL: URL,
        model: any TranscriptionModel
    ) async -> String {
        let trimmed = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = await AudioFileMetadata.duration(for: audioURL)
        let streamingWords = trimmed.isEmpty ? 0 : WordCounter.count(in: trimmed)

        // Blank after something real-length, or far fewer words than the time spoken
        // (normal talking is ~2.5 words/s; under 0.35 words/s over 6 s+ means words went missing).
        let blank = streamingWords == 0 && duration >= 0.8
        let tooShort = duration >= 6 && duration <= 900 && Double(streamingWords) < duration * 0.35
        guard blank || tooShort else { return streamingText }

        let start = Date()
        do {
            let batchText = try await fallbackService.transcribe(audioURL: audioURL, model: model, context: context)
            let batchWords = WordCounter.count(in: batchText)
            ninoDbg("NINODBG recheck: streaming=%ld words, full-recording=%ld words, %.1fs audio, took %.2fs",
                    streamingWords, batchWords, duration, Date().timeIntervalSince(start))
            return batchWords > streamingWords ? batchText : streamingText
        } catch {
            ninoDbg("NINODBG recheck failed: %@", error.localizedDescription)
            return streamingText
        }
    }

    func cancel() {
        startupTask?.cancel()
        startupTask = nil
        startupTaskID = nil
        streamingService.cancel()
    }
}
