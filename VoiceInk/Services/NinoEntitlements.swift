import Foundation
import Combine

let ninoEntitlementsRefreshInterval: TimeInterval = 60
let ninoEntitlementsOfflineGrace: TimeInterval = 7 * 24 * 60 * 60

enum NinoPersona: String, Codable, Sendable {
    case personal, business, enterprise, `operator`
}

enum NinoClientStatus: String, Codable, Sendable {
    case active
    case pastDue = "past_due"
    case paused
    case killed
}

enum NinoBrainMode: String, Codable, Sendable {
    case local, hosted
}

struct NinoEntitlements: Codable, Equatable, Sendable {
    let slug: String
    let status: NinoClientStatus
    let persona: NinoPersona
    let features: [String: Bool]
    let entitlementsVersion: Int
    let brainMode: NinoBrainMode
    let brainURL: String?

    enum CodingKeys: String, CodingKey {
        case slug, status, persona, features, entitlementsVersion, brainMode
        case brainURL = "brainUrl"
    }
}

enum NinoSectorRendering: Equatable, Sendable {
    case voiceContents
    case ninoOSPage(path: String)
}

struct NinoSector: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let blurb: String
    let rendering: NinoSectorRendering

    static let voice = NinoSector(id: "voice", label: "Voice", blurb: "Talk anywhere; Nino types it.", rendering: .voiceContents)
    static let brain = NinoSector(id: "brain", label: "Brain", blurb: "Everything Nino knows about you.", rendering: .ninoOSPage(path: "/brain"))
    static let sweep = NinoSector(id: "sweep", label: "Sweep", blurb: "Scan this machine, file it, clean up.", rendering: .ninoOSPage(path: "/sweep"))
    static let agent = NinoSector(id: "agent", label: "Agent", blurb: "Ask Nino to do something bigger.", rendering: .ninoOSPage(path: "/agent"))

    static let all: [NinoSector] = [.voice, .brain, .sweep, .agent]
}

enum NinoAlwaysVisibleDestination: String, Equatable, Sendable {
    case settings
    case licence
}

struct NinoSidebarVisibility: Equatable, Sendable {
    let sectorIDs: Set<String>
    let alwaysVisibleDestinations: [NinoAlwaysVisibleDestination]

    static let fallback = NinoSidebarVisibility(
        sectorIDs: ["voice"],
        alwaysVisibleDestinations: [.settings, .licence]
    )
}

enum NinoEntitlementPolicy {
    static func visibility(for entitlements: NinoEntitlements) -> NinoSidebarVisibility {
        let sectorIDs: Set<String>
        if entitlements.status == .active {
            sectorIDs = Set(NinoSector.all.compactMap { sector in
                entitlements.features[sector.id] == true ? sector.id : nil
            })
        } else {
            sectorIDs = []
        }

        return NinoSidebarVisibility(
            sectorIDs: sectorIDs,
            alwaysVisibleDestinations: [.settings, .licence]
        )
    }
}

struct NinoCachedEntitlements: Codable, Equatable, Sendable {
    let entitlements: NinoEntitlements
    let fetchedAt: Date
}

protocol NinoEntitlementsCaching: Sendable {
    func load() -> NinoCachedEntitlements?
    func save(_ value: NinoCachedEntitlements)
}

final class NinoEntitlementsFileCache: NinoEntitlementsCaching, @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
    }

    func load() -> NinoCachedEntitlements? {
        lock.withLock {
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return try? JSONDecoder().decode(NinoCachedEntitlements.self, from: data)
        }
    }

    func save(_ value: NinoCachedEntitlements) {
        lock.withLock {
            guard let data = try? JSONEncoder().encode(value) else { return }
            do {
                try fileManager.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: fileURL, options: .atomic)
            } catch {
                // A failed cache write must not replace the in-memory online result.
            }
        }
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        let applicationSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        let appDirectory = Bundle.main.bundleIdentifier ?? "VoiceInk"
        return applicationSupport
            .appendingPathComponent(appDirectory, isDirectory: true)
            .appendingPathComponent("Nino", isDirectory: true)
            .appendingPathComponent("entitlements.json")
    }
}

enum NinoEntitlementsSource: Equatable, Sendable {
    case network, cache, fallback
}

struct NinoEntitlementState: Equatable, Sendable {
    let visibility: NinoSidebarVisibility
    let source: NinoEntitlementsSource
}

struct NinoEntitlementsClient: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let baseURL: URL?
    private let activationKey: String
    private let cache: any NinoEntitlementsCaching
    private let fetch: Fetch
    private let now: @Sendable () -> Date

    init(
        baseURL: URL?,
        activationKey: String,
        cache: any NinoEntitlementsCaching = NinoEntitlementsFileCache(),
        fetch: @escaping Fetch = { request in try await URLSession.shared.data(for: request) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseURL = baseURL
        self.activationKey = activationKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cache = cache
        self.fetch = fetch
        self.now = now
    }

    func refresh() async -> NinoEntitlementState {
        if let fresh = await fetchFresh() {
            cache.save(NinoCachedEntitlements(entitlements: fresh, fetchedAt: now()))
            return NinoEntitlementState(
                visibility: NinoEntitlementPolicy.visibility(for: fresh),
                source: .network
            )
        }

        guard let cached = cache.load() else {
            return NinoEntitlementState(visibility: .fallback, source: .fallback)
        }

        let age = now().timeIntervalSince(cached.fetchedAt)
        guard age >= 0, age < ninoEntitlementsOfflineGrace else {
            return NinoEntitlementState(
                visibility: NinoSidebarVisibility(
                    sectorIDs: [],
                    alwaysVisibleDestinations: [.settings, .licence]
                ),
                source: .cache
            )
        }

        return NinoEntitlementState(
            visibility: NinoEntitlementPolicy.visibility(for: cached.entitlements),
            source: .cache
        )
    }

    private func fetchFresh() async -> NinoEntitlements? {
        guard let baseURL, !activationKey.isEmpty else { return nil }
        let endpoint = baseURL.appendingPathComponent("api/entitlements")
        var request = URLRequest(url: endpoint, timeoutInterval: 5)
        request.setValue("Bearer \(activationKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await fetch(request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return try JSONDecoder().decode(NinoEntitlements.self, from: data)
        } catch {
            return nil
        }
    }
}

enum NinoCRMConfiguration {
    static var baseURL: URL? {
        let buildSetting = Bundle.main.object(forInfoDictionaryKey: "NinoCRMBaseURL") as? String
        let environment = ProcessInfo.processInfo.environment["NINO_CRM_BASE_URL"]
        return [buildSetting, environment]
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter { !$0.isEmpty }
            .compactMap(URL.init(string:))
            .first { url in
                ["http", "https"].contains(url.scheme?.lowercased()) && url.host != nil
            }
    }
}

@MainActor
final class NinoEntitlementsModel: ObservableObject {
    @Published private(set) var state = NinoEntitlementState(
        visibility: .fallback,
        source: .fallback
    )

    private let clientProvider: () -> NinoEntitlementsClient

    init(client: NinoEntitlementsClient? = nil) {
        if let client {
            clientProvider = { client }
        } else {
            clientProvider = {
                NinoEntitlementsClient(
                    baseURL: NinoCRMConfiguration.baseURL,
                    activationKey: LicenseManager.shared.licenseKey ?? ""
                )
            }
        }
    }

    func refresh() async {
        state = await clientProvider().refresh()
    }
}
