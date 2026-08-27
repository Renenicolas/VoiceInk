import Foundation
import XCTest
@testable import VoiceInk

final class NinoEntitlementsTests: XCTestCase {
    func testEntitledSectorShowsAndUnentitledSectorDoesNot() {
        let entitlements = NinoEntitlements.fixture(features: [
            "voice": true,
            "brain": true,
            "sweep": false,
            "agent": false
        ])

        let visibility = NinoEntitlementPolicy.visibility(for: entitlements)

        XCTAssertTrue(visibility.sectorIDs.contains("brain"))
        XCTAssertFalse(visibility.sectorIDs.contains("sweep"))
    }

    func testSettingsAndLicenceSurviveKillSwitch() {
        let entitlements = NinoEntitlements.fixture(
            status: .killed,
            features: ["voice": true, "brain": true, "sweep": true, "agent": true]
        )

        let visibility = NinoEntitlementPolicy.visibility(for: entitlements)

        XCTAssertTrue(visibility.sectorIDs.isEmpty)
        XCTAssertEqual(visibility.alwaysVisibleDestinations, [.settings, .licence])
    }

    func testUnreachableCRMUsesLastKnownGoodCache() async {
        let cached = NinoCachedEntitlements(
            entitlements: .fixture(features: ["voice": true, "brain": true]),
            fetchedAt: Date()
        )
        let cache = InMemoryNinoEntitlementsCache(cached)
        let client = NinoEntitlementsClient(
            baseURL: URL(string: "https://crm.example.test")!,
            activationKey: "paid-key",
            cache: cache,
            fetch: { _ in throw URLError(.notConnectedToInternet) }
        )

        let state = await client.refresh()

        XCTAssertEqual(state.source, .cache)
        XCTAssertEqual(state.visibility.sectorIDs, ["voice", "brain"])
    }

    func testUnreachableCRMWithoutCacheFallsBackToVoiceOnly() async {
        let cache = InMemoryNinoEntitlementsCache(nil)
        let client = NinoEntitlementsClient(
            baseURL: URL(string: "https://crm.example.test")!,
            activationKey: "paid-key",
            cache: cache,
            fetch: { _ in throw URLError(.cannotConnectToHost) }
        )

        let state = await client.refresh()

        XCTAssertEqual(state.source, .fallback)
        XCTAssertEqual(state.visibility.sectorIDs, ["voice"])
        XCTAssertNotEqual(state.visibility.sectorIDs, Set(NinoSector.all.map(\.id)))
    }
}

private extension NinoEntitlements {
    static func fixture(
        status: NinoClientStatus = .active,
        features: [String: Bool]
    ) -> NinoEntitlements {
        NinoEntitlements(
            slug: "test",
            status: status,
            persona: .personal,
            features: features,
            entitlementsVersion: 1,
            brainMode: .local,
            brainURL: nil
        )
    }
}

private final class InMemoryNinoEntitlementsCache: NinoEntitlementsCaching, @unchecked Sendable {
    private var value: NinoCachedEntitlements?

    init(_ value: NinoCachedEntitlements?) {
        self.value = value
    }

    func load() -> NinoCachedEntitlements? { value }
    func save(_ value: NinoCachedEntitlements) { self.value = value }
}
