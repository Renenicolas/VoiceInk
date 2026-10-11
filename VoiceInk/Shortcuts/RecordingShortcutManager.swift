import Foundation
import AppKit
import Carbon.HIToolbox

@MainActor
class RecordingShortcutManager: ObservableObject {
    @Published var primaryRecordingShortcut: ShortcutSelection {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcut.rawValue, forKey: "primaryRecordingShortcut")
            refreshShortcutMonitoring()
        }
    }
    @Published var secondaryRecordingShortcut: ShortcutSelection {
        didSet {
            if secondaryRecordingShortcut == .none {
                ShortcutStore.setShortcut(nil, for: .secondaryRecording)
            }
            UserDefaults.standard.set(secondaryRecordingShortcut.rawValue, forKey: "secondaryRecordingShortcut")
            refreshShortcutMonitoring()
        }
    }
    @Published var primaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcutMode.rawValue, forKey: "primaryRecordingShortcutMode")
            primaryRecordingShortcutModeSource.primaryMode = primaryRecordingShortcutMode
        }
    }
    @Published var secondaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(secondaryRecordingShortcutMode.rawValue, forKey: "secondaryRecordingShortcutMode")
        }
    }
    @Published var isMiddleClickToggleEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isMiddleClickToggleEnabled, forKey: "isMiddleClickToggleEnabled")
            refreshShortcutMonitoring()
        }
    }
    @Published var middleClickActivationDelay: Int {
        didSet {
            UserDefaults.standard.set(middleClickActivationDelay, forKey: "middleClickActivationDelay")
        }
    }
    
    private var engine: VoiceInkEngine
    private var recorderUIManager: RecorderUIManager
    private var recorderPanelShortcutManager: RecorderPanelShortcutManager
    private let modeShortcutManager: ModeShortcutManager
    private let shortcutMonitor = ShortcutMonitor()
    private var shortcutChangeObserver: NSObjectProtocol?
    private let shortcutModeHandler: RecordingShortcutModeHandler
    private let primaryRecordingShortcutModeSource: RecordingShortcutModeSource

    // MARK: - Helper Properties
    private var canHandleShortcutAction: Bool {
        Self.canHandleShortcutAction(for: engine.recordingState)
    }
    
    // Middle-click event monitoring
    private var middleClickMonitors: [Any?] = []
    private var middleClickTask: Task<Void, Never>?

    enum Mode: String, CaseIterable {
        case toggle = "toggle"
        case pushToTalk = "pushToTalk"
        case hybrid = "hybrid"

        var displayName: String {
            switch self {
            case .toggle: return String(localized: "Toggle")
            case .pushToTalk: return String(localized: "Push to Talk")
            case .hybrid: return String(localized: "Hybrid")
            }
        }
    }

    enum ShortcutSelection: String, CaseIterable {
        case none = "none"
        case custom = "custom"
        
        var displayName: String {
            switch self {
            case .none: return String(localized: "None")
            case .custom: return String(localized: "Custom")
            }
        }
    }

    private static func canHandleShortcutAction(for recordingState: RecordingState) -> Bool {
        recordingState != .transcribing &&
        recordingState != .enhancing &&
        recordingState != .busy
    }

    init(engine: VoiceInkEngine, recorderUIManager: RecorderUIManager) {
        ShortcutMigration.migrateLegacyShortcutsIfNeeded()

        // Default-bind hands-free toggle dictation to Left Option. seedShortcut is a
        // no-op once the user has customized or cleared it, so this only ever applies once.
        ShortcutStore.seedShortcut(
            .modifierOnly(keyCode: UInt16(kVK_Option), modifierFlags: [.option]),
            for: .handsFreeToggle
        )

        self.primaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(
            action: .primaryRecording,
            allowsNone: false
        )
        self.secondaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(
            action: .secondaryRecording,
            allowsNone: true
        )

        let primaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(
            for: .primaryRecording
        )
        self.primaryRecordingShortcutMode = primaryRecordingShortcutMode
        self.secondaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(
            for: .secondaryRecording
        )

        self.isMiddleClickToggleEnabled = UserDefaults.standard.bool(forKey: "isMiddleClickToggleEnabled")
        self.middleClickActivationDelay = UserDefaults.standard.integer(forKey: "middleClickActivationDelay")

        let shortcutModeHandler = RecordingShortcutModeHandler(
            canHandleShortcutAction: {
                Self.canHandleShortcutAction(for: engine.recordingState)
            },
            isRecorderVisible: {
                recorderUIManager.isRecorderPanelVisible
            },
            recordingState: {
                engine.recordingState
            },
            toggleRecorderPanel: { modeId in
                await recorderUIManager.toggleRecorderPanel(modeId: modeId)
            },
            cancelRecording: {
                await recorderUIManager.cancelRecording()
            },
            isStreamingSession: {
                engine.currentSession != nil
            },
            hasCapturedSpeech: {
                !engine.partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            },
            micLevel: {
                engine.recorder.audioMeter.peakPower
            }
        )

        let primaryRecordingShortcutModeSource = RecordingShortcutModeSource(
            primaryMode: primaryRecordingShortcutMode
        )

        self.engine = engine
        self.recorderUIManager = recorderUIManager
        self.recorderPanelShortcutManager = RecorderPanelShortcutManager(
            recorderUIManager: recorderUIManager,
            assistantSession: engine.assistantSession,
            cancelIfSilentHandsFree: {
                await shortcutModeHandler.cancelIfSilentHandsFree()
            }
        )
        self.shortcutModeHandler = shortcutModeHandler
        self.primaryRecordingShortcutModeSource = primaryRecordingShortcutModeSource
        self.modeShortcutManager = ModeShortcutManager(
            modeProvider: {
                primaryRecordingShortcutModeSource.primaryMode
            },
            shouldUsePushToTalk: {
                recorderUIManager.shouldCaptureAssistantDictation
            },
            shortcutModeHandler: shortcutModeHandler
        )

        shortcutChangeObserver = NotificationCenter.default.addObserver(
            forName: ShortcutStore.shortcutDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshShortcutMonitoring()
            }
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.refreshShortcutMonitoring()
        }
    }
    
    private func refreshShortcutMonitoring() {
        removeAllMonitoring()
        
        refreshShortcutMonitor()
        setupMiddleClickMonitoring()
    }
    
    private func setupMiddleClickMonitoring() {
        guard isMiddleClickToggleEnabled else { return }

        // Mouse Down
        let downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self = self, event.buttonNumber == 2 else { return }

            self.middleClickTask?.cancel()
            self.middleClickTask = Task {
                do {
                    let delay = UInt64(self.middleClickActivationDelay) * 1_000_000 // ms to ns
                    try await Task.sleep(nanoseconds: delay)
                    
                    guard self.isMiddleClickToggleEnabled, !Task.isCancelled else { return }
                    
                    Task { @MainActor in
                        guard self.canHandleShortcutAction else { return }
                        await self.recorderUIManager.toggleRecorderPanel()
                    }
                } catch {
                    // Cancelled
                }
            }
        }

        // Mouse Up
        let upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
            guard let self = self, event.buttonNumber == 2 else { return }
            self.middleClickTask?.cancel()
        }

        middleClickMonitors = [downMonitor, upMonitor]
    }
    
    private func refreshShortcutMonitor() {
        let primaryShortcut = primaryRecordingShortcut == .custom ? ShortcutStore.shortcut(for: .primaryRecording) : nil
        let secondaryShortcut = secondaryRecordingShortcut == .custom ? ShortcutStore.shortcut(for: .secondaryRecording) : nil
        let handsFreeToggleShortcut = ShortcutStore.shortcut(for: .handsFreeToggle)
        var shortcuts = ShortcutStore.shortcuts(for: ShortcutAction.globalUtilityActions)
        var interruptibleRecordingActions = Set<ShortcutAction>()

        if let primaryShortcut {
            shortcuts[.primaryRecording] = primaryShortcut
            interruptibleRecordingActions.insert(.primaryRecording)
        }

        if let secondaryShortcut {
            shortcuts[.secondaryRecording] = secondaryShortcut
            interruptibleRecordingActions.insert(.secondaryRecording)
        }

        if let handsFreeToggleShortcut {
            shortcuts[.handsFreeToggle] = handsFreeToggleShortcut
        }

        shortcutMonitor.start(
            shortcuts: shortcuts,
            interruptibleActions: interruptibleRecordingActions,
            onKeyDown: { [weak self] action, eventTime in
                Task { @MainActor in
                    guard let self else { return }

                    // Hands-free toggle is always-toggle by design: it never goes through
                    // shortcutModeHandler (the hybrid/push-to-talk state machine), so it can
                    // never turn into push-to-talk no matter how long the key is held.
                    if action == .handsFreeToggle {
                        await self.handleHandsFreeToggleKeyDown()
                        return
                    }

                    guard let mode = self.recordingMode(for: action) else { return }
                    await self.shortcutModeHandler.handleKeyDown(
                        action: action,
                        eventTime: eventTime,
                        mode: mode
                    )
                }
            },
            onKeyUp: { [weak self] action, eventTime in
                Task { @MainActor in
                    guard let self else { return }

                    // No-op on release: this is the bypass that keeps hands-free toggle from
                    // ever behaving like push-to-talk.
                    if action == .handsFreeToggle { return }

                    if let mode = self.recordingMode(for: action) {
                        await self.shortcutModeHandler.handleKeyUp(
                            action: action,
                            eventTime: eventTime,
                            mode: mode
                        )
                    } else {
                        await self.handleGlobalShortcut(action)
                    }
                }
            },
            onShortcutInterrupted: { [weak self] action, _ in
                Task { @MainActor in
                    guard let self, self.recordingMode(for: action) != nil else { return }
                    await self.shortcutModeHandler.handleInterruption(action: action)
                }
            }
        )
    }

    private func recordingMode(for action: ShortcutAction) -> Mode? {
        switch action {
        case .primaryRecording:
            return primaryRecordingShortcutMode
        case .secondaryRecording:
            return secondaryRecordingShortcutMode
        default:
            return nil
        }
    }

    /// Enhancement starter mode (light cleanup: fillers removed + light grammar, not
    /// reshaped) — see StarterModeCatalog kind .enhance. Hands-free toggle always targets
    /// this mode rather than the user's current/default mode.
    private static let enhancementModeId = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!

    private func handleHandsFreeToggleKeyDown() async {
        guard canHandleShortcutAction else { return }
        await recorderUIManager.toggleRecorderPanel(modeId: Self.enhancementModeId)
    }

    private func handleGlobalShortcut(_ action: ShortcutAction) async {
        switch action {
        case .assistantAsk:
            await recorderUIManager.toggleAssistantAsk()
        case .pasteLastTranscription:
            LastTranscriptionService.pasteLastTranscription(from: engine.modelContext)
        case .pasteLastEnhancement:
            LastTranscriptionService.pasteLastEnhancement(from: engine.modelContext)
        case .retryLastTranscription:
            LastTranscriptionService.retryLastTranscription(
                from: engine.modelContext,
                transcriptionModelManager: engine.transcriptionModelManager,
                serviceRegistry: engine.serviceRegistry,
                enhancementService: engine.enhancementService
            )
        case .openHistoryWindow:
            HistoryWindowController.shared.showHistoryWindow(
                modelContainer: engine.modelContext.container,
                engine: engine
            )
        case .quickAddToDictionary:
            DictionaryQuickAddManager.shared.toggle(modelContainer: engine.modelContext.container)
        default:
            break
        }
    }

    private func removeAllMonitoring() {
        shortcutMonitor.stop()
        
        for monitor in middleClickMonitors {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        middleClickMonitors = []
        middleClickTask?.cancel()
        
        shortcutModeHandler.reset()
    }
    
    var isShortcutConfigured: Bool {
        let isPrimaryShortcutConfigured = primaryRecordingShortcut != .none && ShortcutStore.shortcut(for: .primaryRecording) != nil
        let isSecondaryShortcutConfigured = secondaryRecordingShortcut == .none || ShortcutStore.shortcut(for: .secondaryRecording) != nil
        return isPrimaryShortcutConfigured && isSecondaryShortcutConfigured
    }
    
    func updateShortcutStatus() {
        // Called when a shortcut changes
        refreshShortcutMonitoring()
    }
    
    deinit {
        if let shortcutChangeObserver {
            NotificationCenter.default.removeObserver(shortcutChangeObserver)
        }

        MainActor.assumeIsolated {
            removeAllMonitoring()
        }
    }
}

