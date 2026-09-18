import Foundation
import Testing
@testable import VGN

/// Table-driven tests for the PlayStation serial-code regex family.
struct SpineSerialCodeTests {

    struct Case {
        let text: String
        let prefix: String?
        let number: String?
        let slug: String?
        let region: SerialRegion?
    }

    @Test("Recognises serial codes across separators and platforms", arguments: [
        Case(text: "CUSA 00194", prefix: "CUSA", number: "00194", slug: "ps4", region: .unknown),
        Case(text: "CUSA-00194", prefix: "CUSA", number: "00194", slug: "ps4", region: .unknown),
        Case(text: "CUSA00194", prefix: "CUSA", number: "00194", slug: "ps4", region: .unknown),
        Case(text: "PPSA 04609", prefix: "PPSA", number: "04609", slug: "ps5", region: .unknown),
        Case(text: "BLES 01402", prefix: "BLES", number: "01402", slug: "ps3", region: .europe),
        Case(text: "BCES-01234", prefix: "BCES", number: "01234", slug: "ps3", region: .europe),
        Case(text: "BLUS 30490", prefix: "BLUS", number: "30490", slug: "ps3", region: .northAmerica),
        Case(text: "BLJM 60001", prefix: "BLJM", number: "60001", slug: "ps3", region: .japan),
        Case(text: "PCSB 00001", prefix: "PCSB", number: "00001", slug: "vita", region: .europe),
        Case(text: "ULES 00001", prefix: "ULES", number: "00001", slug: "psp", region: .europe),
        Case(text: "SLES 50001", prefix: "SLES", number: "50001", slug: "ps2", region: .europe),
        // Lowercase input is upcased.
        Case(text: "cusa 12345", prefix: "CUSA", number: "12345", slug: "ps4", region: .unknown),
        // Non-matches.
        Case(text: "GAME 12345", prefix: nil, number: nil, slug: nil, region: nil),
        Case(text: "CUSA 123", prefix: nil, number: nil, slug: nil, region: nil),
        Case(text: "just a title with no code", prefix: nil, number: nil, slug: nil, region: nil),
    ])
    func recognises(_ c: Case) {
        let code = SpineSerialCode.first(in: c.text)
        #expect(code?.prefix == c.prefix)
        #expect(code?.number == c.number)
        #expect(code?.platformSlug == c.slug)
        #expect(code?.region == c.region)
    }

    @Test("Extracts several codes from a noisy OCR block, in order")
    func extractsMultiple() {
        let text = "SILENT HILL 2  PPSA 04609  ... rating ... CUSA 08519 some noise BLES 02290"
        let codes = SpineSerialCode.extractAll(from: text)
        #expect(codes.map(\.prefix) == ["PPSA", "CUSA", "BLES"])
        #expect(codes.map(\.platformSlug) == ["ps5", "ps4", "ps3"])
    }

    @Test("Embedded within a longer alphanumeric run is not falsely matched")
    func wordBoundary() {
        // No boundary before the prefix / after the digits → rejected.
        #expect(SpineSerialCode.first(in: "XCUSA00194X") == nil)
    }
}
