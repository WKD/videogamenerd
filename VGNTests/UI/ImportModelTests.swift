import Foundation
import Testing
@testable import VGN

/// The PhotoScanModel state machine, review defaults, edits and keyboard intents, all
/// driven by fakes (no process, no network).
@MainActor
@Suite(.serialized)
struct ImportModelTests {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name).jpg") }

    // MARK: - Input queue

    @Test("Enqueue filters unsupported files and de-dupes")
    func enqueueFilters() {
        let model = PhotoScanModel(environment: ImportEnv.make())
        model.enqueue([url("IMG_1"), URL(fileURLWithPath: "/tmp/notes.txt"), url("IMG_1")])
        #expect(model.jobs.count == 1)
        #expect(model.jobs.first?.name == "IMG_1")
        #expect(model.canStart)
    }

    // MARK: - State machine + progress

    @Test("A photo runs queued → recognising → ready with per-tile rows")
    func stateMachine() async {
        let scanner = FakePhotoScanner(defaultPlan: .init(tileCount: 3, items: [
            ImportFixtures.item(id: 0, photo: "IMG_1", title: "Bloodborne", platform: "ps4", igdbID: 1, bucket: .confident)
        ]))
        let model = PhotoScanModel(environment: ImportEnv.make(scanner: scanner))
        model.enqueue([url("IMG_1")])
        model.start()
        await waitFor { model.presentation == .review }

        #expect(model.presentation == .review)
        #expect(model.jobs[0].phase == .ready)
        #expect(model.jobs[0].tiles.count == 3)
        #expect(model.jobs[0].tiles.allSatisfy { $0.state.rank == 2 })
        #expect(model.jobs[0].costUSD > 0)
        #expect(model.reviewRows.count == 1)
        #expect(model.activeEngine == .claude)
    }

    @Test("A CLI error preflight falls back to Vision with a visible note")
    func visionFallback() async {
        let scanner = FakePhotoScanner(preflight: .failure(.notLoggedIn(detail: "x")))
        let model = PhotoScanModel(environment: ImportEnv.make(scanner: scanner))
        model.enqueue([url("IMG_1")])
        model.start()
        await waitFor { model.presentation == .review }

        #expect(model.activeEngine == .vision)
        #expect(model.fallbackNote != nil)
        #expect(model.preflightError == .notLoggedIn(detail: "x"))
        #expect(scanner.enginesUsed == [.vision])
    }

    @Test("Vision-only preference never preflights the CLI")
    func visionOnly() async {
        let prefs = InMemoryPhotoScanPreferences(PhotoScanSettings(enginePreference: .visionOnly))
        let scanner = FakePhotoScanner()
        let model = PhotoScanModel(environment: ImportEnv.make(scanner: scanner, preferences: prefs))
        model.enqueue([url("IMG_1")])
        model.start()
        await waitFor { model.presentation == .review }

        #expect(model.activeEngine == .vision)
        #expect(scanner.preflightCount == 0)
        #expect(model.fallbackNote == nil)
    }

    @Test("A scan failure marks the photo failed but still reaches review")
    func scanFailure() async {
        let scanner = FakePhotoScanner()
        scanner.setPlan(.init(tileCount: 2, error: .timedOut(after: 120)), for: "IMG_1")
        let model = PhotoScanModel(environment: ImportEnv.make(scanner: scanner))
        model.enqueue([url("IMG_1")])
        model.start()
        await waitFor { model.presentation == .review }

        if case .failed = model.jobs[0].phase {} else { Issue.record("expected failed phase, got \(model.jobs[0].phase)") }
    }

    @Test("Cancel all stops a delayed run and marks jobs cancelled")
    func cancelAll() async {
        let scanner = FakePhotoScanner(defaultPlan: .init(tileCount: 2, delay: .seconds(30)))
        let model = PhotoScanModel(environment: ImportEnv.make(scanner: scanner))
        model.enqueue([url("IMG_1"), url("IMG_2")])
        model.start()
        await waitFor { model.jobs.contains { $0.phase == .recognizing || $0.phase == .tiling } }
        model.cancelAll()
        await waitFor { model.presentation == .review }
        #expect(model.jobs.allSatisfy { $0.phase == .cancelled })
    }

    // MARK: - Review defaults per bucket + already-in-library

    @Test("Review defaults: confident/plausible included, none & already-in-library off")
    func reviewDefaults() async {
        let scanner = FakePhotoScanner(defaultPlan: .init(tileCount: 1, items: [
            ImportFixtures.item(id: 0, photo: "IMG_1", title: "Bloodborne", platform: "ps4", igdbID: 1, bucket: .confident),
            ImportFixtures.item(id: 1, photo: "IMG_1", title: "Nioh", platform: "ps4", igdbID: 2, bucket: .plausible, x: 1400),
            ImportFixtures.item(id: 2, photo: "IMG_1", title: "God of W…", platform: "ps4", igdbID: nil, bucket: .none, x: 1800),
            ImportFixtures.item(id: 3, photo: "IMG_1", title: "Returnal", platform: "ps5", igdbID: 5, bucket: .confident, x: 2200),
        ]))
        // The pipeline greys out duplicates via `isInLibrary`; Returnal (igdb 5) is owned.
        let model = PhotoScanModel(environment: ImportEnv.make(scanner: scanner, isInLibrary: { igdbID, _ in igdbID == 5 }))
        model.enqueue([url("IMG_1")])
        model.start()
        await waitFor { model.presentation == .review }

        let byTitle = Dictionary(uniqueKeysWithValues: model.reviewRows.map { ($0.printedTitle, $0) })
        #expect(byTitle["Bloodborne"]?.include == true)
        #expect(byTitle["Nioh"]?.include == true)
        #expect(byTitle["God of W…"]?.include == false)
        #expect(byTitle["Returnal"]?.include == false)          // already in library → off
        #expect(byTitle["Returnal"]?.alreadyInLibrary == true)
        #expect(byTitle["Returnal"]?.alreadyInLibraryLabel != nil)
        // Grouped confident → plausible → none.
        #expect(model.reviewRows.map(\.bucket.order) == model.reviewRows.map(\.bucket.order).sorted())
    }

    // MARK: - Row edits

    @Test("Row edits: platform, format, ignore, and choosing an alternative")
    func rowEdits() async {
        let alt = ScanMatch(igdbID: 99, name: "Nioh 2", releaseYear: 2020, coverImageID: "c", platformSlugs: ["ps4"], score: 0.95, matchedName: "Nioh 2")
        let scanner = FakePhotoScanner(defaultPlan: .init(tileCount: 1, items: [
            ImportFixtures.item(id: 0, photo: "IMG_1", title: "Nioh", platform: "ps4", igdbID: 2, bucket: .plausible, alternatives: [alt])
        ]))
        let model = PhotoScanModel(environment: ImportEnv.make(scanner: scanner))
        model.enqueue([url("IMG_1")])
        model.start()
        await waitFor { model.presentation == .review }
        let id = model.reviewRows[0].id

        model.setPlatform("ps5", rowID: id)
        model.setFormat(.digital, rowID: id)
        model.togglePlayed(rowID: id)
        #expect(model.reviewRows[0].platformSlug == "ps5")
        #expect(model.reviewRows[0].format == .digital)
        #expect(model.reviewRows[0].played == true)

        model.chooseMatch(alt, rowID: id)
        #expect(model.reviewRows[0].selectedMatch?.igdbID == 99)
        #expect(model.reviewRows[0].bucket == .confident)

        model.ignoreRow(id)
        #expect(model.reviewRows[0].ignored == true)
        #expect(model.reviewRows[0].isCommittable == false)
    }

    @Test("Inline IGDB search choice affirms the row")
    func inlineSearch() async {
        let searcher = FakeScanSearcher(results: [ImportFixtures.searchResult(id: 77, name: "Sekiro")])
        let scanner = FakePhotoScanner(defaultPlan: .init(tileCount: 1, items: [
            ImportFixtures.item(id: 0, photo: "IMG_1", title: "…IE TWICE", platform: "ps4", igdbID: nil, bucket: .none)
        ]))
        let model = PhotoScanModel(environment: ImportEnv.make(scanner: scanner, searcher: searcher))
        model.enqueue([url("IMG_1")])
        model.start()
        await waitFor { model.presentation == .review }
        let id = model.reviewRows[0].id

        let results = await model.searchIGDB("Sekiro", rowID: id)
        #expect(results.count == 1)
        model.chooseSearchResult(results[0], rowID: id)
        #expect(model.reviewRows[0].selectedMatch?.igdbID == 77)
        #expect(model.reviewRows[0].bucket == .confident)
        #expect(model.reviewRows[0].include == true)
    }

    @Test("Quick Add hand-off passes the printed title")
    func quickAddHandoff() async {
        var handed: String?
        let scanner = FakePhotoScanner(defaultPlan: .init(tileCount: 1, items: [
            ImportFixtures.item(id: 0, photo: "IMG_1", title: "Goodbye Deponia", platform: "ps4", igdbID: nil, bucket: .none)
        ]))
        let model = PhotoScanModel(environment: ImportEnv.make(scanner: scanner, onQuickAdd: { handed = $0 }))
        model.enqueue([url("IMG_1")])
        model.start()
        await waitFor { model.presentation == .review }
        model.handToQuickAdd(rowID: model.reviewRows[0].id)
        #expect(handed == "Goodbye Deponia")
    }

    // MARK: - Keyboard intents

    @Test("Keyboard intents: move, toggle include/played, select-all, bucket jump")
    func keyboard() async {
        let scanner = FakePhotoScanner(defaultPlan: .init(tileCount: 1, items: [
            ImportFixtures.item(id: 0, photo: "IMG_1", title: "AAA", platform: "ps4", igdbID: 1, bucket: .confident),
            ImportFixtures.item(id: 1, photo: "IMG_1", title: "BBB", platform: "ps4", igdbID: 2, bucket: .none, x: 1500),
        ]))
        let model = PhotoScanModel(environment: ImportEnv.make(scanner: scanner))
        model.enqueue([url("IMG_1")])
        model.start()
        await waitFor { model.presentation == .review }

        #expect(model.selectedRowID == model.reviewRows[0].id)
        model.moveSelection(by: 1)
        #expect(model.selectedIndex == 1)
        model.moveSelection(by: 5)   // clamps
        #expect(model.selectedIndex == 1)

        // Toggle include on the selected (none-bucket) row.
        model.toggleIncludeSelected()
        #expect(model.reviewRows[1].include == true)
        // Played on selected.
        model.togglePlayedSelected()
        #expect(model.reviewRows[1].played == true)

        // Bucket jump from none (index 1) up to confident (index 0).
        model.jumpBucket(-1)
        #expect(model.reviewRows[model.selectedIndex!].bucket == .confident)

        model.selectAllIncludable()
        #expect(model.reviewRows.allSatisfy { $0.include })
    }

    // MARK: - Commit + summary

    @Test("Commit builds photo-sourced drafts and reports a summary")
    func commitSummary() async {
        let committer = FakeCommitter()
        committer.outcomes = [.created(gameID: 10), .created(gameID: 11), .addedCopy(gameID: 12), .alreadyPresent(gameID: 13)]
        let scanner = FakePhotoScanner(defaultPlan: .init(tileCount: 1, items: [
            ImportFixtures.item(id: 0, photo: "IMG_1", title: "Bloodborne", platform: "ps4", igdbID: 1, bucket: .confident),
            ImportFixtures.item(id: 1, photo: "IMG_1", title: "Nioh", platform: "ps4", igdbID: 2, bucket: .plausible, x: 1500),
        ]))
        var libraryChanged = false
        let model = PhotoScanModel(environment: ImportEnv.make(scanner: scanner, committer: committer, onLibraryChanged: { libraryChanged = true }))
        model.enqueue([url("IMG_1")])
        model.start()
        await waitFor { model.presentation == .review }

        #expect(model.committableCount == 2)
        #expect(model.commitButtonTitle == "Add 2 games")
        model.commit()
        await waitFor { model.presentation == .committed }

        #expect(committer.recordedSingles.count == 2)
        #expect(committer.recordedSingles.allSatisfy { $0.source == .photo && $0.owned })
        #expect(libraryChanged)
        #expect(model.summary?.message == "2 added · 1 copy added to existing games · 1 already present")
    }

    @Test("A commit failure surfaces an error and stays on the review sheet")
    func commitFailure() async {
        struct Boom: Error {}
        let committer = FakeCommitter()
        committer.error = Boom()
        let scanner = FakePhotoScanner(defaultPlan: .init(tileCount: 1, items: [
            ImportFixtures.item(id: 0, photo: "IMG_1", title: "Bloodborne", platform: "ps4", igdbID: 1, bucket: .confident)
        ]))
        let model = PhotoScanModel(environment: ImportEnv.make(scanner: scanner, committer: committer))
        model.enqueue([url("IMG_1")])
        model.start()
        await waitFor { model.presentation == .review }
        model.commit()
        await waitFor { model.commitError != nil }
        #expect(model.presentation == .review)
        #expect(model.summary == nil)
    }

    @Test("A compilation row commits via addCompilation with fetched members")
    func compilationCommit() async {
        let committer = FakeCommitter()
        let searcher = FakeScanSearcher(members: [
            ImportFixtures.searchResult(id: 501, name: "Jak 1"),
            ImportFixtures.searchResult(id: 502, name: "Jak 2"),
        ])
        let scanner = FakePhotoScanner(defaultPlan: .init(tileCount: 1, items: [
            ImportFixtures.item(id: 0, photo: "IMG_1", title: "Jak Collection", platform: "ps3", igdbID: 500, bucket: .confident, compilation: true)
        ]))
        let model = PhotoScanModel(environment: ImportEnv.make(scanner: scanner, committer: committer, searcher: searcher))
        model.enqueue([url("IMG_1")])
        model.start()
        await waitFor { model.presentation == .review }
        model.commit()
        await waitFor { model.presentation == .committed }

        #expect(committer.recordedCompilations.count == 1)
        #expect(committer.recordedCompilations.first?.members.count == 2)
        #expect(committer.recordedSingles.isEmpty)
    }
}
