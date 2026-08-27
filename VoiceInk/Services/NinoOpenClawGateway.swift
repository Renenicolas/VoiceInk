import Foundation

struct NinoOpenClawGateway {
    static let gatewayURLDefaultsKey = "NinoOpenClawGatewayURL"
    static let defaultGatewayURL = URL(string: "http://127.0.0.1:18789")!

    enum GatewayError: LocalizedError {
        case invalidGatewayURL
        case missingToken
        case rejected(String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .invalidGatewayURL:
                return "Nino's gateway address is not valid."
            case .missingToken:
                return "Nino's gateway token is missing."
            case .rejected(let message):
                return message
            case .emptyResponse:
                return "Nino finished without an answer."
            }
        }
    }

    private struct OpenClawConfig: Decodable {
        struct Gateway: Decodable {
            struct Auth: Decodable { let token: String? }
            let auth: Auth?
        }
        let gateway: Gateway?
    }

    private struct RequestBody: Encodable {
        struct InputMessage: Encodable {
            let type = "message"
            let role: String
            let content: String
        }

        let model = "agent:main"
        let input: [InputMessage]
        let stream = true
        let user = "voiceink-ask-nino"
    }

    private struct StreamEvent: Decodable {
        struct Response: Decodable {
            struct Failure: Decodable { let message: String? }
            let error: Failure?
        }

        let type: String
        let delta: String?
        let response: Response?
    }

    private var gatewayURL: URL {
        guard let override = UserDefaults.standard.string(forKey: Self.gatewayURLDefaultsKey),
              !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.defaultGatewayURL
        }
        return URL(string: override) ?? Self.defaultGatewayURL
    }

    func streamReply(
        messages: [AssistantDisplayMessage],
        onStreaming: @MainActor @escaping () -> Void
    ) async throws -> String {
        let token = try loadToken()
        let endpoint = gatewayURL.appendingPathComponent("v1/responses")
        guard endpoint.scheme == "http" || endpoint.scheme == "https" else {
            throw GatewayError.invalidGatewayURL
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                input: messages.map {
                    RequestBody.InputMessage(
                        role: $0.role.rawValue,
                        content: $0.content
                    )
                }
            )
        )

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GatewayError.rejected("Nino's gateway returned an unreadable response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw GatewayError.rejected("Nino's gateway refused the request (\(httpResponse.statusCode)).")
        }

        await onStreaming()
        var answer = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]", let data = payload.data(using: .utf8) else { continue }
            let event = try JSONDecoder().decode(StreamEvent.self, from: data)
            if event.type == "response.output_text.delta", let delta = event.delta {
                answer += delta
            } else if event.type == "response.failed" {
                throw GatewayError.rejected(event.response?.error?.message ?? "Nino could not finish that request.")
            }
        }

        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GatewayError.emptyResponse }
        return trimmed
    }

    private func loadToken() throws -> String {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/openclaw.json")
        let data = try Data(contentsOf: configURL)
        let token = try JSONDecoder().decode(OpenClawConfig.self, from: data)
            .gateway?.auth?.token?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, !token.isEmpty else { throw GatewayError.missingToken }
        return token
    }
}
