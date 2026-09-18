import SwiftUI

extension Color {
    /// Build a `Color` from a `#RRGGBB` / `#RRGGBBAA` hex string (the form the
    /// model carries in `TierInfo.colorHex` / `GameSummary.tierColorHex`).
    /// Returns nil for anything it can't parse so callers can fall back.
    init?(hex: String?) {
        guard let hex else { return nil }
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else {
            return nil
        }
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// A stable, pleasant colour derived from an arbitrary string — used to
    /// tint generated placeholder covers so a coverless library still reads as
    /// a varied grid rather than a wall of grey.
    static func stableTint(for seed: String) -> Color {
        // FNV-1a over the UTF-8 bytes: deterministic *across processes*, unlike
        // `Hasher`, whose per-process random seed made a game's placeholder tint
        // change on every launch (and made snapshots non-reproducible).
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let h = Double(hash % 360) / 360
        return Color(hue: h, saturation: 0.42, brightness: 0.55)
    }
}
