import Foundation

/// Resolves VGN's on-disk locations under `~/Library/Application Support/VGN/`
/// (CLAUDE.md on-disk layout). All the service dirs are injectable — tests pass a
/// temp root — but the defaults live here.
enum VGNAppSupport {
    /// `~/Library/Application Support/VGN/`, created on first access.
    static func rootDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("VGN", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `…/VGN/covers/` — permanent cover originals (library assets, PLAN §5.2).
    static func coversDirectory() throws -> URL { try subdirectory("covers") }

    /// `…/VGN/thumbs/` — pre-downsampled grid thumbnails.
    static func thumbsDirectory() throws -> URL { try subdirectory("thumbs") }

    /// `…/VGN/libretro-index/` — cached GitHub tree listings per libretro repo.
    static func libretroIndexDirectory() throws -> URL { try subdirectory("libretro-index") }

    private static func subdirectory(_ name: String) throws -> URL {
        let dir = try rootDirectory().appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
