import Foundation

/// Canonical on-disk locations for VGN runtime state, all under
/// `~/Library/Application Support/VGN/` (PLAN §9, EXECUTION "App support dir").
enum AppPaths {
    /// `VGN` for the default profile, `VGN-<name>` for `-VGNProfile <name>` (an isolated
    /// library for risky experiments such as the first live PSN steps).
    static let folderName = AppProfile.folderName(base: "VGN", profile: AppProfile.name)

    /// `~/Library/Application Support/VGN/`, created on demand.
    static func supportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let url = base.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The live SQLite database file.
    static func databaseURL() throws -> URL {
        try supportDirectory().appendingPathComponent("vgn.sqlite")
    }

    /// Permanent cover-art store (library assets, not cache — PLAN §5.2).
    static func coversDirectory() throws -> URL {
        try subdirectory("covers")
    }

    /// Pre-downsampled grid thumbnails (PLAN §9).
    static func thumbsDirectory() throws -> URL {
        try subdirectory("thumbs")
    }

    /// Launch snapshots live here (PLAN §9 Safety).
    static func backupsDirectory() throws -> URL {
        try subdirectory("backups")
    }

    private static func subdirectory(_ name: String) throws -> URL {
        let url = try supportDirectory().appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
