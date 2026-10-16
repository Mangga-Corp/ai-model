//
//  RecommendationEngine.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 15/10/26.
//


import Foundation

nonisolated struct RecommendationEngine: Sendable {

    enum Decision: Equatable, Sendable {
        /// Show the existing composition instruction (or "ready").
        case composition
        /// Show this scene recommendation instead.
        case scene(Recommendation)
    }

    func decide(compositionIssue: CompositionEvaluation.Issue?,
                sceneRecommendations: [Recommendation]) -> Decision {
        let ranked = sceneRecommendations.sorted { $0.priority > $1.priority }

        if let technical = ranked.first(where: { $0.priority == .technical }) {
            return .scene(technical)
        }
        // With no subject in view, "No subject detected" is not actionable; a
        // notable object hint (e.g. a table filling the usual subject spot) is.
        // Pattern match, not `==`: `Issue`'s Equatable conformance is main-actor
        // isolated under the project's default isolation.
        if case .noSubject? = compositionIssue,
           let notable = ranked.first(where: { $0.priority >= .notable }) {
            return .scene(notable)
        }
        if compositionIssue != nil { return .composition }
        if let enhancement = ranked.first { return .scene(enhancement) }
        return .composition
    }
}
