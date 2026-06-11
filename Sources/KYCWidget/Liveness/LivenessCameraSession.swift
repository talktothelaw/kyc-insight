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
final class LivenessCameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDepthDataOutputDelegate {

    enum Facing { case front, back }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "kyc.liveness.session")
    private let sampleQueue = DispatchQueue(label: "kyc.liveness.samples")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()

    private(set) var facing: Facing = .front

    /// TrueDepth anti-spoof verdict: false = scene persistently FLAT
    /// (photo / screen replay), true = real 3D relief, nil = no depth
    /// hardware / no verdict yet. Written and read on `sampleQueue`.
    private(set) var latestDepthOk: Bool?
    private var flatStreak = 0
    private var solidStreak = 0

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
        // VGA is plenty for face analysis and cuts the per-frame Vision +
        // render cost ~7× vs .high (1080p); matches the Android analyzer
        // resolution so evidence JPEGs stay comparable across platforms.
        session.sessionPreset = session.canSetSessionPreset(.vga640x480) ? .vga640x480 : .high
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        latestDepthOk = nil
        flatStreak = 0
        solidStreak = 0
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
            // TrueDepth depth stream (front camera on Face ID hardware) —
            // drives the depthOk anti-spoof signal. Silently absent on
            // devices without a depth camera.
            if facing == .front, session.canAddOutput(depthOutput) {
                session.addOutput(depthOutput)
                if depthOutput.connection(with: .depthData) != nil {
                    depthOutput.isFilteringEnabled = true
                    depthOutput.setDelegate(self, callbackQueue: sampleQueue)
                } else {
                    session.removeOutput(depthOutput)
                }
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
        // Prefer the TrueDepth module for the front camera — same RGB
        // stream, plus the depth map for presentation-attack detection.
        let types: [AVCaptureDevice.DeviceType] = (position == .front)
            ? [.builtInTrueDepthCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
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

    // MARK: - AVCaptureDepthDataOutputDelegate

    func depthDataOutput(
        _ output: AVCaptureDepthDataOutput,
        didOutput depthData: AVDepthData,
        timestamp: CMTime,
        connection: AVCaptureConnection
    ) {
        let depth32 = depthData.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depthData
            : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let map = depth32.depthDataMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        let w = CVPixelBufferGetWidth(map)
        let h = CVPixelBufferGetHeight(map)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(map) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(map)

        // Sample the centre half of the frame (where the face oval sits)
        // and measure depth relief across valid handheld-range samples.
        var minD = Float.greatestFiniteMagnitude
        var maxD = -Float.greatestFiniteMagnitude
        var valid = 0
        var y = h / 4
        while y < (3 * h) / 4 {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            var x = w / 4
            while x < (3 * w) / 4 {
                let d = row[x]
                if d.isFinite && d > 0.1 && d < 1.5 {
                    if d < minD { minD = d }
                    if d > maxD { maxD = d }
                    valid += 1
                }
                x += 8
            }
            y += 8
        }
        guard valid >= 40 else { return }  // too little signal — keep last verdict

        // A real face shows ≥ ~2 cm nose-to-cheek relief; photos and
        // screens are flat. Streaks debounce single noisy frames.
        if (maxD - minD) < 0.015 {
            flatStreak += 1
            solidStreak = 0
            if flatStreak >= 5 { latestDepthOk = false }
        } else {
            solidStreak += 1
            flatStreak = 0
            if solidStreak >= 3 { latestDepthOk = true }
        }
    }
}
#endif