@MainActor
private final class RecordingShortcutModeSource {
    var primaryMode: RecordingShortcutManager.Mode

    init(primaryMode: RecordingShortcutManager.Mode) {
        self.primaryMode = primaryMode
    }
}

@MainActor
final class RecordingShortcutModeHandler {
    private let canHandleShortcutAction: @MainActor () -> Bool
    private let isRecorderVisible: @MainActor () -> Bool
    private let recordingState: @MainActor () -> RecordingState
    private let toggleRecorderPanel: @MainActor (UUID?) async -> Void
    private let cancelRecording: @MainActor () async -> Void
    private let isStreamingSession: @MainActor () -> Bool
    private let hasCapturedSpeech: @MainActor () -> Bool
    /// Normalized (0...1, where 0 = -60 dB and 1 = 0 dB) smoothed mic peak level.
    private let micLevel: @MainActor () -> Double

    private var shortcutPressStartTime: TimeInterval?
    private var isHandsFreeRecording = false
    private var isShortcutPressed = false
    private var activeRecordingShortcutAction: ShortcutAction?
    private var interruptedRecordingActions = Set<ShortcutAction>()
    private var activeShortcutCanCancelAccidentalStart = false
    private var lastShortcutPressTime: Date?
    private var silenceAutoCancelTask: Task<Void, Never>?
    private var handsFreeSessionID: UUID?
    /// True once the silence watch has heard a real voice in the current hands-free recording.
    private var voiceHeardInSession = false

