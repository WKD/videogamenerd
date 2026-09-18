import Foundation

/// The sparse, sortable fine-rank key within a tier (PLAN §7).
///
/// Agent C owns the RankingEngine and the final key representation; it is
/// aliased here in exactly one place so switching it (e.g. to a string key)
/// is a one-line change that ripples through every model type.
typealias RankKey = Int64
