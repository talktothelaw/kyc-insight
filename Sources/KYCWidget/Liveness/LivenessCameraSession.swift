#if canImport(AVFoundation) && canImport(UIKit)
import AVFoundation
import UIKit

/// AVCaptureSession variant configured for *active vision*: front camera +
/// `AVCaptureVideoDataOutput` that emits every frame to a delegate. The
/// existing `CameraSession` is photo/movie-output focused — used by
/// `CameraFieldView` for document scans — and we deliberately don't fold
/// these flows together. Each camera surface is small enough on its own
/// that the cleaner separation is worth more than the de-duplication.
@available(iOS 15.0, *)
final class LivenessCameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    enum Facing { case front, back }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "kyc.liveness.session")
    private let sampleQueue = DispatchQueue(label: "kyc.liveness.samples")
    private let videoOutput = AVCaptureVideoDataOutput()

    private(set) var facing: Facing = .front

    /// Fired on the sample queue for every frame the camera produces.
    var onSample: ((CMSampleBuffer) -> Void)?

    func start(facing: Facing = .front, completion: @escaping (Error?) -> Void) {
        sessionQueue.async {
            self.facing = facing
            self.configure(completion: completion)
        }
    }

    /// Hot-swap between front and back. The Vision-based detector handles
    /// either orientation via the same `analyze(sampleBuffer:)` entry point
    /// — front-facing samples are mirrored; back-facing aren't.
    func switchFacing(completion: @escaping (Error?) -> Void) {
        sessionQueue.async {
            self.facing = self.facing == .front ? .back : .front
            self.configure(completion: completion)
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configure(completion: @escaping (Error?) -> Void) {
        session.beginConfiguration()
        session.sessionPreset = .high
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        do {
            try addCamera()
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
            videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }
            // Mirror the preview only when the user is looking at the
            // front camera — back-camera footage should NOT be mirrored.
            if let conn = videoOutput.connection(with: .video) {
                if conn.isVideoOrientationSupported {
                    conn.videoOrientation = .portrait
                }
                if conn.isVideoMirroringSupported {
                    conn.isVideoMirrored = (facing == .front)
                }
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
            DispatchQueue.main.async { completion(nil) }
        } catch {
            session.commitConfiguration()
            DispatchQueue.main.async { completion(error) }
        }
    }

    private func addCamera() throws {
        let position: AVCaptureDevice.Position = (facing == .front) ? .front : .back
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        guard let device = discovery.devices.first else {
            throw NSError(domain: "KYCWidget.Liveness", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "No \(position == .front ? "front" : "back")-facing camera available.",
            ])
        }
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) {
            session.addInput(input)
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSample?(sampleBuffer)
    }
}
#endif