    private let shortcutPressCooldown: TimeInterval = 0.5
    private let hybridPressThreshold: TimeInterval = 0.5
    // A quick tap that leaves a hands-free recording running in the background (see handleKeyUp)
    // has no other way to stop itself. Without this, a tap that captures no speech records
    // silently until the shortcut is pressed again, and whatever ambient audio happened in
    // between gets transcribed and delivered instead of being canceled.
    private let silenceAutoCancelDelay: TimeInterval

    init(
        canHandleShortcutAction: @escaping @MainActor () -> Bool,
        isRecorderVisible: @escaping @MainActor () -> Bool,
        recordingState: @escaping @MainActor () -> RecordingState,
        toggleRecorderPanel: @escaping @MainActor (UUID?) async -> Void,
        cancelRecording: @escaping @MainActor () async -> Void,
        isStreamingSession: @escaping @MainActor () -> Bool,
        hasCapturedSpeech: @escaping @MainActor () -> Bool,
        micLevel: @escaping @MainActor () -> Double = { 0 },
        // Rene, Oct 11 2026: 4 s of live mic with no voice = nothing coming, cancel.
        silenceAutoCancelDelay: TimeInterval = 4
    ) {
        self.canHandleShortcutAction = canHandleShortcutAction
        self.isRecorderVisible = isRecorderVisible
        self.recordingState = recordingState
        self.toggleRecorderPanel = toggleRecorderPanel
        self.cancelRecording = cancelRecording
        self.isStreamingSession = isStreamingSession
        self.hasCapturedSpeech = hasCapturedSpeech
        self.micLevel = micLevel
        self.silenceAutoCancelDelay = silenceAutoCancelDelay
    }

