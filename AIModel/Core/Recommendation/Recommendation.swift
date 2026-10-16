import Foundation

nonisolated struct Recommendation: Sendable, Equatable {

    enum Kind: String, Sendable {
        case levelHorizon
        case moveHorizonOffHead
        case placeHorizonOnThird
        case showFullPeak
        case showFullBuilding
        case stepAwayFromBackground
        case objectBehindHead
        case objectInTargetSpot
        case personInBackground
        case busyBackground
    }

    /// Ordering used by `RecommendationEngine`.
    enum Priority: Int, Comparable, Sendable {
        /// Nice-to-have; only shown once the user's own framing is satisfied.
        case enhancement = 0
        /// Worth fixing before small enhancements (e.g. a pole growing out of
        /// the head), but never overrides the user's own framing.
        case notable = 1
        /// Ruins the shot regardless of taste (tilted sea, horizon through the head).
        case technical = 2

        static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    let kind: Kind
    let priority: Priority
    let message: String
}
