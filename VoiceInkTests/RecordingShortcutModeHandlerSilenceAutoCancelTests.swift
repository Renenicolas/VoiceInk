import Foundation
import Testing
@testable import VoiceInk

/// Covers the silence auto-cancel watchdog in `RecordingShortcutModeHandler`: a quick tap on a
/// toggle/hybrid shortcut leaves recording running in the background (`isHandsFreeRecording`).
/// Without a watchdog that recording sits open until the shortcut is pressed again, capturing
/// whatever ambient audio happens in between instead of canceling when nothing was said.
@MainActor
struct RecordingShortcutModeHandlerSilenceAutoCancelTests {
    private final class Spy {
        var recordingState: RecordingState = .idle
        var isStreaming = true
        var hasSpeech = false
        var micLevel: Double = 0
        var startsAs: RecordingState = .recording
        var cancelCallCount = 0
        var toggleCallCount = 0
    }

    private func makeHandler(spy: Spy, delay: TimeInterval = 0.05) -> RecordingShortcutModeHandler {
        RecordingShortcutModeHandler(
            canHandleShortcutAction: { true },
            isRecorderVisible: { spy.recordingState != .idle },
            recordingState: { spy.recordingState },
            toggleRecorderPanel: { _ in
                spy.toggleCallCount += 1
                spy.recordingState = spy.recordingState == .idle ? spy.startsAs : .idle
            },
            cancelRecording: {
                spy.cancelCallCount += 1
                spy.recordingState = .idle
            },
            isStreamingSession: { spy.isStreaming },
            hasCapturedSpeech: { spy.hasSpeech },
            micLevel: { spy.micLevel },
            silenceAutoCancelDelay: delay
        )
    }

    @Test func quickTapWithNoSpeechAutoCancels() async {
        let spy = Spy()
        let handler = makeHandler(spy: spy)

        await handler.handleKeyDown(action: .secondaryRecording, eventTime: 0, mode: .toggle)
        await handler.handleKeyUp(action: .secondaryRecording, eventTime: 0.05, mode: .toggle)

        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(spy.cancelCallCount == 1)
    }

    @Test func quickTapWithSpeechDoesNotAutoCancel() async {
        let spy = Spy()
        let handler = makeHandler(spy: spy)

        await handler.handleKeyDown(action: .secondaryRecording, eventTime: 0, mode: .toggle)
        await handler.handleKeyUp(action: .secondaryRecording, eventTime: 0.05, mode: .toggle)
        spy.hasSpeech = true

        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(spy.cancelCallCount == 0)
    }

    @Test func batchModeSessionNeverAutoCancels() async {
        let spy = Spy()
        spy.isStreaming = false
        let handler = makeHandler(spy: spy)

        await handler.handleKeyDown(action: .secondaryRecording, eventTime: 0, mode: .toggle)
        await handler.handleKeyUp(action: .secondaryRecording, eventTime: 0.05, mode: .toggle)

        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(spy.cancelCallCount == 0)
    }

    @Test func secondPressAfterSpeechStopsInsteadOfCanceling() async {
        let spy = Spy()
        let handler = makeHandler(spy: spy, delay: 2.0)
        spy.hasSpeech = true

        await handler.handleKeyDown(action: .secondaryRecording, eventTime: 0, mode: .toggle)
        await handler.handleKeyUp(action: .secondaryRecording, eventTime: 0.05, mode: .toggle)

        // Clear the shortcut's real-time debounce cooldown before the second press.
        try? await Task.sleep(nanoseconds: 600_000_000)

        await handler.handleKeyDown(action: .secondaryRecording, eventTime: 0.66, mode: .toggle)

        #expect(spy.toggleCallCount == 2)
        #expect(spy.cancelCallCount == 0)
    }

    /// Oct 2026 bug: the window started at key-up, so a mic that took ~4 s to come up got
    /// killed ~2 s after it went live. Time spent in `.starting` must not count.
    @Test func slowMicStartDoesNotCountTowardTheWindow() async {
        let spy = Spy()
        spy.startsAs = .starting
        let handler = makeHandler(spy: spy, delay: 0.2)

        await handler.handleKeyDown(action: .secondaryRecording, eventTime: 0, mode: .toggle)
        await handler.handleKeyUp(action: .secondaryRecording, eventTime: 0.05, mode: .toggle)

        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(spy.cancelCallCount == 0)

        spy.recordingState = .recording
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(spy.cancelCallCount == 1)
    }