    func reset() {
        isShortcutPressed = false
        shortcutPressStartTime = nil
        isHandsFreeRecording = false
        activeRecordingShortcutAction = nil
        interruptedRecordingActions.removeAll()
        activeShortcutCanCancelAccidentalStart = false
        silenceAutoCancelTask?.cancel()
        silenceAutoCancelTask = nil
        handsFreeSessionID = nil
        voiceHeardInSession = false
    }

    /// A hands-free recording is running and nothing has been said into it yet
    /// (no streaming words, no voice-level signal on the mic).
    var isSilentHandsFreeRecording: Bool {
        isHandsFreeRecording && !voiceHeardInSession && !hasCapturedSpeech()
    }

    /// Esc during a silent hands-free recording: throw it away right now, no second press,
    /// no "didn't catch any words" notice. Returns false (does nothing) if anything was said.
    func cancelIfSilentHandsFree() async -> Bool {
        guard isSilentHandsFreeRecording else { return false }
        ninoDbg("NINODBG silence-watch: Esc with no voice, canceling")
        reset()
        await cancelRecording()
        return true
    }

    /// Auto-cancels a hands-free recording that captured no speech, so a quick tap that
    /// wasn't meant to start a real dictation doesn't sit recording in the background until
    /// the shortcut is pressed again. Only applies to streaming models, where `hasCapturedSpeech`
    /// is a real signal — batch models never populate a partial transcript mid-recording, so
    /// there's no reliable way to tell silence from real speech before the recording ends.
    // Rene's eMeet mic: room silence peaks around -45..-35 dB, his speech -34..-20 dB
    // (calibrated on 140 real recordings, Oct 2026). -34 dB = 0.433 on the 0...1 meter.
    private static let voiceLevelThreshold: Double = 0.433
    // Loud polls (50 ms apart) needed before we call it a voice, so one click or pop
    // can't count. The first half second after the mic goes live is ignored: the
    // eMeet emits a pop when it opens.
    private static let voiceTicksRequired = 4
    private static let micOpenPopIgnore: TimeInterval = 0.5
    private static let pollInterval: TimeInterval = 0.05

