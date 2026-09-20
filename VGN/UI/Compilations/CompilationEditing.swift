import Foundation

/// The store-write seam the compilation editor drives (PLAN §5.1/§8). Kept as a
/// small protocol so ``CompilationEditorModel`` is unit-testable with a fake.
/// ``LibraryStore`` conforms directly (its method names already match).
protocol CompilationWriting: Sendable {
    func compilationProduct(id productID: Int64) async throws -> CompilationProductInfo?
    @discardableResult
    func addCompilationMember(productID: Int64, _ member: CompilationMemberDraft) async throws -> AddOutcome
    func addExistingGameToCompilation(productID: Int64, gameID: Int64, position: Int) async throws
    @discardableResult
    func removeCompilationMember(productID: Int64, gameID: Int64, confirmOrphanDelete: Bool) async throws -> WriteOutcome
    /// Remove a member and capture the undo snapshot (so the editor can register a
    /// "Remove from Compilation" undo step). `LibraryStore` provides it.
    func removeCompilationMemberCapturingUndo(
        productID: Int64, gameID: Int64, confirmOrphanDelete: Bool) async throws -> (outcome: WriteOutcome, undo: ReconcileUndo?)
    /// Restore a captured reconcile snapshot (undo).
    func restoreReconcile(_ undo: ReconcileUndo) async throws
    func reorderCompilationMembers(productID: Int64, orderedGameIDs: [Int64]) async throws
    func renameProduct(productID: Int64, title: String?) async throws
    func updateProductDetails(
        productID: Int64, platformID: String?, format: ProductFormat?,
        edition: String??, region: String??) async throws
}

extension LibraryStore: CompilationWriting {}
