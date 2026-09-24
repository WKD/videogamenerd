import Foundation

/// Pure Swift mirror of ``LibraryQuery/effectivePlaytimeSQL(alias:)`` (PLAN §7b, v17):
/// manual play time wins; otherwise the larger of the PSN and Batocera times (the same act
/// measured on two machines — never summed); nil when none is known.
enum EffectivePlaytime {
    static func seconds(manual: Int?, psn: Int?, batocera: Int?) -> Int? {
        if let manual { return manual }
        switch (psn, batocera) {
        case let (p?, b?): return max(p, b)
        case let (p?, nil): return p
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }
}