    /// Watches a hands-free recording and cancels it only if the mic has been LIVE for the full
    /// window and neither the streaming transcript nor the mic level ever showed a voice.
    ///
    /// Two bugs this replaces (Oct 2026): the window used to start at key-up, so when the mic
    /// took ~4 s to come up the recording was killed ~2 s after it actually started; and "speech"
    /// meant only "the streaming model has produced a partial", which lags real speech by a
    /// second or more, so real sentences were thrown away as silence.
    private func scheduleSilenceAutoCancel() {
        silenceAutoCancelTask?.cancel()
        let sessionID = UUID()
        handsFreeSessionID = sessionID
        voiceHeardInSession = false
        let window = silenceAutoCancelDelay
        let tickNanos = UInt64(Self.pollInterval * 1_000_000_000)
        silenceAutoCancelTask = Task { [weak self] in
            // 1. Wait for the mic to actually be live. Starting can take seconds.
            var waited: TimeInterval = 0
            while true {
                guard let self, !Task.isCancelled,
                      self.isHandsFreeRecording,
                      self.handsFreeSessionID == sessionID else { return }
                let state = self.recordingState()
                if state == .recording { break }
                guard state == .starting, waited < 20 else { return }
                try? await Task.sleep(nanoseconds: tickNanos)
                waited += Self.pollInterval
            }

            // 2. Count only live-mic time; any sign of a voice ends the watch for good.
            var live: TimeInterval = 0
            var loudTicks = 0
            while live < window {
                try? await Task.sleep(nanoseconds: tickNanos)
                live += Self.pollInterval
                guard let self, !Task.isCancelled,
                      self.isHandsFreeRecording,
                      self.handsFreeSessionID == sessionID,
                      self.recordingState() == .recording else { return }
                if self.hasCapturedSpeech() { self.voiceHeardInSession = true; return }
                if live > Self.micOpenPopIgnore, self.micLevel() >= Self.voiceLevelThreshold {
                    loudTicks += 1
                    if loudTicks >= Self.voiceTicksRequired {
                        self.voiceHeardInSession = true
                        ninoDbg("NINODBG silence-watch: voice heard at %.2fs live, keeping recording", live)
                        return
                    }
                }
            }

            guard let self, !Task.isCancelled,
                  self.isHandsFreeRecording,
                  self.handsFreeSessionID == sessionID,
                  self.recordingState() == .recording,
                  self.isStreamingSession(),
                  !self.hasCapturedSpeech() else { return }
            ninoDbg("NINODBG silence-watch: auto-cancel after %.1fs of live mic with no voice (loudTicks=%ld)", live, loudTicks)
            self.reset()
            await self.cancelRecording()
        }
    }

