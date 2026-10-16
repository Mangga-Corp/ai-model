//
//  SceneStabilizer.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 15/10/26.
//


import Foundation

/// Majority vote over the last few samples. A new category must win
/// `requiredVotes` of the last `window` samples before it replaces the current one.
nonisolated struct SceneStabilizer: Sendable {
    var window = 3
    var requiredVotes = 2

    private var history: [SceneCategory] = []
    private(set) var current: SceneCategory = .unknown

    mutating func update(with category: SceneCategory) -> SceneCategory {
        history.append(category)
        if history.count > window { history.removeFirst(history.count - window) }
        let votes = history.filter { $0 == category }.count
        if votes >= requiredVotes { current = category }
        return current
    }

    mutating func reset() {
        history.removeAll()
        current = .unknown
    }
}