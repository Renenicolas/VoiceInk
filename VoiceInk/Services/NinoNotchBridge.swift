import Foundation
import AppKit
import AVFoundation
import Combine
import Darwin

/// Nino Notch is the only app that draws in the notch. Nino Voice runs headless
/// behind it: this bridge sends the engine's live state to Nino Notch and takes
/// its commands (start/stop, Ask Nino, open settings).
///
/// WHY A UNIX SOCKET AND NOT DistributedNotificationCenter: distributed
/// notifications are broadcast to every process on the Mac, sandboxed apps
/// included. That would leak every transcript, and any app could post "ask",
/// which runs the OpenClaw agent with hands on this Mac. The socket lives in a
/// 0700 folder, is 0600 itself, and every peer's uid is checked, so only this
/// user's own unsandboxed processes can reach it.
///
/// Wire format: one JSON object per line.
///   engine -> notch: {"type":"state", ...}   {"type":"meter","level":0.42}
///   notch -> engine: {"cmd":"toggleRecord"}  {"cmd":"askSend","text":"..."}  ...
/// The same shapes are mirrored in nino-notch `Nino/NinoVoiceLink.swift`.
@MainActor
final class NinoNotchBridge {
    static let shared = NinoNotchBridge()

    /// Headless unless someone opts back into the old standalone chrome
    /// (`defaults write com.prakashjoshipax.VoiceInk NinoVoiceStandalone -bool YES`).
    /// Even standalone, Nino Voice no longer draws its own notch.
    nonisolated static var isHeadless: Bool {
        !UserDefaults.standard.bool(forKey: "NinoVoiceStandalone")
    }

    /// True until Nino Notch asks for a window. SwiftUI's WindowGroup opens the
    /// main (or onboarding) window at launch; headless, that must stay hidden.
    nonisolated(unsafe) static var suppressesLaunchWindow = isHeadless  // main thread only (window setup + bridge commands)

