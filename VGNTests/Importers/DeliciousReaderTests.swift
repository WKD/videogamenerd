import Foundation
import ImageIO
import Testing
@testable import VGN

/// Reader: entity-by-name resolution, VideoGame-only filtering, epoch conversion,
/// read-only immutability, validation errors, and cover decode.
struct DeliciousReaderTests {

    /// Seconds since the Core Data reference date (2001-01-01) for a Y-M-D in UTC.
    private static func seconds(year: Int, month: Int, day: Int) -> Double {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let date = c.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        return date.timeIntervalSinceReferenceDate
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func readsOnlyVideoGamesOnTheMediumEntity() throws {
        let url = try DeliciousTestStore.make([
            .init(uuid: "a", title: "Game A", platforms: ["PlayStation 3"]),
            .init(uuid: "b", title: "Game B", platforms: ["Nintendo Wii"]),
        ])
        defer { cleanup(url) }
        let games = try DeliciousLibraryReader(url: url).readGames()
        // Two VideoGame rows; the movie, book and recommendation noise are skipped even
        // though Medium is entity 42 here (proves name resolution, not a hard-coded 6).
        #expect(games.count == 2)
        #expect(Set(games.map(\.uuid)) == ["a", "b"])
    }

    @Test func convertsCoreDataEpoch() throws {
        let pub = Self.seconds(year: 2009, month: 6, day: 15)
        let created = Self.seconds(year: 2011, month: 3, day: 2)
        let url = try DeliciousTestStore.make([
            .init(uuid: "a", title: "Dated", platforms: ["PC"],
                  publishSeconds: pub, creationSeconds: created),
        ])
        defer { cleanup(url) }
        let game = try #require(try DeliciousLibraryReader(url: url).readGames().first)
        #expect(game.publishYear == 2009)
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        #expect(game.catalogedAt.map { c.component(.year, from: $0) } == 2011)
    }

    @Test func carriesFieldsAndLoanFlag() throws {
        let url = try DeliciousTestStore.make([
            .init(uuid: "loaned", title: "Lent Game", platforms: ["PlayStation 3", "Windows XP"],
                  ean: "3475132453", asin: "B000XYZ", editions: "Collector's Edition",
                  country: "gb", loanPK: 55),
        ])
        defer { cleanup(url) }
        let game = try #require(try DeliciousLibraryReader(url: url).readGames().first)
        #expect(game.platforms == ["PlayStation 3", "Windows XP"])
        #expect(game.ean == "3475132453")
        #expect(game.asin == "B000XYZ")
        #expect(game.editions == "Collector's Edition")
        #expect(game.country == "gb")
        #expect(game.wasLoaned == true)
    }

    @Test func readingDoesNotMutateTheFile() throws {
        let url = try DeliciousTestStore.make([
            .init(uuid: "a", title: "Game A", platforms: ["PlayStation 3"]),
        ])
        defer { cleanup(url) }
        let fm = FileManager.default
        let before = try fm.attributesOfItem(atPath: url.path)
        let sizeBefore = before[.size] as? Int
        let mtimeBefore = before[.modificationDate] as? Date

        _ = try DeliciousLibraryReader(url: url).readGames()
        _ = try DeliciousLibraryReader(url: url).coverJPEGData(forCoverImagePKs: [1, 2])

        let after = try fm.attributesOfItem(atPath: url.path)
        #expect(after[.size] as? Int == sizeBefore)
        #expect(after[.modificationDate] as? Date == mtimeBefore)
        // No rollback-journal / WAL sidecar was created next to the file.
        #expect(!fm.fileExists(atPath: url.path + "-wal"))
        #expect(!fm.fileExists(atPath: url.path + "-journal"))
    }

    @Test func rejectsForeignFile() throws {
        let url = try DeliciousTestStore.makeForeign()
        defer { cleanup(url) }
        #expect(throws: DeliciousImportError.notDeliciousFile) {
            _ = try DeliciousLibraryReader(url: url).readGames()
        }
    }

    @Test func rejectsUnsupportedVersion() throws {
        let url = try DeliciousTestStore.makeUnsupported()
        defer { cleanup(url) }
        #expect(throws: DeliciousImportError.unsupportedVersion) {
            _ = try DeliciousLibraryReader(url: url).readGames()
        }
    }

    @Test func rejectsStoreWithNoVideoGames() throws {
        let url = try DeliciousTestStore.make([], includeNoise: true)   // only movie/book/rec
        defer { cleanup(url) }
        #expect(throws: DeliciousImportError.noVideoGames) {
            _ = try DeliciousLibraryReader(url: url).readGames()
        }
    }

    @Test func extractsAndDecodesCoverBlob() throws {
        let jpeg = DeliciousTestStore.tinyJPEG()
        let url = try DeliciousTestStore.make([
            .init(uuid: "c", title: "Cover Game", platforms: ["PlayStation 3"],
                  coverPK: 777, coverJPEG: jpeg),
        ])
        defer { cleanup(url) }
        let reader = DeliciousLibraryReader(url: url)
        let game = try #require(try reader.readGames().first)
        #expect(game.coverImagePK == 777)
        let blobs = try reader.coverJPEGData(forCoverImagePKs: [777])
        let data = try #require(blobs[777])
        // Decodes cleanly through ImageIO.
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
    }
}
