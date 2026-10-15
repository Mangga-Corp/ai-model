//
//  SceneModelProtocols.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 15/10/26.
//

import Foundation
import CoreGraphics

nonisolated protocol SemanticSegmenting: Sendable {
    func prepare() async throws
    func segment(_ image: CGImage) async throws -> SegmentationMap
}

nonisolated protocol DepthEstimating: Sendable {
    func prepare() async throws
    func estimateDepth(_ image: CGImage) async throws -> DepthMap
}

nonisolated protocol ImageClassifying: Sendable {
    func prepare() async throws
    func classify(_ image: CGImage, top: Int) async throws -> [ClassificationHint]
}
