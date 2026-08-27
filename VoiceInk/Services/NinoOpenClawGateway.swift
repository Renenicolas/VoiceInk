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
/// It runs the agent LOCALLY (`--local`), on this Mac, on purpose. Routing it to
/// the always-on mini worked and answered questions, but the hands were on the
/// wrong machine: "read my screen" meant the mini's screen and "open that app"
/// meant the mini's apps. Verified locally before this change — asked the local
/// agent to run `sw_vers -productVersion` and it returned this Mac's real OS
/// version, so `tools.exec` genuinely reaches the user's machine. Running local
/// is also markedly faster, with no SSH round trip.
///
/// The message is passed on STDIN via `--message-file /dev/stdin`, never
/// interpolated into a command string, so nothing the user says can be parsed as
/// a command.
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

    /// Set a hostname to run the agent on that machine over SSH instead of here.
    /// Empty (the default) means local, which is what gives Nino hands on THIS Mac.
    static var remoteHost: String? {
        let host = UserDefaults.standard.string(forKey: "NinoOpenClawHost") ?? ""
        return host.isEmpty ? nil : host
    }

    /// Agent id. `main` is the default agent ("⚡ Nino").
    static var agentId: String {
        UserDefaults.standard.string(forKey: "NinoOpenClawAgent") ?? "main"
    }

    /// Absolute path to the `openclaw` binary.
    ///
    /// Resolving it beats trusting PATH: a GUI app does not inherit a login
    /// shell's PATH, and `openclaw` installs into `~/.npm-global/bin`, which is
    /// on Rene's interactive PATH and not on the app's — the first live attempt
    /// failed with `zsh:1: command not found: openclaw` for exactly that reason.
    /// A client's machine may put it somewhere else again, so check the usual
    /// homes and let a UserDefaults override win.
    static var executablePath: String? {
        if let override = UserDefaults.standard.string(forKey: "NinoOpenClawPath"),
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.npm-global/bin/openclaw",
            "/opt/homebrew/bin/openclaw",
            "/usr/local/bin/openclaw",
            "\(home)/.local/bin/openclaw",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
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
        // Two shapes, both seen live: the gateway wraps its answer in `result`
        // and adds `status`; `--local` returns the inner object directly.
        let result = (root["result"] as? [String: Any]) ?? root
        if let meta = result["meta"] as? [String: Any],
           let visible = meta["finalAssistantVisibleText"] as? String,
           !visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return visible
        }
        if let payloads = result["payloads"] as? [[String: Any]],
           let text = payloads.first?["text"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        throw GatewayError.emptyReply
    }

    private static func runAgent(message: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let openclaw = executablePath else {
                    continuation.resume(throwing: GatewayError.failed("openclaw isn't installed where Nino can find it"))
                    return
                }

                let process = Process()
                if let remote = remoteHost {
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                    // The remote command is a FIXED string. The user's text goes in
                    // on stdin, never into this array — `ssh host "cmd"` hands its
                    // argument to a remote shell.
                    process.arguments = [
                        "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                        remote,
                        "openclaw agent --agent \(agentId) --message-file /dev/stdin --json",
                    ]
                } else {
                    // Run the binary directly — no shell, so the arguments below
                    // are exactly the arguments, and nothing can be re-parsed.
                    process.executableURL = URL(fileURLWithPath: openclaw)
                    process.arguments = [
                        "agent", "--local",
                        "--agent", agentId,
                        "--message-file", "/dev/stdin",
                        "--json",
                    ]
                }

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
