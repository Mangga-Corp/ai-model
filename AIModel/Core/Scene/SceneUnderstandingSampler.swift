//
//  SceneUnderstandingSampler.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 15/10/26.
//

import Foundation
import CoreGraphics

/// Decides WHEN the scene pipeline runs. Lives on the main actor (project
/// default) because it is driven from the camera view model; the heavy work
/// happens inside the pipeline actor.
final class SceneUnderstandingSampler {

    var interval: TimeInterval = 1.0
    /// Multiplier applied when the device is hot.
    var thermalBackoff: Double = 3.0
    /// Injected for tests.
    var now: () -> Date = Date.init
    var thermalState: () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }

    private let pipeline: any SceneAnalyzing
    private var stabilizer = SceneStabilizer()
    private var lastSample = Date.distantPast
    private var inFlight = false
    private var generation = 0

    private(set) var latest: SceneSnapshot?

    init(pipeline: any SceneAnalyzing = SceneUnderstandingPipeline()) {
        self.pipeline = pipeline
    }

    func prepare() async throws { try await pipeline.prepare() }

    var effectiveInterval: TimeInterval {
        switch thermalState() {
        case .serious, .critical: return interval * thermalBackoff
        default: return interval
        }
    }

    /// Offers a frame. `makeImage` is only called when a sample is accepted, so
    /// rejected frames cost nothing.
    func offer(makeImage: () -> CGImage?,
               subjectBox: CGRect?,
               onUpdate: @escaping (SceneSnapshot) -> Void) {
        let time = now()
        guard !inFlight, time.timeIntervalSince(lastSample) >= effectiveInterval,
              let image = makeImage() else { return }

        lastSample = time
        inFlight = true
        let token = generation

        Task {
            defer { if token == self.generation { self.inFlight = false } }
            guard let raw = try? await pipeline.analyze(image, subjectBox: subjectBox),
                  token == self.generation   // drop results from before a reset
            else { return }

            let stable = stabilizer.update(with: raw.category)
            let snapshot = SceneSnapshot(
                category: stable,
                confidence: stable == raw.category ? raw.confidence : raw.confidence * 0.5,
                segmentation: raw.segmentation,
                depth: raw.depth,
                hints: raw.hints,
                capturedAt: raw.capturedAt
            )
            latest = snapshot
            onUpdate(snapshot)
        }
    }

    func reset() {
        generation += 1
        lastSample = .distantPast
        inFlight = false
        latest = nil
        stabilizer.reset()
    }
}
