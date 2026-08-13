import Testing
@testable import VoiceInk

/// Covers `AIEnhancementService.isBlank` — the pure predicate that short-circuits `makeRequest`
/// before any provider (including the local CLI) is invoked, so an empty/no-speech transcript
/// never reaches a CLI process or network call. See the guard right above `makeRequest`.
struct AIEnhancementServiceBlankTextTests {
    @Test func emptyStringIsBlank() {
        #expect(AIEnhancementService.isBlank(""))
    }

    @Test func whitespaceOnlyIsBlank() {
        #expect(AIEnhancementService.isBlank("   \n\t  "))
    }

    @Test func realTextIsNotBlank() {
        #expect(!AIEnhancementService.isBlank("hello"))
    }

    @Test func punctuationOnlyIsNotBlank() {
        // Out of scope by design: only empty/whitespace short-circuits. A punctuation-only
        // transcript ("...", "?") still reaches the provider as before.
        #expect(!AIEnhancementService.isBlank("..."))
    }
}