    func handleKeyDown(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        modeId: UUID? = nil
    ) async {
        if interruptedRecordingActions.remove(action) != nil {
            return
        }

        if let lastTrigger = lastShortcutPressTime,
           Date().timeIntervalSince(lastTrigger) < shortcutPressCooldown {
            return
        }

        guard !isShortcutPressed else {
            return
        }
        isShortcutPressed = true
        activeRecordingShortcutAction = action
        activeShortcutCanCancelAccidentalStart = canCurrentShortcutPressCancelAccidentalStart
        lastShortcutPressTime = Date()
        shortcutPressStartTime = eventTime

        switch mode {
        case .toggle, .hybrid:
            if isHandsFreeRecording {
                // Pressed again before saying anything: just make it go away quietly
                // instead of stopping and transcribing an empty clip.
                if isSilentHandsFreeRecording, recordingState() == .recording {
                    ninoDbg("NINODBG silence-watch: second press with no voice, canceling")
                    reset()
                    await cancelRecording()
                    return
                }
                isHandsFreeRecording = false
                silenceAutoCancelTask?.cancel()
                silenceAutoCancelTask = nil
                handsFreeSessionID = nil
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
                return
            }

            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .pushToTalk:
            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }
        }
    }

    func handleKeyUp(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        modeId: UUID? = nil
    ) async {
        guard isShortcutPressed, activeRecordingShortcutAction == action else { return }
        isShortcutPressed = false
        activeRecordingShortcutAction = nil
        activeShortcutCanCancelAccidentalStart = false

        switch mode {
        case .toggle:
            isHandsFreeRecording = true
            scheduleSilenceAutoCancel()

        case .pushToTalk:
            ninoDbg("NINOKEY pushToTalk-branch visible=%@ canHandle=%@ state=%@",
                  String(describing: isRecorderVisible()),
                  String(describing: canHandleShortcutAction()),
                  String(describing: recordingState()))
            if isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .hybrid:
            let pressDuration = shortcutPressStartTime.map { eventTime - $0 } ?? 0
            if pressDuration >= hybridPressThreshold && recordingState() == .recording {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            } else {
                isHandsFreeRecording = true
                scheduleSilenceAutoCancel()
            }
        }

        shortcutPressStartTime = nil
    }

    func handleInterruption(action: ShortcutAction) async {
        guard isShortcutPressed, activeRecordingShortcutAction == action else {
            if canCurrentShortcutPressCancelAccidentalStart {
                interruptedRecordingActions.insert(action)
            }
            return
        }

        guard activeShortcutCanCancelAccidentalStart else { return }

        reset()
        await cancelRecording()
    }

    private var canCurrentShortcutPressCancelAccidentalStart: Bool {
        !isRecorderVisible() && recordingState() == .idle
    }
}
