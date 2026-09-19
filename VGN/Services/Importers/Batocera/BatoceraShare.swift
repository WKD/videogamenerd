import Foundation

/// One system's `gamelist.xml` located on the share, with the facts change-detection needs
/// (PLAN §15 — "compare the modification date … re-read only the systems that changed").
struct BatoceraSystemFile: Sendable, Hashable, Identifiable {
    /// Batocera system folder name (`snes`, `megadrive`…).
    var system: String
    var gamelistURL: URL
    var modificationDate: Date?
    var fileSize: Int64

    var id: String { system }
}

/// Locates systems and their `gamelist.xml` files under a Batocera share root, **read-only**
/// (PLAN §15). Never writes, creates, renames or deletes anything under the share. The root
/// may be the share itself (`/Volumes/share`, containing `roms/`) or the roms folder
/// directly (`/Volumes/share/roms`) — ``romsFolder(under:)`` handles both.
struct BatoceraShare: Sendable {
    /// The roms folder holding `<system>/gamelist.xml` directories.
    let romsRoot: URL

    /// Build from a user-chosen root, resolving the roms folder. Throws
    /// ``BatoceraError/shareNotMounted`` / ``BatoceraError/noRomsFolder``.
    init(root: URL) throws {
        self.romsRoot = try Self.romsFolder(under: root)
    }

    /// Build directly from a known roms folder (used by ``BatoceraSync`` and tests).
    init(romsRoot: URL) {
        self.romsRoot = romsRoot
    }

    /// Resolve the roms folder under a chosen root. Accepts a share root (with a `roms`
    /// child) or the roms folder itself.
    static func romsFolder(under root: URL) throws -> URL {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw BatoceraError.shareNotMounted(path: root.path)
        }
        // A `roms` child → that is the folder.
        let romsChild = root.appendingPathComponent("roms", isDirectory: true)
        if fm.fileExists(atPath: romsChild.path, isDirectory: &isDir), isDir.boolValue {
            return romsChild
        }
        // Else the root itself must already contain system folders with gamelists.
        if root.lastPathComponent == "roms" || Self.containsAnyGamelist(root) {
            return root
        }
        throw BatoceraError.noRomsFolder(path: root.path)
    }

    private static func containsAnyGamelist(_ folder: URL) -> Bool {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles]) else {
            return false
        }
        for child in children {
            var isDir: ObjCBool = false
            let gl = child.appendingPathComponent("gamelist.xml")
            if fm.fileExists(atPath: gl.path, isDirectory: &isDir), !isDir.boolValue { return true }
        }
        return false
    }

    /// Every system folder that has a `gamelist.xml`, with its mtime + size. The mount
    /// disappearing between construction and this call surfaces as `.shareNotMounted`.
    /// The result is sorted by system name for stable reporting.
    func systemFiles() throws -> [BatoceraSystemFile] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: romsRoot, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            throw BatoceraError.shareNotMounted(path: romsRoot.path)
        }
        var out: [BatoceraSystemFile] = []
        for dir in children {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let gl = dir.appendingPathComponent("gamelist.xml")
            guard fm.fileExists(atPath: gl.path) else { continue }
            let attrs = try? fm.attributesOfItem(atPath: gl.path)
            let mtime = attrs?[.modificationDate] as? Date
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            out.append(BatoceraSystemFile(system: dir.lastPathComponent, gamelistURL: gl,
                                          modificationDate: mtime, fileSize: size))
        }
        return out.sorted { $0.system < $1.system }
    }

    /// Whether the share root looks reachable right now (a cheap `stat`), so a sync can
    /// return `.shareUnavailable` without an error storm when the NAS is asleep.
    var isReachable: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: romsRoot.path, isDirectory: &isDir) && isDir.boolValue
    }
}
