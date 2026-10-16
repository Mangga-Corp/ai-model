//
//  FastViTClassifier.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 15/10/26.
//


import Foundation
import CoreML
import CoreGraphics
import Vision

/// FastViT T8 ImageNet classifier, used only as a second opinion on the scene.
actor FastViTClassifier: ImageClassifying {

    static let modelName = "FastViTT8F16"

    private var model: MLModel?

    func prepare() async throws {
        guard model == nil else { return }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try await SceneModelLoader.load(Self.modelName, configuration: configuration)
    }

    func classify(_ image: CGImage, top: Int) async throws -> [ClassificationHint] {
        try await prepare()
        guard let model else { throw SceneModelError.notLoaded("FastViT") }

        // ImageNet classifiers are trained on centre crops.
        let input = try SceneModelIO.imageInput(for: model, image: image, crop: .centerCrop)
        let output = try await model.prediction(from: input)

        let probabilities: [AnyHashable: NSNumber]
        if let name = model.modelDescription.predictedProbabilitiesName,
           let dictionary = output.featureValue(for: name)?.dictionaryValue {
            probabilities = dictionary
        } else if let dictionary = SceneModelIO.firstOutput(of: .dictionary, in: output, model: model)?
                    .dictionaryValue {
            probabilities = dictionary
        } else {
            throw SceneModelError.unexpectedOutput("FastViT: no probability dictionary")
        }

        let hints = probabilities.compactMap { key, value -> ClassificationHint? in
            guard let label = key.base as? String else { return nil }
            return ClassificationHint(label: label, confidence: value.doubleValue)
        }
        return Array(hints.sorted { $0.confidence > $1.confidence }.prefix(top))
    }
}