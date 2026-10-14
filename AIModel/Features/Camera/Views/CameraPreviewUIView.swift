import SwiftUI
import AVFoundation
import Vision
import UIKit

// MARK: - Frame Delegate

/// Receives camera frames, runs subject detection, and retains the frame for
/// capture.
///
/// Detection runs HERE, on the capture queue, while the buffer is valid.
/// AVFoundation pools buffer memory and recycles it as soon as this callback
/// returns, so handing the buffer to a detached task means Vision reads
/// recycled memory and silently finds nothing.
final class FrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    private weak var viewModel: CameraPreviewViewModel?

    /// Minimum seconds between detection passes. Vision costs more than the
    /// camera framerate, so frames are dropped rather than queued.
    private let interval: TimeInterval = 0.14
    private var lastAnalysis = Date.distantPast

    init(viewModel: CameraPreviewViewModel) {
        self.viewModel = viewModel
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Handed to the ViewModel, which holds it strongly for the shutter.
        viewModel?.storeFrame(sampleBuffer)

        let now = Date()
        guard now.timeIntervalSince(lastAnalysis) >= interval else { return }
        lastAnalysis = now

        Task { @MainActor in
            viewModel?.detectSubject(in: sampleBuffer)
        }
    }
}

/// Runs person detection on a camera frame.
///
/// Isolated from the delegate so it can be tested and reused, and so the
/// Vision call is the only thing here.
// MARK: - UIViewRepresentable

struct CameraPreviewRepresentable: UIViewRepresentable {

    let viewModel: CameraPreviewViewModel

    func makeUIView(context: Context) -> CameraPreviewUIView {
        CameraPreviewUIView(session: viewModel.captureSession)
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {}
}

/// Hosts the AVCaptureVideoPreviewLayer.
final class CameraPreviewUIView: UIView {

    private let session: AVCaptureSession
    private var previewLayer: AVCaptureVideoPreviewLayer?

    init(session: AVCaptureSession) {
        self.session = session
        super.init(frame: .zero)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, previewLayer == nil else { return }
        configurePreview()
    }

    private func configurePreview() {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        self.layer.addSublayer(layer)
        previewLayer = layer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Skip the initial pass, where bounds is still .zero — assigning a
        // zero-height frame makes Core Graphics fail with "Failed to create
        // WxH image slot".
        guard bounds.width > 0, bounds.height > 0 else { return }
        previewLayer?.frame = bounds
    }
}

#Preview {
    CameraGuidanceView(profile: nil, onDismiss: { })
}

