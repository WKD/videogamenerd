#if DEBUG
import Foundation

/// A no-database ``CompilationWriting`` that keeps its members in memory, so the
/// compilation editor's `#Preview` works without GRDB.
actor PreviewCompilationWriter: CompilationWriting {
    private var product: CompilationProductInfo
    private var nextID: Int64

    init(_ product: CompilationProductInfo) {
        self.product = product
        self.nextID = (product.members.map(\.gameID).max() ?? 0) + 1
    }

    func compilationProduct(id productID: Int64) async throws -> CompilationProductInfo? { product }

    func addCompilationMember(productID: Int64, _ member: CompilationMemberDraft) async throws -> AddOutcome {
        let id = nextID; nextID += 1
        product.members.append(CompilationMemberInfo(
            gameID: id, title: member.title, position: product.members.count, year: member.year))
        return .created(gameID: id)
    }

    func addExistingGameToCompilation(productID: Int64, gameID: Int64, position: Int) async throws {
        product.members.append(CompilationMemberInfo(gameID: gameID, title: "Reused", position: position))
    }

    func removeCompilationMember(productID: Int64, gameID: Int64, confirmOrphanDelete: Bool) async throws -> WriteOutcome {
        product.members.removeAll { $0.gameID == gameID }
        return .ok
    }

    func removeCompilationMemberCapturingUndo(productID: Int64, gameID: Int64, confirmOrphanDelete: Bool) async throws -> (outcome: WriteOutcome, undo: ReconcileUndo?) {
        product.members.removeAll { $0.gameID == gameID }
        return (.ok, nil)   // preview: no real snapshot
    }

    func restoreReconcile(_ undo: ReconcileUndo) async throws {}

    func reorderCompilationMembers(productID: Int64, orderedGameIDs: [Int64]) async throws {
        product.members.sort { a, b in
            (orderedGameIDs.firstIndex(of: a.gameID) ?? 0) < (orderedGameIDs.firstIndex(of: b.gameID) ?? 0)
        }
    }

    func renameProduct(productID: Int64, title: String?) async throws { product.title = title }

    func updateProductDetails(
        productID: Int64, platformID: String?, format: ProductFormat?,
        edition: String??, region: String??
    ) async throws {
        if let platformID { product.platformID = platformID }
        if let format { product.format = format }
        if case let .some(v) = edition { product.edition = v }
        if case let .some(v) = region { product.region = v }
    }
}

enum PreviewCompilationEditor {
    @MainActor
    static func mgsLegacy() -> CompilationEditorModel {
        let titles = ["Metal Gear Solid", "Metal Gear Solid 2", "Metal Gear Solid 3",
                      "Metal Gear Solid 4", "Peace Walker"]
        let members = titles.enumerated().map { i, t in
            CompilationMemberInfo(gameID: Int64(i + 1), title: t, position: i,
                                  year: 1998 + i, played: i < 2, tierLetter: i == 0 ? "S" : nil)
        }
        let product = CompilationProductInfo(
            id: 1, title: "Metal Gear Solid: The Legacy Collection", platformID: "ps3",
            format: .physical, igdbID: 42, members: members)
        return CompilationEditorModel(
            productID: 1, writer: PreviewCompilationWriter(product),
            catalog: OfflineCatalogSearcher(),
            localSearch: { _ in [] })
    }
}
#endif
