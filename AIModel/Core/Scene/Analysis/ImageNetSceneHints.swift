//
//  ImageNetSceneHints.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 15/10/26.
//


import Foundation

nonisolated enum ImageNetSceneHints {
    /// First synonym of ImageNet class names → category.
    static let table: [String: SceneCategory] = [
        "seashore": .beach, "sandbar": .beach, "lakeside": .beach,
        "breakwater": .beach, "coral reef": .beach,
        "alp": .mountain, "volcano": .mountain, "valley": .mountain, "cliff": .mountain,
        "church": .urban, "mosque": .urban, "palace": .urban, "monastery": .urban,
        "castle": .urban, "dome": .urban, "bell cote": .urban, "triumphal arch": .urban,
        "suspension bridge": .urban, "steel arch bridge": .urban, "obelisk": .urban,
        "library": .indoor, "restaurant": .indoor, "home theater": .indoor,
        "geyser": .nature, "rapeseed": .nature,
    ]

    /// "seashore, coast, seacoast, sea-coast" → .beach. Labels may arrive with
    /// or without a WordNet id prefix such as "n09428293 ". ⚠️ check FastViT's labels.
    static func category(for label: String) -> SceneCategory? {
        for synonym in label.lowercased().split(separator: ",") {
            var name = synonym.trimmingCharacters(in: .whitespaces)
            if let space = name.firstIndex(of: " "), name.hasPrefix("n"),
               name[name.index(after: name.startIndex)..<space].allSatisfy({ $0.isNumber }) {
                name = String(name[name.index(after: space)...])
            }
            if let category = table[name] { return category }
        }
        return nil
    }
}