    /// Oct 2026 bug: real sentences were canceled because the streaming partial lagged.
    /// A sustained voice-level signal from the mic must keep the recording alive.
    @Test func voiceOnTheMicPreventsAutoCancel() async {
        let spy = Spy()
        spy.micLevel = 0.6
        let handler = makeHandler(spy: spy, delay: 1.0)

        await handler.handleKeyDown(action: .secondaryRecording, eventTime: 0, mode: .toggle)
        await handler.handleKeyUp(action: .secondaryRecording, eventTime: 0.05, mode: .toggle)

        try? await Task.sleep(nanoseconds: 1_400_000_000)
        #expect(spy.cancelCallCount == 0)
    }

    /// Room noise below the voice threshold still counts as silence.
    @Test func quietRoomStillAutoCancels() async {
        let spy = Spy()
        spy.micLevel = 0.3
        let handler = makeHandler(spy: spy, delay: 0.8)

        await handler.handleKeyDown(action: .secondaryRecording, eventTime: 0, mode: .toggle)
        await handler.handleKeyUp(action: .secondaryRecording, eventTime: 0.05, mode: .toggle)

        try? await Task.sleep(nanoseconds: 1_300_000_000)
        #expect(spy.cancelCallCount == 1)
    }

    /// Rene, Oct 2026: tap Option, say nothing, tap Option again -> it just goes away.
    @Test func secondPressWithNoSpeechCancelsQuietly() async {
        let spy = Spy()
        let handler = makeHandler(spy: spy, delay: 2.0)

        await handler.handleKeyDown(action: .secondaryRecording, eventTime: 0, mode: .hybrid)
        await handler.handleKeyUp(action: .secondaryRecording, eventTime: 0.05, mode: .hybrid)
        try? await Task.sleep(nanoseconds: 600_000_000)
        await handler.handleKeyDown(action: .secondaryRecording, eventTime: 0.66, mode: .hybrid)

        #expect(spy.cancelCallCount == 1)
        #expect(spy.toggleCallCount == 1)
        #expect(spy.recordingState == .idle)
    }

    /// A second press after a real voice on the mic (even before any words stream) must stop
    /// and transcribe, never cancel.
    @Test func secondPressAfterVoiceOnMicStops() async {
        let spy = Spy()
        spy.micLevel = 0.6
        let handler = makeHandler(spy: spy, delay: 2.0)

        await handler.handleKeyDown(action: .secondaryRecording, eventTime: 0, mode: .hybrid)
        await handler.handleKeyUp(action: .secondaryRecording, eventTime: 0.05, mode: .hybrid)
        try? await Task.sleep(nanoseconds: 900_000_000)
        await handler.handleKeyDown(action: .secondaryRecording, eventTime: 0.96, mode: .hybrid)

        #expect(spy.cancelCallCount == 0)
        #expect(spy.toggleCallCount == 2)
    }

    @Test func escWithNoSpeechCancelsOnFirstPress() async {
        let spy = Spy()
        let handler = makeHandler(spy: spy, delay: 2.0)

        await handler.handleKeyDown(action: .secondaryRecording, eventTime: 0, mode: .hybrid)
        await handler.handleKeyUp(action: .secondaryRecording, eventTime: 0.05, mode: .hybrid)
        let canceled = await handler.cancelIfSilentHandsFree()

        #expect(canceled)
        #expect(spy.cancelCallCount == 1)
    }

    @Test func escAfterSpeechIsLeftToDoubleEsc() async {
        let spy = Spy()
        let handler = makeHandler(spy: spy, delay: 2.0)

        await handler.handleKeyDown(action: .secondaryRecording, eventTime: 0, mode: .hybrid)
        await handler.handleKeyUp(action: .secondaryRecording, eventTime: 0.05, mode: .hybrid)
        spy.hasSpeech = true
        let canceled = await handler.cancelIfSilentHandsFree()

        #expect(!canceled)
        #expect(spy.cancelCallCount == 0)
    }

    /// Rene, Oct 11 2026: no auto-cancel. A silent recording keeps running until he cancels it.
    @Test func defaultNeverAutoCancels() async {
        let spy = Spy()
        let handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: { true },
            isRecorderVisible: { spy.recordingState != .idle },
            recordingState: { spy.recordingState },
            toggleRecorderPanel: { _ in spy.recordingState = spy.recordingState == .idle ? .recording : .idle },
            cancelRecording: { spy.cancelCallCount += 1; spy.recordingState = .idle },
            isStreamingSession: { true },
            hasCapturedSpeech: { false }
        )
        await handler.handleKeyDown(action: .secondaryRecording, eventTime: 0, mode: .hybrid)
        await handler.handleKeyUp(action: .secondaryRecording, eventTime: 0.05, mode: .hybrid)

        try? await Task.sleep(nanoseconds: 9_000_000_000)
        #expect(spy.cancelCallCount == 0)
        #expect(spy.recordingState == .recording)
        // Still knows nothing was said, so Esc cancels on one press.
        #expect(handler.isSilentHandsFreeRecording)
    }
}