    static var socketPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Nino Notch's own support folder (plain "Nino" belongs to another app).
        return base.appendingPathComponent("com.meetnino.notch", isDirectory: true)
            .appendingPathComponent("voice.sock").path
    }

    private weak var engine: VoiceInkEngine?
    private weak var recorderUIManager: RecorderUIManager?
    private weak var menuBarManager: MenuBarManager?
    private let server = NinoBridgeSocketServer(path: NinoNotchBridge.socketPath)
    private var cancellables = Set<AnyCancellable>()
    private var sendScheduled = false
    private var lastText = ""
    private let encoder = JSONEncoder()

    func configure(engine: VoiceInkEngine, recorderUIManager: RecorderUIManager, menuBarManager: MenuBarManager) {
        self.engine = engine
        self.recorderUIManager = recorderUIManager
        self.menuBarManager = menuBarManager

        server.onLine = { [weak self] data in
            Task { @MainActor in self?.handle(data) }
        }
        server.onConnect = { [weak self] in
            Task { @MainActor in self?.sendState() }
        }
        do {
            try server.start()
        } catch {
            NSLog("NINOBRIDGE could not open %@: %@", Self.socketPath, String(describing: error))
        }

        engine.objectWillChange
            .merge(with: recorderUIManager.objectWillChange, engine.assistantSession.objectWillChange)
            .sink { [weak self] _ in self?.scheduleSend() }
            .store(in: &cancellables)

        ModeManager.shared.$activeConfiguration
            .sink { [weak self] _ in self?.scheduleSend() }
            .store(in: &cancellables)

        engine.recorder.$audioMeter
            .throttle(for: .milliseconds(60), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] meter in self?.sendMeter(meter) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .transcriptionCompleted)
            .sink { [weak self] note in
                guard let self, let t = note.object as? Transcription else { return }
                let text = (t.enhancedText?.isEmpty == false ? t.enhancedText : nil) ?? t.text
                self.lastText = text
                self.scheduleSend()
            }
            .store(in: &cancellables)
    }

    /// Nino Notch quits with its engine: one app, not two half-running.
    private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Commands from Nino Notch

    private func handle(_ data: Data) {
        guard let engine, let ui = recorderUIManager,
              let command = try? JSONDecoder().decode(NinoBridgeCommand.self, from: data) else { return }
        NSLog("NINOBRIDGE cmd=%@", command.cmd)
        Task { @MainActor in
            switch command.cmd {
            case "hello":
                sendState()
            case "toggleRecord":
                // Optional mode id: same path as a mode shortcut (e.g. Option+Command = Enhancement).
                await ui.toggleRecorderPanel(modeId: command.mode.flatMap(UUID.init(uuidString:)))
            case "cancel":
                switch engine.recordingState {
                case .starting, .recording, .transcribing, .enhancing:
                    await ui.cancelRecording()
                case .idle, .busy:
                    await ui.dismissRecorderPanel()
                }
            case "askOpen":
                if !(ui.isRecorderPanelVisible && engine.assistantSession.isVisible) {
                    await ui.toggleAssistantAsk()
                }
            case "askClose":
                if engine.assistantSession.isVisible { await ui.dismissRecorderPanel() }
            case "askSend":
                let text = (command.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                if !(ui.isRecorderPanelVisible && engine.assistantSession.isVisible) {
                    await ui.toggleAssistantAsk()
                }
                guard engine.assistantSession.canSendFollowUp else { return }
                engine.assistantSession.draftText = ""
                await ui.sendAssistantMessage(text)
            case "openSettings":
                Self.suppressesLaunchWindow = false
                menuBarManager?.focusMainWindow()
            case "openHistory":
                menuBarManager?.openHistoryWindow()
            case "openOnboarding":
                // Not onboarded: the main window IS the onboarding flow.
                Self.suppressesLaunchWindow = false
                menuBarManager?.focusMainWindow()
            case "requestPermissions":
                requestPermissions()
            case "quit":
                quit()
            default:
                break
            }
            scheduleSend()
        }
    }

    private func requestPermissions() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in NinoNotchBridge.shared.scheduleSend() }
            }
        }
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    // MARK: - State to Nino Notch

    private func scheduleSend() {
        guard !sendScheduled else { return }
        sendScheduled = true
        // objectWillChange fires BEFORE the value changes; read it next turn.
        DispatchQueue.main.async { [weak self] in
            self?.sendScheduled = false
            self?.sendState()
        }
    }

    private func sendState() {
        guard let engine, let ui = recorderUIManager else { return }
        let session = engine.assistantSession
        let failure: String? = { if case .failed(let m) = session.phase { return m } else { return nil } }()
        let status: String? = {
            switch session.phase {
            case .sending: return "Sending"
            case .streaming, .responding, .sendingFollowUp: return "Thinking"
            case .failed(let m): return m
            case .ready: return session.messages.isEmpty ? nil : "Done"
            case .inactive: return nil
            }
        }()
        let state = NinoBridgeState(
            recording: Self.name(engine.recordingState),
            panelVisible: ui.isRecorderPanelVisible,
            // Hosted in Nino Notch = the old `.notch` style. Mini still draws its own window.
            hostedInNotch: ui.recorderPanelStyle == .notch,
            partial: engine.partialTranscript,
            lastText: lastText,
            modeName: ModeManager.shared.activeConfiguration?.name ?? "",
            modelName: Self.modelName(engine: engine),
            recordKey: ShortcutStore.shortcut(for: .primaryRecording)?.displayString ?? "",
            askKey: ShortcutStore.shortcut(for: .assistantAsk)?.displayString ?? "",
            pasteKey: ShortcutStore.shortcut(for: .pasteLastEnhancement)?.displayString ?? "",
            ask: .init(
                visible: session.isVisible,
                busy: session.isBusy,
                canSend: session.canSendFollowUp,
                status: status,
                failed: failure,
                draft: session.draftText,
                messages: session.messages.map { .init(id: $0.id.uuidString, role: $0.role.rawValue, text: $0.content) }
            ),
            setup: .init(
                onboarded: UserDefaults.standard.bool(forKey: "hasCompletedOnboardingV2"),
                microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                accessibility: AXIsProcessTrusted()
            )
        )
        guard let data = try? encoder.encode(state) else { return }
        server.send(data)
    }

    private func sendMeter(_ meter: AudioMeter) {
        guard engine?.recordingState == .recording else { return }
        let level = max(0, min(1, meter.averagePower))
        server.send(Data(#"{"type":"meter","level":\#(level)}"#.utf8))
    }

    /// Modes pick their own speech model; fall back to the global one.
    private static func modelName(engine: VoiceInkEngine) -> String {
        let manager = engine.transcriptionModelManager
        if let name = ModeManager.shared.activeConfiguration?.selectedTranscriptionModelName, !name.isEmpty {
            return manager.allAvailableModels.first { $0.name == name }?.displayName ?? name
        }
        return manager.currentTranscriptionModel?.displayName ?? ""
    }

    nonisolated static func name(_ state: RecordingState) -> String {
        switch state {
        case .idle: return "idle"
        case .starting: return "starting"
        case .recording: return "recording"
        case .transcribing: return "transcribing"
        case .enhancing: return "enhancing"
        case .busy: return "busy"
        }
    }
}

struct NinoBridgeCommand: Codable {
    let cmd: String
    let text: String?
    let mode: String?
}

struct NinoBridgeState: Codable {
    var type = "state"
    let recording: String
    let panelVisible: Bool
    let hostedInNotch: Bool
    let partial: String
    let lastText: String
    let modeName: String
    let modelName: String
    let recordKey: String
    let askKey: String
    let pasteKey: String
    let ask: Ask
    let setup: Setup

    struct Ask: Codable {
        let visible: Bool
        let busy: Bool
        let canSend: Bool
        let status: String?
        let failed: String?
        let draft: String
        let messages: [Message]
    }

    struct Message: Codable {
        let id: String
        let role: String
        let text: String
    }

    struct Setup: Codable {
        let onboarded: Bool
        let microphone: Bool
        let accessibility: Bool
    }
}

/// Minimal newline-delimited JSON server over a Unix socket.
final class NinoBridgeSocketServer: @unchecked Sendable {
    private let path: String
    private let queue = DispatchQueue(label: "com.meetnino.voice.bridge")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]

    var onLine: (Data) -> Void = { _ in }
    var onConnect: () -> Void = {}

    private final class Client {
        let fd: Int32
        var source: DispatchSourceRead?
        var buffer = Data()
        init(fd: Int32) { self.fd = fd }
    }

    init(path: String) {
        self.path = path
    }

    func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        chmod(dir, 0o700)
        unlink(path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        chmod(path, 0o600)
        guard listen(listenFD, 4) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.resume()
        acceptSource = source
    }

    private func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            return
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // A client that stops reading must not stall the engine forever.
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let client = Client(fd: fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, weak client] in
            guard let self, let client else { return }
            self.read(client)
        }
        source.setCancelHandler { close(fd) }
        client.source = source
        clients[fd] = client
        source.resume()
        onConnect()
    }

    private func read(_ client: Client) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = Darwin.read(client.fd, &chunk, chunk.count)
        guard count > 0 else {
            drop(client)
            return
        }
        client.buffer.append(contentsOf: chunk[0..<count])
        while let newline = client.buffer.firstIndex(of: 0x0A) {
            let line = Data(client.buffer[client.buffer.startIndex..<newline])
            client.buffer.removeSubrange(client.buffer.startIndex...newline)
            if !line.isEmpty { onLine(line) }
        }
        if client.buffer.count > 1_000_000 { drop(client) }
    }

    private func drop(_ client: Client) {
        clients[client.fd] = nil
        client.source?.cancel()
    }

    func send(_ payload: Data) {
        var line = payload
        line.append(0x0A)
        queue.async { [self] in
            for client in clients.values where !Self.writeAll(client.fd, line) {
                drop(client)
            }
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }
}
