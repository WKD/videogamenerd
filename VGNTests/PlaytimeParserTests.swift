import Testing
@testable import VGN

struct PlaytimeParserTests {

    @Test("Hours forms", arguments: [
        ("45h", 45 * 3600),
        ("45 h", 45 * 3600),
        ("45hr", 45 * 3600),
        ("45 hours", 45 * 3600),
        ("45.5h", 45 * 3600 + 30 * 60),
        ("45,5h", 45 * 3600 + 30 * 60),
        ("0.5h", 30 * 60),
    ])
    func hours(input: String, expected: Int) {
        #expect(PlaytimeParser.seconds(from: input) == expected)
    }

    @Test("Minutes forms", arguments: [
        ("90m", 90 * 60),
        ("90 m", 90 * 60),
        ("90 min", 90 * 60),
        ("90 mins", 90 * 60),
        ("90 minutes", 90 * 60),
    ])
    func minutes(input: String, expected: Int) {
        #expect(PlaytimeParser.seconds(from: input) == expected)
    }

    @Test("Days", arguments: [
        ("2d", 2 * 86_400),
        ("2 d", 2 * 86_400),
        ("2 days", 2 * 86_400),
        ("1d", 86_400),
    ])
    func days(input: String, expected: Int) {
        #expect(PlaytimeParser.seconds(from: input) == expected)
    }

    @Test("Clock forms", arguments: [
        ("45:30", 45 * 3600 + 30 * 60),
        ("1:05", 3600 + 5 * 60),
        ("1:05:30", 3600 + 5 * 60 + 30),
        ("0:45", 45 * 60),
    ])
    func clock(input: String, expected: Int) {
        #expect(PlaytimeParser.seconds(from: input) == expected)
    }

    @Test("Combined units", arguments: [
        ("1h30", 3600 + 30 * 60),
        ("1h30m", 3600 + 30 * 60),
        ("1 h 30 m", 3600 + 30 * 60),
        ("2h5m", 2 * 3600 + 5 * 60),
        ("1d2h", 86_400 + 2 * 3600),
        ("1d 2h 30m", 86_400 + 2 * 3600 + 30 * 60),
    ])
    func combined(input: String, expected: Int) {
        #expect(PlaytimeParser.seconds(from: input) == expected)
    }

    @Test("Bare number is hours", arguments: [
        ("45", 45 * 3600),
        ("45.5", 45 * 3600 + 30 * 60),
        ("45,5", 45 * 3600 + 30 * 60),
        ("0", 0),
    ])
    func bare(input: String, expected: Int) {
        #expect(PlaytimeParser.seconds(from: input) == expected)
    }

    @Test("Whitespace and case tolerance")
    func tolerance() {
        #expect(PlaytimeParser.seconds(from: "  45H  ") == 45 * 3600)
        #expect(PlaytimeParser.seconds(from: "1H30M") == 3600 + 30 * 60)
    }

    @Test("Garbage is rejected", arguments: [
        "", "   ", "abc", "h", "45x", "1:2:3:4", "45:99", "1:60",
        "--5h", "h30", "45 potatoes", "1..5h", ":30", "45:",
    ])
    func garbage(input: String) {
        #expect(PlaytimeParser.seconds(from: input) == nil)
    }

    @Test("Format round trips readable")
    func formatting() {
        #expect(PlaytimeParser.format(seconds: 45 * 3600 + 30 * 60) == "45 h 30")
        #expect(PlaytimeParser.format(seconds: 45 * 3600) == "45 h")
        #expect(PlaytimeParser.format(seconds: 30 * 60) == "30 min")
        #expect(PlaytimeParser.format(seconds: 120 * 3600) == "120 h")
        #expect(PlaytimeParser.formatApprox(seconds: 32 * 3600) == "≈ 32 h")
        #expect(PlaytimeParser.formatApprox(seconds: 32 * 3600 + 20 * 60) == "≈ 32 h")
    }
}
