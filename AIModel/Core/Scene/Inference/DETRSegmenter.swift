//
//  DETRSegmenter.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 15/10/26.
//

import Foundation
import CoreML
import CoreGraphics
import Vision

/// DETR ResNet50 semantic segmentation (COCO panoptic labels).
///
/// An actor so loading and inference never touch the main thread and the
/// lazily loaded model is shared safely.
actor DETRSegmenter: SemanticSegmenting {

    static let modelName = "DETRResnet50SemanticSegmentationF16P8"

    private var model: MLModel?
    private var labels: [String] = []

    func prepare() async throws {
        guard model == nil else { return }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all   // Neural Engine when available

        let loaded = try await SceneModelLoader.load(Self.modelName, configuration: configuration)
        let labels = SceneModelMetadata.labels(of: loaded)
        guard !labels.isEmpty else { throw SceneModelError.missingLabels("DETR") }

        self.labels = labels
        self.model = loaded
    }

    func segment(_ image: CGImage) async throws -> SegmentationMap {
        try await prepare()
        guard let model else { throw SceneModelError.notLoaded("DETR") }

        // Stretch the whole frame into the model input so normalised positions
        // in the mask map 1:1 onto the preview. Aspect distortion does not
        // matter for area fractions or the skyline's height.
        let input = try SceneModelIO.imageInput(for: model, image: image, crop: .scaleFill)
        let output = try await model.prediction(from: input)

        guard let array = SceneModelIO.firstOutput(of: .multiArray, in: output, model: model)?
                .multiArrayValue
        else { throw SceneModelError.unexpectedOutput("DETR: no multi-array output") }

        let grid = try SceneModelIO.grid(from: array)
        return SegmentationMap(width: grid.width,
                               height: grid.height,
                               classIndices: grid.values.map { Int32($0.rounded()) },
                               labels: labels)
    }
}

/// Reads the label list Apple's converted models store in their metadata.
nonisolated enum SceneModelMetadata {
    /// Key used by Apple's and Hugging Face's Core ML sample apps.
    /// ⚠️ Confirm under Metadata → Additional Metadata in Xcode.
    static let previewParamsKey = "com.apple.coreml.model.preview.params"

    static func labels(of model: MLModel) -> [String] {
        guard let creator = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String],
              let json = creator[previewParamsKey]?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let labels = object["labels"] as? [String]
        else { return [] }
        return labels
    }
}
