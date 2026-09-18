import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import VGN

/// A `CoverProvider` returning canned candidates keyed by the query title.
struct StubCoverProvider: CoverProvider {
    let id: String
    let candidatesByTitle: @Sendable (CoverQuery) -> [CoverCandidate]

    init(id: String = "stub", _ candidates: @escaping @Sendable (CoverQuery) -> [CoverCandidate]) {
        self.id = id
        self.candidatesByTitle = candidates
    }

    func candidates(for query: CoverQuery) async -> [CoverCandidate] {
        candidatesByTitle(query)
    }
}

enum TestImage {
    /// A solid-colour PNG of the given pixel size, as bytes.
    static func png(width: Int = 400, height: Int = 533) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
