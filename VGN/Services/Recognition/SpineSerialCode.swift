import Foundation

/// The region a PlayStation serial-code prefix implies.
enum SerialRegion: String, Sendable, Codable, Equatable {
    case europe, northAmerica, japan, asia, unknown
}

/// A PlayStation product serial code read off a spine (PLAN §6.2 step 3), e.g.
/// `CUSA 00194`, `PPSA 04609`, `BLES 01402`. The prefix pins the platform (and often
/// the region), so a matched code is a strong platform/region booster for a detection
/// when their positions line up.
struct SpineSerialCode: Sendable, Equatable, Codable {
    /// Normalised, no separator: `CUSA00194`.
    var raw: String
    /// The 4-letter family prefix: `CUSA`.
    var prefix: String
    /// The digit block: `00194`.
    var number: String
    /// VGN platform slug the prefix implies.
    var platformSlug: String
    var region: SerialRegion

    /// Prefix → (slug, region). Modern families are region-agnostic in the prefix
    /// (region lives elsewhere), so they report `.unknown`. The `S***`/legacy
    /// families are included for completeness; SLES/SCES are PS1/PS2-shared, mapped to
    /// PS2 (the shelf set has neither, so this never affects accuracy here).
    static let prefixMap: [String: (slug: String, region: SerialRegion)] = [
        // PS5
        "PPSA": ("ps5", .unknown), "PCSF": ("ps5", .unknown),
        // PS4
        "CUSA": ("ps4", .unknown),
        // PS3
        "BLES": ("ps3", .europe), "BCES": ("ps3", .europe), "BLED": ("ps3", .europe),
        "BLUS": ("ps3", .northAmerica), "BCUS": ("ps3", .northAmerica),
        "BLJM": ("ps3", .japan), "BCJS": ("ps3", .japan), "BLJS": ("ps3", .japan),
        "BLAS": ("ps3", .asia), "BCAS": ("ps3", .asia),
        // PS Vita
        "PCSB": ("vita", .europe), "PCSE": ("vita", .northAmerica),
        "PCSG": ("vita", .japan), "PCSH": ("vita", .japan), "PCSA": ("vita", .asia),
        // PSP
        "ULES": ("psp", .europe), "UCES": ("psp", .europe),
        "ULUS": ("psp", .northAmerica), "UCUS": ("psp", .northAmerica),
        "ULJM": ("psp", .japan), "UCJS": ("psp", .japan), "ULJS": ("psp", .japan),
        // PS2 (SLES/SCES also appear on PS1; PS2 is the common case)
        "SLES": ("ps2", .europe), "SCES": ("ps2", .europe),
        "SLUS": ("ps2", .northAmerica), "SCUS": ("ps2", .northAmerica),
        "SLPS": ("ps2", .japan), "SLPM": ("ps2", .japan), "SCPS": ("ps2", .japan),
    ]

    /// One regex, reused. 4 letters, optional space/hyphen/dot, 5 digits. The prefix
    /// is validated against `prefixMap` after matching so arbitrary 4-letter words
    /// (e.g. "GAME 12345") are rejected.
    private static let regex = try! NSRegularExpression(
        pattern: #"\b([A-Z]{4})[\s\-\.]?(\d{5})\b"#,
        options: []
    )

    /// Extract every recognised serial code from a block of OCR text, in order.
    static func extractAll(from text: String) -> [SpineSerialCode] {
        let upper = text.uppercased()
        let ns = upper as NSString
        var out: [SpineSerialCode] = []
        for match in regex.matches(in: upper, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges == 3 else { continue }
            let prefix = ns.substring(with: match.range(at: 1))
            let number = ns.substring(with: match.range(at: 2))
            guard let mapping = prefixMap[prefix] else { continue }
            out.append(SpineSerialCode(
                raw: prefix + number,
                prefix: prefix,
                number: number,
                platformSlug: mapping.slug,
                region: mapping.region
            ))
        }
        return out
    }

    /// The first recognised code, if any.
    static func first(in text: String) -> SpineSerialCode? {
        extractAll(from: text).first
    }
}
