import Foundation
import CoreGraphics
import UIKit

/// Progress signal for one photo. Emitted only when real work starts or ends.
nonisolated enum PhotoRunEvent: Sendable {
    case started(UUID)
    case finished(UUID, PhotoResultStatus)
}

/// Anything that turns selected photos into results. The session depends on
/// this seam so tests and previews can supply fixed results.
nonisolated protocol PhotoAnalyzing: Sendable {
    func analyze(_ sources: [PhotoSource],
                 events: @escaping @Sendable (PhotoRunEvent) -> Void) async -> [PhotoResult]
}

/// Orchestrates Stages A through E for a set of photos.
///
/// - Photos are processed two at a time (the Core ML models are single actors,
///   so more parallelism only adds memory pressure).
/// - Each photo's result is cached by its stable ID. Asking again for a photo
///   that has already been analysed returns the cached result and runs NO
///   inference, so revisiting results or expanding detail cards is free.
/// - The three Core ML models live only for the duration of a run; they are
///   released afterwards so the camera screen starts with that memory free.
actor AnalysisEngine: PhotoAnalyzing {

    static let maximumConcurrentPhotos = 2

    private let imageStore: PhotoImageStore
    private let artifactStore: AnalysisArtifactStore
    private var cache: [UUID: PhotoResult] = [:]

    init(imageStore: PhotoImageStore, artifactStore: AnalysisArtifactStore) {
        self.imageStore = imageStore
        self.artifactStore = artifactStore
    }

    /// Analyses `sources` and returns results in selection order.
    /// Returns early with whatever finished if the calling task is cancelled.
    func analyze(_ sources: [PhotoSource],
                 events: @escaping @Sendable (PhotoRunEvent) -> Void) async -> [PhotoResult] {

        let pending = sources.filter { cache[$0.id] == nil }
        if !pending.isEmpty {
            let models = AnalysisModels()
            let images = imageStore, artifacts = artifactStore

            await withTaskGroup(of: PhotoResult.self) { group in
                var iterator = pending.makeIterator()

                func addNext() {
                    guard !Task.isCancelled, let source = iterator.next() else { return }
                    group.addTask {
                        await Self.process(source, models: models, images: images,
                                           artifacts: artifacts, events: events)
                    }
                }

                for _ in 0..<Self.maximumConcurrentPhotos { addNext() }
                while let result = await group.next() {
                    cache[result.id] = result
                    addNext()
                }
            }
        }

        return sources.compactMap { cache[$0.id] }.sorted { $0.selectionOrder < $1.selectionOrder }
    }

    func cachedResult(for id: UUID) -> PhotoResult? { cache[id] }

    func reset() {
        cache.removeAll()
    }

    // MARK: One photo

    private static func process(_ source: PhotoSource,
                                models: AnalysisModels,
                                images: PhotoImageStore,
                                artifacts: AnalysisArtifactStore,
                                events: @Sendable (PhotoRunEvent) -> Void) async -> PhotoResult {
        events(.started(source.id))

        // Stage A
        let prepared = PhotoPreparer.prepare(source)
        let result: PhotoResult
        switch prepared.outcome {
        case .unreadable(let reason):
            result = PhotoResultBuilder.unreadable(prepared, reason: reason)

        case .ready(let image, let record):
            images.set(UIImage(cgImage: image, scale: 1, orientation: .up), for: prepared.id)

            // Stages B + C
            let (evidence, grids) = await EvidenceCollector.collect(from: image, models: models)
            artifacts.set(grids, for: prepared.id)

            // Stages D + E
            result = PhotoResultBuilder.build(prepared: prepared, record: record,
                                              evidence: evidence, artifacts: grids)
        }

        events(.finished(source.id, result.status))
        return result
    }
}
