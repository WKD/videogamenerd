import Foundation
import Testing
@testable import VGN

/// Pure open-panel path logic: resolving a picked file or the containing folder.
struct DeliciousFilePickerTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DLpick-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func resolvesADirectlyPickedFile() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Delicious Library Items.deliciouslibrary2")
        try Data("x".utf8).write(to: file)
        #expect(DeliciousFilePicker.resolve(file) == file)
    }

    @Test func resolvesAFileInsideAPickedFolder() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Delicious Library 2", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Delicious Library Items.deliciouslibrary2")
        try Data("x".utf8).write(to: file)
        let resolved = DeliciousFilePicker.resolve(folder)
        // Compare by resolved path (the temp dir is under the /var → /private/var symlink).
        #expect(resolved?.resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
    }

    @Test func rejectsAnUnrelatedFile() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: file)
        #expect(DeliciousFilePicker.resolve(file) == nil)
    }

    @Test func rejectsAFolderWithoutAStore() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(DeliciousFilePicker.resolve(dir) == nil)
    }
}
