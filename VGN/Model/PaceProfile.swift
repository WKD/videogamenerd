import Foundation

/// The pace factor(s) everything *plans* with (PLAN §7b "Personal pace factor" + "Per-genre
/// pace"): a **global** factor plus the per-genre factors of the genres that qualified (≥ 10
/// plausible samples, shrunk toward the global one). A game plans with the mean of its
/// qualifying genres' factors, else the global factor (``factor(genreNames:)``).
///
/// It is the one value threaded through the grid (``LibraryFilter/paceFactor``), Play Next
/// (``TimeBracket/paceFactor``), the Vault scorer and Stats. Its SQL mirror is
/// `LibraryQuery.paceFactorSQL(_:)` — built from the same table, so the per-game factor is one
/// definition. The manual override is a ``uniform(_:)`` profile (no genre factors).
///
/// Genre factors are **quantized to 1/1024** (``quantize(_:)``) so the mean of any few of them is
/// computed exactly in binary floating point: SQLite's `AVG` and the Swift mirror then produce
/// the identical `Double`, whatever the summation order. The global factor needs no
/// quantization (it enters both sides as the same literal).
///
/// A float/integer literal is a uniform profile (`paceFactor: 1.3` ≡ `.uniform(1.3)`).
/// Foundation only.
struct PaceProfile: Hashable, Sendable, Codable {
    /// One qualifying genre's factor.
    struct Genre: Hashable, Sendable, Codable {
        /// `genres.id` — keys the SQL mirror.
        var id: Int64
        /// `genres.name` — keys the Swift mirror (the genre trait values, IGDB genre names).
        var name: String
        /// The shrunk, clamped, quantized factor.
        var factor: Double
        /// Plausible samples it rests on.
        var sampleCount: Int

        init(id: Int64, name: String, factor: Double, sampleCount: Int) {
            self.id = id
            self.name = name
            self.factor = factor
            self.sampleCount = sampleCount
        }
    }

    /// The factor of a game with no qualifying genre (and of every game under an override).
    var global: Double
    /// Qualifying genres, ascending ``Genre/id`` (deterministic SQL + equality).
    var genres: [Genre]

    init(global: Double, genres: [Genre] = []) {
        self.global = global
        self.genres = genres.sorted { $0.id < $1.id }
    }

    /// One factor for every game (the manual override, or a measurement with no qualifying genre).
    static func uniform(_ factor: Double) -> PaceProfile { PaceProfile(global: factor) }
    /// The advertised times (1.0×).
    static let neutral = PaceProfile.uniform(1.0)

    /// True when every game plans with ``global``.
    var isUniform: Bool { genres.isEmpty }

    /// True when every game plans with the advertised times.
    var isNeutral: Bool { isUniform && global == 1.0 }

    /// Quantize a genre factor to a multiple of 1/1024 (see the type doc).
    static func quantize(_ value: Double) -> Double { (value * 1024).rounded() / 1024 }

    // MARK: Per-game factor (the Swift mirror)

    /// The qualifying genres among `genreNames` (deduplicated, ascending id).
    func qualifyingGenres(genreNames: some Sequence<String>) -> [Genre] {
        guard !genres.isEmpty else { return [] }
        let names = Set(genreNames)
        return genres.filter { names.contains($0.name) }
    }

    /// The factor a game with these genres plans with: the mean of its qualifying genres'
    /// factors, else ``global``. Mirror of `LibraryQuery.paceFactorSQL`.
    func factor(genreNames: some Sequence<String>) -> Double {
        let q = qualifyingGenres(genreNames: genreNames)
        guard !q.isEmpty else { return global }
        return q.reduce(0.0) { $0 + $1.factor } / Double(q.count)
    }

    /// The factor for a game's genre **traits** (the `.genre` values of Play Next candidates and
    /// Vault entries).
    func factor(traits: [GameTrait]) -> Double {
        guard !genres.isEmpty else { return global }
        return factor(genreNames: traits.lazy.filter { $0.kind == .genre }.map(\.value))
    }

    /// What a game's factor rests on, for the inspector's "for you" line.
    enum Basis: Hashable, Sendable {
        /// One qualifying genre ("point-and-click pace 2.8×").
        case genre(String)
        /// Several qualifying genres, averaged ("adventure + puzzle pace 2.2×").
        case genres([String])
        /// The global factor ("your pace 1.8×").
        case global
    }

    func basis(genreNames: some Sequence<String>) -> Basis {
        let q = qualifyingGenres(genreNames: genreNames)
        switch q.count {
        case 0: return .global
        case 1: return .genre(q[0].name)
        default: return .genres(q.map(\.name).sorted())
        }
    }
}

extension PaceProfile: ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral {
    init(floatLiteral value: Double) { self.init(global: value) }
    init(integerLiteral value: Int) { self.init(global: Double(value)) }
}
