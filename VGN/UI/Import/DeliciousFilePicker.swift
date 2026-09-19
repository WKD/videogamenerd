import Foundation

/// Pure helpers for choosing a Delicious Library file (PLAN §5.5). Kept separate from the
/// `NSOpenPanel` so the resolution logic is unit-testable: the owner may pick the
/// `.deliciouslibrary2` file directly, or the "Delicious Library 2" **folder** that
/// contains it (the default install location).
enum DeliciousFilePicker {
    /// The file extension of a Delicious Library 2 database.
    static let fileExtension = "deliciouslibrary2"
    /// `AppPreferences.defaults` key for the last folder the owner picked from.
    static let lastFolderKey = "delicious.lastFolder"

    /// Resolve a picked URL to the actual `.deliciouslibrary2` file, or nil if none is
    /// found. A file with the right extension is returned as-is; a directory is searched
    /// (shallow) for the first `.deliciouslibrary2` inside it.
    static func resolve(_ url: URL, fileManager: FileManager = .default) -> URL? {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue {
            return url.pathExtension.lowercased() == fileExtension ? url : nil
        }
        // A directory (e.g. the "Delicious Library 2" folder): find the store inside.
        guard let contents = try? fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil) else { return nil }
        return contents.first { $0.pathExtension.lowercased() == fileExtension }
    }
}
