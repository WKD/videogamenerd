import Foundation

/// Clusters photo-scan detections that are the same game (same platform + fuzzy
/// title), keeping the highest-confidence representative of each cluster. Used to
/// merge overlap duplicates from tiled shelf photos.
enum Dedupe {

    struct Detection: Equatable, Sendable {
        var id: Int64
        var title: String
        var platform: String
        /// Recognition confidence in [0, 1]; higher wins as the representative.
        var confidence: Double
        var alternativeNames: [String]

        init(id: Int64, title: String, platform: String, confidence: Double, alternativeNames: [String] = []) {
            self.id = id
            self.title = title
            self.platform = platform
            self.confidence = confidence
            self.alternativeNames = alternativeNames
        }
    }

    struct Cluster: Equatable, Sendable {
        var representative: Detection
        var members: [Detection]
    }

    /// Cluster `detections`. Two detections merge iff they share a platform and
    /// their titles score at or above `threshold`. Deterministic output.
    static func cluster(
        _ detections: [Detection],
        threshold: Double = FuzzyMatch.confidentThreshold
    ) -> [Cluster] {
        guard !detections.isEmpty else { return [] }

        // Union-find within platform buckets.
        var parent = Array(0..<detections.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }

        // Group indices by platform, then pairwise compare within each group.
        var byPlatform: [String: [Int]] = [:]
        for (i, d) in detections.enumerated() { byPlatform[d.platform, default: []].append(i) }
        for (_, indices) in byPlatform {
            for a in 0..<indices.count {
                for b in (a + 1)..<indices.count {
                    let i = indices[a], j = indices[b]
                    let names_i = [detections[i].title] + detections[i].alternativeNames
                    let names_j = [detections[j].title] + detections[j].alternativeNames
                    var best = 0.0
                    for ni in names_i {
                        best = Swift.max(best, FuzzyMatch.bestScore(query: ni, names: names_j))
                    }
                    if best >= threshold { union(i, j) }
                }
            }
        }

        // Collect clusters by root.
        var groups: [Int: [Int]] = [:]
        for i in detections.indices { groups[find(i), default: []].append(i) }

        var clusters: [Cluster] = []
        for (_, members) in groups {
            let memberDetections = members
                .map { detections[$0] }
                .sorted { lhs, rhs in
                    lhs.confidence != rhs.confidence ? lhs.confidence > rhs.confidence : lhs.id < rhs.id
                }
            let rep = memberDetections[0]
            clusters.append(Cluster(representative: rep, members: memberDetections))
        }
        // Deterministic cluster order: by representative id.
        return clusters.sorted { $0.representative.id < $1.representative.id }
    }
}
