//
//  SceneCategory.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 15/10/26.
//


import Foundation

/// The kind of location the camera is pointed at. Drives which best-practice
/// rules apply. Deliberately coarse: each case must change the advice given,
/// otherwise it does not earn a case.
nonisolated enum SceneCategory: String, CaseIterable, Sendable {
    /// Sea, lake or river front, with or without sand. Horizon rules apply.
    case beach
    /// Mountains, hills, rock faces, snow fields.
    case mountain
    /// Buildings, streets, bridges.
    case urban
    /// Trees, grass, parks, forests.
    case nature
    /// Walls, floors, furniture, little or no sky.
    case indoor
    /// Nothing dominant enough to call. Only scene-independent rules apply.
    case unknown

    var displayName: String {
        switch self {
        case .beach:    return "Beach / waterside"
        case .mountain: return "Mountain"
        case .urban:    return "Urban"
        case .nature:   return "Nature"
        case .indoor:   return "Indoor"
        case .unknown:  return "Unknown scene"
        }
    }
}