import Testing
@testable import VoiceInk

struct SmartNumberFormatterTests {
    @Test(arguments: [
        ("over one hundred twenty-five thousand dollars on it", "over $125,000 on it"),
        ("I just spent 800 bucks", "I just spent $800"),
        ("it costs one fifty", "it costs $150"),
        ("meet at eight thirty tomorrow", "meet at 8:30 tomorrow"),
        ("fifteen million authorized", "15 million authorized"),
        ("like one hundred and ninety K a year", "like 190K a year"),
        ("maybe twenty percent off", "maybe 20% off"),
        ("a 10 grand check", "a $10,000 check"),
        ("one of them is fine", "one of them is fine"),
        ("six eight short clips", "six eight short clips"),
        ("back in nineteen ninety nine", "back in nineteen ninety nine"),
    ])
    func formats(input: String, expected: String) {
        #expect(SmartNumberFormatter.format(input) == expected)
    }
}
