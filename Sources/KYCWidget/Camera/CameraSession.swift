#if canImport(UIKit) && canImport(AVFoundation)
import AVFoundation
import UIKit

/// Thin wrapper around `AVCaptureSession` that handles:
///   • Configuring back-camera or front-camera input.
///   • Switching between the two without recreating the session.
///   • Capturing a still photo via `AVCapturePhotoOutput`.
///   • Recording a short liveness video via `AVCaptureMovieFileOutput`.
///
/// Lives on a dedicated session queue so configuration changes don't
/// block the main thread. Preview is rendered by ``CameraPreviewView``.
final class CameraSession: NSObject {

    enum Facing { case back, front }
    enum Mode { case photo, video }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "kyc.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()

    private(set) var facing: Facing = .back
    private(set) var mode: Mode = .photo
    private var currentInput: AVCaptureDeviceInput?

    private var photoCompletion: ((Result<Data, Error>) -> Void)?
    private var videoCompletion: ((Result<URL, Error>) -> Void)?

    // MARK: - Configure

    /// Configure the session for either photos or video. Idempotent — safe
    /// to call from `viewDidLoad` and again on facing changes.
    func configure(mode: Mode, facing: Facing, completion: @escaping (Error?) -> Void) {
        self.mode = mode
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = mode == .photo ? .photo : .high
            // Remove existing inputs and outputs so we can re-add fresh ones.
            for input in self.session.inputs { self.session.removeInput(input) }
            for output in self.session.outputs { self.session.removeOutput(output) }
            do {
                try self.addInput(facing: facing)
                if mode == .photo {
                    if self.session.canAddOutput(self.photoOutput) {
                        self.session.addOutput(self.photoOutput)
                    }
                } else {
                    if self.session.canAddOutput(self.movieOutput) {
                        self.session.addOutput(self.movieOutput)
                    }
                }
                self.session.commitConfiguration()
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async { completion(nil) }
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    func switchFacing(completion: @escaping (Error?) -> Void) {
        configure(mode: mode, facing: facing == .back ? .front : .back, completion: completion)
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func addInput(facing: Facing) throws {
        let position: AVCaptureDevice.Position = facing == .back ? .back : .front
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        guard let device = discovery.devices.first else {
            throw NSError(domain: "KYCWidget", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "No camera available for the requested facing.",
            ])
        }
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
            self.facing = facing
        }
        // Microphone for video mode.
        if mode == .video, let mic = AVCaptureDevice.default(for: .audio) {
            let micInput = try AVCaptureDeviceInput(device: mic)
            if session.canAddInput(micInput) {
                session.addInput(micInput)
            }
        }
    }

    // MARK: - Capture

    func capturePhoto(completion: @escaping (Result<Data, Error>) -> Void) {
        sessionQueue.async {
            self.photoCompletion = completion
            let settings = AVCapturePhotoSettings()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func startRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        sessionQueue.async {
            self.videoCompletion = completion
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("kyc-\(UUID().uuidString).mov")
            self.movieOutput.startRecording(to: tempURL, recordingDelegate: self)
        }
    }

    func stopRecording() {
        sessionQueue.async {
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraSession: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        DispatchQueue.main.async {
            if let error { self.photoCompletion?(.failure(error)); return }
            if let data = photo.fileDataRepresentation() {
                self.photoCompletion?(.success(data))
            } else {
                self.photoCompletion?(.failure(NSError(
                    domain: "KYCWidget", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Photo data unavailable."]
                )))
            }
            self.photoCompletion = nil
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraSession: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        DispatchQueue.main.async {
            if let error {
                self.videoCompletion?(.failure(error))
            } else {
                self.videoCompletion?(.success(outputFileURL))
            }
            self.videoCompletion = nil
        }
    }
}
#endif
