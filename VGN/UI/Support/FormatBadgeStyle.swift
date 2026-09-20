import SwiftUI

/// The tint colour paired with each format's shared glyph (``FormatBadgeKind/symbolName``),
/// so the grid badges and any other format icon agree on colour as well as shape (D3, wave 19).
/// Distinct and accessible: physical blue, digital teal, ROM purple. PS Plus is drawn from the
/// owner's `PSPlusBadge` asset, so it has no tint here.
extension FormatBadgeKind {
    var tint: Color {
        switch self {
        case .physical: return .blue
        case .digital:  return .teal
        case .rom:      return .purple
        case .psPlus:   return .yellow   // unused: PS Plus draws the asset, not a tinted circle
        }
    }
}
