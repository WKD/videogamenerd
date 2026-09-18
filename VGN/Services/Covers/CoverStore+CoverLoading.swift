import CoreGraphics

/// Conform ``CoverStore`` to the UI lane's `CoverLoading` seam (defined in
/// `VGN/UI/CoverLoading.swift`, read-only for this lane) so the UI only has to
/// inject the store. `CoverStore.thumbnail(for:pixelSize:)` already provides the
/// exact signature; this just declares the conformance in the services lane.
extension CoverStore: CoverLoading {}
