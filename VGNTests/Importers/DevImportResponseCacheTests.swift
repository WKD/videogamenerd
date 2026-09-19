#if DEBUG
import Foundation
import Testing
@testable import VGN

/// The development response cache (PLAN §13.5): write-before-use, read-first, per-account
/// folders, bodies only (no headers), a redacted index, and `wipe()`. Every test injects a
/// throwaway temp directory — **never** the real Application Support one.
///
/// "Absent in Release" is a *compile-time* guarantee: ``DevImportResponseCache`` and this
/// whole suite are wrapped in `#if DEBUG`, so neither the type nor its tests exist in a
/// Release build. That cannot be asserted at runtime from a DEBUG test host, so it is
/// enforced structurally by the `#if DEBUG` guard here and on the type.
@Suite struct DevImportResponseCacheTests {

    private func tempCache() -> (DevImportResponseCache, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vgn-devcache-\(UUID().uuidString)", isDirectory: true)
        return (DevImportResponseCache(root: root), root)
    }

    private func cleanup(_ root: URL) { try? FileManager.default.removeItem(at: root) }

    @Test func readFirstMissesBeforeAnyWrite() {
        let (cache, root) = tempCache(); defer { cleanup(root) }
        #expect(cache.read(source: "psn", account: .test, endpoint: "profile", paramsHash: "x") == nil)
    }

    @Test func writeBeforeUseThenReadReturnsExactBody() {
        let (cache, root) = tempCache(); defer { cleanup(root) }
        let body = Data(#"{"onlineId":"fake"}"#.utf8)
        cache.write(source: "psn", account: .test, endpoint: "profile", paramsHash: "h1",
                    requestURL: URL(string: "https://m.np.playstation.com/api/userProfile/v1/internal/users/me/profiles")!,
                    status: 200, body: body, itemCount: 1)
        let read = cache.read(source: "psn", account: .test, endpoint: "profile", paramsHash: "h1")
        #expect(read == body)   // bodies stored exactly as received
    }

    @Test func accountsAreKeptInSeparateFolders() {
        let (cache, root) = tempCache(); defer { cleanup(root) }
        let testBody = Data("TEST".utf8)
        let realBody = Data("REAL".utf8)
        let url = URL(string: "https://m.np.playstation.com/api/trophy/v1/users/me/trophyTitles?limit=10")!
        cache.write(source: "psn", account: .test, endpoint: "trophyTitles", paramsHash: "p",
                    requestURL: url, status: 200, body: testBody, itemCount: 10)
        cache.write(source: "psn", account: .real, endpoint: "trophyTitles", paramsHash: "p",
                    requestURL: url, status: 200, body: realBody, itemCount: 10)
        #expect(cache.read(source: "psn", account: .test, endpoint: "trophyTitles", paramsHash: "p") == testBody)
        #expect(cache.read(source: "psn", account: .real, endpoint: "trophyTitles", paramsHash: "p") == realBody)
        // Distinct on-disk folders.
        #expect(FileManager.default.fileExists(atPath:
            root.appendingPathComponent("psn/test/trophyTitles-p.json").path))
        #expect(FileManager.default.fileExists(atPath:
            root.appendingPathComponent("psn/real/trophyTitles-p.json").path))
    }

    @Test func indexRecordsUrlStatusCountAndNoHeaders() {
        let (cache, root) = tempCache(); defer { cleanup(root) }
        let url = URL(string: "https://web.np.playstation.com/api/graphql/v1/op?operationName=getPurchasedGameList")!
        cache.write(source: "psn", account: .test, endpoint: "purchases", paramsHash: "g",
                    requestURL: url, status: 200, body: Data("{}".utf8), itemCount: 3)
        let entries = cache.indexEntries()
        #expect(entries.count == 1)
        let e = entries[0]
        #expect(e.status == 200)
        #expect(e.itemCount == 3)
        #expect(e.account == "test")
        #expect(e.url.contains("getPurchasedGameList"))
        // The raw index.json must never contain header-y or token-y content.
        let raw = String(decoding: (try? Data(contentsOf: root.appendingPathComponent("index.json"))) ?? Data(), as: UTF8.self)
        #expect(!raw.lowercased().contains("authorization"))
        #expect(!raw.lowercased().contains("cookie"))
        #expect(!raw.lowercased().contains("npsso"))
    }

    @Test func tokenInUrlIsRedactedFromIndex() {
        let (cache, root) = tempCache(); defer { cleanup(root) }
        // A stray access_token in a URL must be scrubbed by the structural redactor.
        let url = URL(string: "https://example.com/x?access_token=abcdef1234567890abcdef1234567890")!
        cache.write(source: "psn", account: .real, endpoint: "profile", paramsHash: "z",
                    requestURL: url, status: 200, body: Data("{}".utf8), itemCount: 1)
        let raw = String(decoding: (try? Data(contentsOf: root.appendingPathComponent("index.json"))) ?? Data(), as: UTF8.self)
        #expect(!raw.contains("abcdef1234567890abcdef1234567890"))
    }

    @Test func wipeDeletesEverything() {
        let (cache, root) = tempCache(); defer { cleanup(root) }
        cache.write(source: "psn", account: .test, endpoint: "profile", paramsHash: "h",
                    requestURL: URL(string: "https://example.com")!, status: 200, body: Data("x".utf8), itemCount: 1)
        #expect(FileManager.default.fileExists(atPath: root.path))
        cache.wipe()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func paramsHashIsStableAcrossCalls() {
        #expect(DevImportResponseCache.paramsHash("limit=10&offset=0")
                == DevImportResponseCache.paramsHash("limit=10&offset=0"))
        #expect(DevImportResponseCache.paramsHash("limit=10")
                != DevImportResponseCache.paramsHash("limit=800"))
    }
}
#endif
