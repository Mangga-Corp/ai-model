//
//  ScenePreferences.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 15/10/26.
//


import Foundation

nonisolated struct ScenePreferences: Sendable, Equatable {
    /// User favours centred, symmetric frames → don't push the horizon to a third.
    var prefersSymmetry: Bool = false

    static let neutral = ScenePreferences()
}

extension ScenePreferences {
    init(profile: PhotographicPreferenceProfile?) {
        self.prefersSymmetry = (profile?.symmetryRatio ?? 0) > 0.5
    }
}