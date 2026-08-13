import Testing
@testable import VoiceInk

/// Covers the pure `key(bundleID:browserTabURL:)` computation — the part of
/// `StyleContextKeyResolver` that doesn't shell out to AppleScript, so it's fully deterministic.
/// `resolve(bundleID:)` (the async wrapper that fetches a live browser tab URL) is exercised by
/// running the app, not here — it has no meaningful behavior beyond "fetch a URL, then call this
/// pure function," which these tests already cover.
struct StyleContextKeyResolverTests {
    private let chromeBundleID = "com.google.Chrome"
    private let safariBundleID = "com.apple.Safari"
    private let nativeBundleID = "com.apple.mail"

    @Test func browserWithURLYieldsWebDomainKey() {
        let key = StyleContextKeyResolver.key(
            bundleID: chromeBundleID,
            browserTabURL: "https://mail.google.com/mail/u/0/#inbox"
        )
        #expect(key == "web:mail.google.com")
    }

    @Test func sameDomainAcrossDifferentBrowsersYieldsTheSameKey() {
        let chromeKey = StyleContextKeyResolver.key(
            bundleID: chromeBundleID,
            browserTabURL: "https://mail.google.com/mail/u/0/#inbox"
        )
        let safariKey = StyleContextKeyResolver.key(
            bundleID: safariBundleID,
            browserTabURL: "https://mail.google.com/mail/u/0/#inbox"
        )
        #expect(chromeKey == safariKey)
        #expect(chromeKey == "web:mail.google.com")
    }

    @Test func nativeAppYieldsAppBundleIDKey() {
        let key = StyleContextKeyResolver.key(bundleID: nativeBundleID, browserTabURL: nil)
        #expect(key == "app:com.apple.mail")
    }

    @Test func browserWithNoURLFallsBackToAppKey() {
        let key = StyleContextKeyResolver.key(bundleID: chromeBundleID, browserTabURL: nil)
        #expect(key == "app:com.google.Chrome")
    }

    // MARK: - Edge cases called out by the spec

    @Test func differentSubdomainsOfTheSameSiteStayDistinct() {
        let mail = StyleContextKeyResolver.key(bundleID: chromeBundleID, browserTabURL: "https://mail.google.com/")
        let docs = StyleContextKeyResolver.key(bundleID: chromeBundleID, browserTabURL: "https://docs.google.com/")
        #expect(mail != docs)
    }

    @Test func httpAndHttpsOfTheSameHostYieldTheSameKey() {
        let http = StyleContextKeyResolver.key(bundleID: chromeBundleID, browserTabURL: "http://example.com/page")
        let https = StyleContextKeyResolver.key(bundleID: chromeBundleID, browserTabURL: "https://example.com/page")
        #expect(http == https)
        #expect(http == "web:example.com")
    }

    @Test func wwwPrefixIsStripped() {
        let key = StyleContextKeyResolver.key(bundleID: chromeBundleID, browserTabURL: "https://www.example.com/")
        #expect(key == "web:example.com")
    }

    @Test func localhostResolvesToAWebKey() {
        let key = StyleContextKeyResolver.key(bundleID: chromeBundleID, browserTabURL: "http://localhost:3000/app")
        #expect(key == "web:localhost")
    }

    @Test func nonBrowserAppWithAURLStillYieldsAnAppKey() {
        // e.g. a native app embedding a webview reporting a URL some other way — only apps in
        // `BrowserType.allCases` (the ones AppleScript URL fetching is wired up for) ever get a
        // web key.
        let key = StyleContextKeyResolver.key(bundleID: nativeBundleID, browserTabURL: "https://mail.google.com/")
        #expect(key == "app:com.apple.mail")
    }
}
