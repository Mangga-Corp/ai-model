//
//  SceneModelLoader.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 15/10/26.
//


import Foundation
import CoreML

nonisolated enum SceneModelLoader {
    /// Xcode compiles each .mlpackage into "<name>.mlmodelc" inside the app bundle.
    static func load(_ name: String,
                     configuration: MLModelConfiguration,
                     bundle: Bundle = .main) async throws -> MLModel {
        guard let url = bundle.url(forResource: name, withExtension: "mlmodelc") else {
            throw SceneModelError.missingModel(name)
        }
        return try await MLModel.load(contentsOf: url, configuration: configuration)
    }
}