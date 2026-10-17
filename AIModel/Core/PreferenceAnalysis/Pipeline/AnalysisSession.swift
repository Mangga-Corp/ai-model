import Foundation
import Combine

nonisolated enum PhotoRunState: Equatable, Sendable {
    case queued
    case running
    case finished(PhotoResultStatus)
}

/// Owns the analysis for the current photo selection and keeps it available
/// across navigation.
///
/// One instance lives for the life of the root view. `start(photos:)` is
/// idempotent per selection, so pushing, popping and re-pushing the results
/// screen never repeats inference. Changing the selection cancels the old run
/// and starts a new one.
@MainActor
final class AnalysisSession: ObservableObject {

    enum Phase: Equatable {
        case idle
        case running
        case completed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var photoStates: [UUID: PhotoRunState] = [:]
    @Published private(set) var results: [PhotoResult] = []
    @Published private(set) var profile: PreferenceProfile?
    @Published private(set) var photoOrder: [UUID] = []

    let imageStore: PhotoImageStore
    let artifactStore: AnalysisArtifactStore

    private let engine: any PhotoAnalyzing
    private var selectionKey: [UUID] = []
    private var runTask: Task<Void, Never>?

    /// - Parameter engine: Defaults to the real pipeline. Tests and previews
    ///   may inject another analyzer that writes into the same stores.
    init(imageStore: PhotoImageStore = PhotoImageStore(),
         artifactStore: AnalysisArtifactStore = AnalysisArtifactStore(),
         engine: (any PhotoAnalyzing)? = nil) {
        self.imageStore = imageStore
        self.artifactStore = artifactStore
        self.engine = engine ?? AnalysisEngine(imageStore: imageStore, artifactStore: artifactStore)
    }

    // MARK: Progress

    var totalCount: Int { photoOrder.count }

    var finishedCount: Int {
        photoStates.values.filter { if case .finished = $0 { return true } else { return false } }.count
    }

    /// Fraction of photos whose analysis has actually finished.
    var progress: Double {
        totalCount == 0 ? 0 : Double(finishedCount) / Double(totalCount)
    }

    func result(for id: UUID) -> PhotoResult? { results.first { $0.id == id } }

    // MARK: Control

    /// Starts analysing `photos` unless this exact selection is already running
    /// or finished.
    func start(photos: [ReferencePhoto]) {
        let key = photos.map(\.id)
        if key == selectionKey, phase != .idle { return }

        runTask?.cancel()
        selectionKey = key
        photoOrder = key
        results = []
        profile = nil
        phase = .running
        photoStates = Dictionary(uniqueKeysWithValues: key.map { ($0, PhotoRunState.queued) })

        // Snapshot on the main actor so the pipeline never touches UI models.
        let sources = photos.map(PhotoSource.init)
        let engine = self.engine
        let relay: @Sendable (PhotoRunEvent) -> Void = { [weak self] event in
            let session = self
            Task { @MainActor in session?.apply(event) }
        }

        // Runs never overlap. A cancelled run still finishes the photo it is
        // on (Core ML predictions cannot be interrupted), and two runs using the
        // same models at once is unsafe, so the new run waits for the old one.
        let previous = runTask
        runTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            let finished = await engine.analyze(sources, events: relay)
            guard !Task.isCancelled, let self, self.selectionKey == key else { return }
            self.results = finished
            self.profile = ProfileAggregator.aggregate(finished)
            self.phase = .completed
        }
    }

    /// Abandons the current run and returns to the initial state.
    func cancel() {
        runTask?.cancel()
        runTask = nil
        selectionKey = []
        photoOrder = []
        photoStates = [:]
        results = []
        profile = nil
        phase = .idle
    }

    private func apply(_ event: PhotoRunEvent) {
        guard phase == .running else { return }
        switch event {
        case .started(let id): photoStates[id] = .running
        case .finished(let id, let status): photoStates[id] = .finished(status)
        }
    }

    // MARK: Camera hand-off

    /// The profile in the shape the existing camera guidance consumes.
    func cameraGuidanceProfile() -> PhotographicPreferenceProfile? {
        guard let profile else { return nil }
        return CameraProfileBridge.make(profile: profile, results: results)
    }
}
