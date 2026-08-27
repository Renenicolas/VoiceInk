import Foundation

/// Nino's hands. Sends a message to the OpenClaw agent and returns its reply.
///
/// WHY THIS SHELLS OUT INSTEAD OF POSTING JSON: the gateway's HTTP port (18789)
/// serves the control UI and `/health` only — every API path probed there returns
/// 404, and the separate gateway port named in the CLI help (19001) is not
/// listening. The interface that actually exists and answers is the CLI:
///
///     openclaw agent --agent main --message-file /dev/stdin --json
///
/// It was verified end to end before this file was written, so this is the
/// contract as observed, not as documented.
///
/// The agent runs on the always-on mini, so the call goes over SSH. The message
/// is written to the remote process's STDIN rather than interpolated into the
/// remote command line — `ssh host "cmd"` hands its argument to a remote shell,
/// so user text in that string would be shell-injected. Nothing the user says
/// ever becomes part of a command.
///
/// Requests still pass through the agent, so guard.ts (ask/act/spend, the scoped
/// brain fence, the spend approval that times out to deny) applies exactly as it
/// does for Telegram. There is no second path to the brain.
enum NinoOpenClawGateway {
    enum GatewayError: LocalizedError {
        case unreachable
        case timedOut
        case failed(String)
        case emptyReply

        var errorDescription: String? {
            switch self {
            case .unreachable: return "Can't reach Nino's hands right now."
            case .timedOut: return "Nino took too long to answer."
            case .emptyReply: return "Nino answered with nothing."
            case .failed(let detail): return "Nino's hands hit a problem: \(detail)"
            }
        }
    }

    /// Host running the agent. Overridable for a different machine.
    static var host: String {
        UserDefaults.standard.string(forKey: "NinoOpenClawHost") ?? "reno-mini"
    }

    /// Agent id. `main` is the default agent ("⚡ Nino").
    static var agentId: String {
        UserDefaults.standard.string(forKey: "NinoOpenClawAgent") ?? "main"
    }

    static var timeoutSeconds: Double {
        let stored = UserDefaults.standard.double(forKey: "NinoOpenClawTimeoutSeconds")
        return stored > 0 ? max(10, stored) : 90
    }

    static func send(_ message: String) async throws -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GatewayError.emptyReply }

        let raw = try await runAgent(message: trimmed)
        return try parseReply(from: raw)
    }

    /// Pulls the assistant's text out of the CLI's JSON.
    /// Observed shape: `.result.meta.finalAssistantVisibleText`, with
    /// `.result.payloads[0].text` carrying the same string. "Visible" is
    /// preferred — it is what a human is meant to read.
    static func parseReply(from data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GatewayError.failed("unreadable reply")
        }
        if let status = root["status"] as? String, status != "ok" {
            throw GatewayError.failed(status)
        }
        let result = root["result"] as? [String: Any]
        if let meta = result?["meta"] as? [String: Any],
           let visible = meta["finalAssistantVisibleText"] as? String,
           !visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return visible
        }
        if let payloads = result?["payloads"] as? [[String: Any]],
           let text = payloads.first?["text"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        throw GatewayError.emptyReply
    }

    private static func runAgent(message: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                // The remote command is a fixed string. The user's text goes in on
                // stdin via --message-file /dev/stdin, never into this array.
                process.arguments = [
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=8",
                    host,
                    "openclaw agent --agent \(agentId) --message-file /dev/stdin --json",
                ]

                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = ShellCommandEnvironment.preferredPATH(fallback: environment["PATH"])
                process.environment = environment

                let input = Pipe(), output = Pipe(), errorPipe = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = errorPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: GatewayError.unreachable)
                    return
                }

                input.fileHandleForWriting.write(Data(message.utf8))
                try? input.fileHandleForWriting.close()

                // Read before waiting: a full pipe buffer would deadlock otherwise.
                let outData = output.fileHandleForReading.readDataToEndOfFile()
                let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                let deadline = DispatchTime.now() + timeoutSeconds
                let finished = DispatchQueue.global().sync { () -> Bool in
                    while process.isRunning {
                        if DispatchTime.now() > deadline { return false }
                        usleep(50_000)
                    }
                    return true
                }
                guard finished else {
                    process.terminate()
                    continuation.resume(throwing: GatewayError.timedOut)
                    return
                }

                guard process.terminationStatus == 0 else {
                    let detail = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    // ssh's own failures are a reachability problem, not an agent one.
                    if detail.localizedCaseInsensitiveContains("connection")
                        || detail.localizedCaseInsensitiveContains("resolve")
                        || detail.localizedCaseInsensitiveContains("timed out") {
                        continuation.resume(throwing: GatewayError.unreachable)
                    } else {
                        continuation.resume(throwing: GatewayError.failed(String(detail.prefix(200))))
                    }
                    return
                }
                continuation.resume(returning: outData)
            }
        }
    }
}
