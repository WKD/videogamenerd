import Foundation
import Testing
@testable import VGN

/// Binary discovery + version gating, all seams injected (no real shell/subprocess).
struct ClaudeBinaryLocatorTests {

    private func locator(
        override: String? = nil,
        commandV: String? = nil,
        known: [String] = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"],
        existing: Set<String>,
        versions: [String: String],
        minimum: ClaudeCLIVersion = .minimumSupported
    ) -> ClaudeBinaryLocator {
        ClaudeBinaryLocator(
            explicitOverride: override,
            minimumVersion: minimum,
            knownLocations: known,
            commandVSource: { commandV },
            versionProbe: { versions[$0] },
            fileExists: { existing.contains($0) }
        )
    }

    @Test("Override wins over command -v and known locations")
    func overrideWins() throws {
        let loc = locator(
            override: "/custom/claude",
            commandV: "/opt/homebrew/bin/claude",
            existing: ["/custom/claude", "/opt/homebrew/bin/claude"],
            versions: ["/custom/claude": "2.1.0", "/opt/homebrew/bin/claude": "2.1.0"]
        )
        #expect(try loc.resolve().path == "/custom/claude")
    }

    @Test("command -v is preferred over known locations")
    func commandVPreferred() throws {
        let loc = locator(
            commandV: "/Users/me/.local/bin/claude",
            existing: ["/Users/me/.local/bin/claude", "/usr/local/bin/claude"],
            versions: ["/Users/me/.local/bin/claude": "2.2.0", "/usr/local/bin/claude": "2.2.0"]
        )
        #expect(try loc.resolve().path == "/Users/me/.local/bin/claude")
    }

    @Test("Falls through to a known location when earlier candidates don't exist")
    func fallThroughToKnown() throws {
        let loc = locator(
            commandV: nil,
            existing: ["/usr/local/bin/claude"],
            versions: ["/usr/local/bin/claude": "2.0.5"]
        )
        #expect(try loc.resolve().path == "/usr/local/bin/claude")
    }

    @Test("notInstalled when nothing exists, listing what was searched")
    func notInstalled() {
        let loc = locator(existing: [], versions: [:])
        #expect(throws: ClaudeCLIError.self) { _ = try loc.resolve() }
        do {
            _ = try loc.resolve()
        } catch let ClaudeCLIError.notInstalled(searched) {
            #expect(searched.contains("/opt/homebrew/bin/claude"))
        } catch {
            Issue.record("expected notInstalled, got \(error)")
        }
    }

    @Test("versionTooOld when the only binary is below the minimum")
    func versionTooOld() {
        let loc = locator(
            existing: ["/opt/homebrew/bin/claude"],
            versions: ["/opt/homebrew/bin/claude": "1.9.0"],
            minimum: ClaudeCLIVersion(major: 2, minor: 0, patch: 0)
        )
        do {
            _ = try loc.resolve()
            Issue.record("expected throw")
        } catch let ClaudeCLIError.versionTooOld(found, minimum) {
            #expect(found == "1.9.0")
            #expect(minimum == "2.0.0")
        } catch {
            Issue.record("expected versionTooOld, got \(error)")
        }
    }

    @Test("Skips a too-old candidate for a newer one later in the list")
    func skipsOldForNew() throws {
        let loc = locator(
            commandV: "/old/claude",
            known: ["/opt/homebrew/bin/claude"],
            existing: ["/old/claude", "/opt/homebrew/bin/claude"],
            versions: ["/old/claude": "1.0.0", "/opt/homebrew/bin/claude": "2.3.0"]
        )
        #expect(try loc.resolve().path == "/opt/homebrew/bin/claude")
    }

    @Test("unparsableVersion when an existing binary reports gibberish")
    func unparsable() {
        let loc = locator(
            existing: ["/opt/homebrew/bin/claude"],
            versions: ["/opt/homebrew/bin/claude": "banana"]
        )
        do {
            _ = try loc.resolve()
            Issue.record("expected throw")
        } catch let ClaudeCLIError.unparsableVersion(raw) {
            #expect(raw == "banana")
        } catch {
            Issue.record("expected unparsableVersion, got \(error)")
        }
    }
}
