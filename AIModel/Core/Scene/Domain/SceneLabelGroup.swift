//
//  SceneLabelGroup.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 15/10/26.
//


import Foundation

/// Photography-relevant grouping of segmentation labels.
nonisolated enum SceneLabelGroup: String, CaseIterable, Sendable {
    case sky, water, sand, mountain, snow, vegetation, structure, street, indoor, person, other

    /// Maps a raw model label (e.g. "sky-other-merged", "sea", "building-other-merged")
    /// to a group. Matches whole tokens so "sandwich" never becomes `.sand`.
    static func group(forLabel raw: String) -> SceneLabelGroup {
        let tokens = Set(
            raw.lowercased()
                .split(whereSeparator: { $0 == "-" || $0 == " " || $0 == "_" })
                .map(String.init)
        )
        func any(_ words: Set<String>) -> Bool { !tokens.isDisjoint(with: words) }

        if tokens == ["person"] { return .person }
        if any(["sky"]) { return .sky }
        if any(["sea", "river", "water", "lake"]) { return .water }
        if any(["sand"]) { return .sand }
        if any(["mountain", "hill", "rock"]) { return .mountain }
        if any(["snow"]) { return .snow }
        if any(["tree", "grass", "flower", "plant", "bush", "dirt"]) { return .vegetation }
        if any(["building", "house", "roof", "bridge", "skyscraper", "tower"]) { return .structure }
        if any(["road", "pavement", "railroad", "platform"]) { return .street }
        if any(["wall", "ceiling", "floor", "window", "door", "table", "cabinet", "shelf",
                "curtain", "rug", "bed", "couch", "chair", "counter", "stairs"]) { return .indoor }
        return .other
    }
}