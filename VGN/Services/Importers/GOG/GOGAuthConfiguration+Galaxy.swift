import Foundation

extension GOGAuthConfiguration {
    /// The GOG Galaxy client's **public** OAuth credentials, shipped by every
    /// open-source GOG client (they are GOG's own values, not the owner's secrets). The
    /// owner approved the authorization-code route knowing it uses these (see
    /// `docs/gog-import.md`). Tests must use a fake configuration, never this one.
    ///
    /// ASSUMPTION(G0): verified at G1 — that these are still the current Galaxy client
    /// id/secret and that `auth.gog.com/token` accepts them.
    static let galaxy = GOGAuthConfiguration(
        clientID: "46899977096215655",
        clientSecret: "9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9"
    )
}
