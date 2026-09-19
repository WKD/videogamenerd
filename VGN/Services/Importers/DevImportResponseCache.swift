#if DEBUG
import Foundation

/// The **development** response cache of PLAN §13.5 — a build-time, on-disk store that
/// makes re-running any live build step (a test recording, a crashed session, a repeated
/// probe) cost **zero requests**. It is *not* the runtime cache (that is `import_cache`
/// inside `vgn.sqlite`, §13.2); it exists only during the gated live build so a valid
/// response, once seen, is never fetched twice.
///
/// Layout (PLAN §13.5, extended with the brief's per-account folders):
/// ```
/// <root>/<source>/<account-label>/<endpoint>-<params-hash>.json     ← the body, as received
/// <root>/index.json                                                 ← url (no tokens), status, date, count
/// ```
/// Contract:
///  - **write-before-use / read-first**: the client writes a valid body here *before*
///    anything else is done with it, and reads here *before* the network.
///  - **bodies stored as received; headers are NEVER stored** — only the body bytes.
///  - **per-account folders** (`test`, `real`) keep the build account and the real
///    account apart (PLAN §13.3 "Accounts for the build").
///  - **no tokens ever**: the index URL passes through ``ImportRedactor`` (the NPSSO,
///    the OAuth code and the access/refresh tokens live in headers, never the URL, and
///    are scrubbed anyway). Account ids are kept **only** here, scrubbed from fixtures.
///  - the directory is **injected** so tests use a temp dir, **never** the real
///    Application Support one.
///  - `wipe()` deletes everything (end of milestone / on request).
///
/// **This whole type is `#if DEBUG`**, so it does not exist in a Release build (a test
/// proves the symbol is absent there). It is Foundation-only and best-effort: every file
/// operation is wrapped, and a failure degrades to "no cache", never a thrown build error.
struct DevImportResponseCache: Sendable {
    /// Which build account a folder belongs to (PLAN §13.3).
    enum Account: String, Sendable, CaseIterable {
        case test
        case real
        var folder: String { rawValue }
    }

    /// One index entry — everything safe to keep for the build log (PLAN §13.5). No body,
    /// no headers, no tokens.
    struct IndexEntry: Codable, Sendable, Hashable {
        var source: String
        var account: String
        var endpoint: String
        var paramsHash: String
        var url: String
        var status: Int
        var date: Date
        var itemCount: Int
        var file: String
    }

    /// The base `dev-import-cache` directory. **Injected** — tests pass a temp dir.
    let root: URL
    private let redactor: ImportRedactor

    init(root: URL, redactor: ImportRedactor = .structural) {
        self.root = root
        self.redactor = redactor
    }

    /// The real on-disk location (`~/Library/Application Support/VGN/dev-import-cache`).
    /// Only the live build wiring uses this; **tests must never** — they inject a temp dir.
    static func defaultRoot() throws -> URL {
        try AppPaths.supportDirectory().appendingPathComponent("dev-import-cache", isDirectory: true)
    }

    // MARK: - Read-first

    /// The cached body for `(source, account, endpoint, params)`, or nil. Read **before**
    /// the network so a re-run costs zero requests.
    func read(source: String, account: Account, endpoint: String, paramsHash: String) -> Data? {
        let url = bodyURL(source: source, account: account, endpoint: endpoint, paramsHash: paramsHash)
        return try? Data(contentsOf: url)
    }

    // MARK: - Write-before-use

    /// Persist a **validated** body, updating the index. Called *before* anything else is
    /// done with the response. `requestURL` is stored only after redaction; **headers are
    /// never passed in and never stored**. Best-effort — a failure is swallowed.
    func write(source: String, account: Account, endpoint: String, paramsHash: String,
               requestURL: URL, status: Int, body: Data, itemCount: Int) {
        let bodyURL = bodyURL(source: source, account: account, endpoint: endpoint, paramsHash: paramsHash)
        do {
            try FileManager.default.createDirectory(
                at: bodyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: bodyURL)
        } catch {
            return   // best-effort dev tool: a write failure just means "no dev cache".
        }
        let entry = IndexEntry(
            source: source, account: account.folder, endpoint: endpoint, paramsHash: paramsHash,
            url: redactor.redact(requestURL.absoluteString), status: status, date: Date(),
            itemCount: itemCount, file: relativePath(source: source, account: account,
                                                     endpoint: endpoint, paramsHash: paramsHash))
        updateIndex(with: entry)
    }

    // MARK: - Index

    /// Every recorded entry, newest first (diagnostics / tests).
    func indexEntries() -> [IndexEntry] {
        guard let data = try? Data(contentsOf: indexURL),
              let entries = try? JSONDecoder.dev.decode([IndexEntry].self, from: data) else { return [] }
        return entries
    }

    private func updateIndex(with entry: IndexEntry) {
        var entries = indexEntries().filter {
            !($0.source == entry.source && $0.account == entry.account
              && $0.endpoint == entry.endpoint && $0.paramsHash == entry.paramsHash)
        }
        entries.insert(entry, at: 0)
        guard let data = try? JSONEncoder.dev.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: indexURL)
    }

    // MARK: - Wipe

    /// Delete the whole dev cache (end of milestone / on request).
    func wipe() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Paths

    private var indexURL: URL { root.appendingPathComponent("index.json") }

    private func bodyURL(source: String, account: Account, endpoint: String, paramsHash: String) -> URL {
        root.appendingPathComponent(relativePath(source: source, account: account,
                                                 endpoint: endpoint, paramsHash: paramsHash))
    }

    private func relativePath(source: String, account: Account, endpoint: String, paramsHash: String) -> String {
        "\(sanitize(source))/\(account.folder)/\(sanitize(endpoint))-\(paramsHash).json"
    }

    /// Filename-safe: keep alphanumerics, `-`, `_`; everything else → `_`.
    private func sanitize(_ s: String) -> String {
        String(s.map { ch in
            (ch.isLetter || ch.isNumber || ch == "-" || ch == "_") ? ch : "_"
        })
    }

    /// A stable, filename-safe hash of canonical params (deterministic across runs, unlike
    /// `Hasher`, so a re-run finds the same file). FNV-1a 64-bit → hex.
    static func paramsHash(_ canonical: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in canonical.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

private extension JSONEncoder {
    static var dev: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

private extension JSONDecoder {
    static var dev: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
#endif
