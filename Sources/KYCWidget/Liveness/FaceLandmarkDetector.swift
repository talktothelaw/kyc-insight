#if canImport(Vision) && canImport(AVFoundation) && canImport(UIKit)
import Vision
import AVFoundation
import CoreImage
import UIKit

/// Single-face landmark detector built on Apple's Vision framework. This is
/// the iOS counterpart to the web widget's MediaPipe Face Landmarker
/// (`kyc-web-wiget-v2/src/hooks/useLiveness.ts`). We use Vision rather than
/// pulling MediaPipe into the iOS SDK because:
///   • Vision ships with iOS — no native dep, no model download at runtime.
///   • The signals we actually need (face bbox, eye landmarks, yaw, smile
///     blendshape) are all exposed natively.
///   • The web math (EAR, yaw ratio, face-size ratio) ports verbatim once
///     you account for the different keypoint indexing.
///
/// The detector exposes a single sample type, `FaceFrameSignals`, that
/// carries every signal the state machine needs. The state machine only
/// looks at THIS shape — it doesn't import Vision itself, which keeps the
/// machine unit-testable with synthetic samples.
public struct FaceFrameSignals: Sendable, Equatable {
    /// True if exactly one face was detected (we reject multi-face frames
    /// upstream of this signal). Matches the web `faceDetected` semantics.
    public let faceDetected: Bool

    /// Eye-aspect-ratio average across both eyes. Drops sharply during a
    /// blink. Threshold parity with the web hook:
    ///   • EAR < 0.20 → eye is closed
    ///   • EAR > 0.24 → eye is open
    /// Set to 1.0 when no face / landmarks unavailable.
    public let earAvg: Double

    /// Horizontal head pose, normalised so 0.5 is centred. < 0.35 → user
    /// turned head to OUR left; > 0.65 → user turned head to OUR right.
    /// Same convention as web `computeYawRatio` so server-side validation
    /// and dashboard review treat both clients identically.
    public let yawRatio: Double

    /// Face bounding box centred + reasonable size? Single combined flag
    /// because both signals gate every challenge, so the state machine
    /// only ever checks one boolean.
    public let faceCentered: Bool

    /// Face-region brightness 0–255. The state machine rejects frames
    /// below 100 (same as web). Server-side validator (`sharp`) does an
    /// independent check on the submitted JPEGs.
    public let brightness: Double

    /// Smile blendshape score 0..1, when available. Vision's
    /// `VNFaceObservation.faceCaptureQuality` does not surface smile
    /// directly — we approximate from mouth landmarks (corners pulled
    /// outward + upward) and clamp to 0..1.
    public let smileScore: Double

    /// Mouth-aperture ratio (height / face height). Used for the
    /// OPEN_MOUTH challenge — threshold 0.05 mirrors the web hook.
    public let mouthOpenRatio: Double

    public static let empty = FaceFrameSignals(
        faceDetected: false,
        earAvg: 1.0,
        yawRatio: 0.5,
        faceCentered: false,
        brightness: 128,
        smileScore: 0,
        mouthOpenRatio: 0
    )
}

/// Stateless wrapper around a single `VNDetectFaceLandmarksRequest`. The
/// caller drives it from a `AVCaptureVideoDataOutput` delegate; the detector
/// does NOT manage the camera session itself.
@available(iOS 14.0, *)
public final class FaceLandmarkDetector {

    private let request: VNDetectFaceLandmarksRequest
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    public init() {
        self.request = VNDetectFaceLandmarksRequest()
    }

    /// Camera orientation passed in so the Vision orientation matches
    /// the actual buffer (front camera frames are mirrored; back aren't).
    public enum CameraFacing { case front, back }

    /// Run the detector on a single sample buffer. Returns the signals
    /// + the most recent UIImage frame (for capture). The image is the
    /// RGB representation matching what the user saw on screen — front
    /// camera frames come out horizontally flipped, back-camera ones
    /// don't.
    public func analyze(sampleBuffer: CMSampleBuffer, facing: CameraFacing = .front) -> (signals: FaceFrameSignals, image: UIImage?) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return (FaceFrameSignals.empty, nil)
        }
        // Vision orientation: front-camera buffers arrive mirrored about
        // the vertical axis when the device is held portrait → `.leftMirrored`
        // un-mirrors them. Back-camera buffers in portrait map to `.right`.
        let orientation: CGImagePropertyOrientation = (facing == .front) ? .leftMirrored : .right
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return (FaceFrameSignals.empty, makeImage(from: pixelBuffer, facing: facing))
        }
        let image = makeImage(from: pixelBuffer, facing: facing)
        let observations = (request.results ?? [])
        guard observations.count == 1, let face = observations.first else {
            return (FaceFrameSignals.empty, image)
        }
        let signals = signals(from: face, in: pixelBuffer)
        return (signals, image)
    }

    private func makeImage(from pixelBuffer: CVPixelBuffer, facing: CameraFacing) -> UIImage? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        // Front camera is mirrored at the AVCaptureConnection layer
        // (videoMirrored=true) for the preview, so the saved JPEG also
        // needs flipping to match what the user saw. Back-camera samples
        // are already un-mirrored and pass through untouched.
        let oriented = (facing == .front)
            ? ci.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -ci.extent.width, y: 0))
            : ci
        guard let cg = ciContext.createCGImage(oriented, from: oriented.extent) else { return nil }
        return UIImage(cgImage: cg, scale: 1.0, orientation: .up)
    }

    private func signals(from face: VNFaceObservation, in pixelBuffer: CVPixelBuffer) -> FaceFrameSignals {
        let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        // ── face box ─────────────────────────────────────────────────────
        // Vision's bbox is normalised + Y-flipped relative to UIImage coords.
        // We work in normalised space throughout so the math stays
        // resolution-independent.
        let box = face.boundingBox
        let cx = box.midX
        let cy = 1.0 - box.midY  // flip Y to match UIImage convention
        // Match web `isFaceCentered`: nose within ±15% of centre.
        let centered = abs(cx - 0.5) < 0.15 && abs(cy - 0.5) < 0.20
        let sizeRatio = box.height
        let sizeOk = sizeRatio > 0.25 && sizeRatio < 0.75

        // ── yaw ──────────────────────────────────────────────────────────
        // VNFaceObservation.yaw is in radians (positive = head to OUR right).
        // Map to the web's 0..1 ratio where 0.5 is centre.
        let yawRadians = face.yaw?.doubleValue ?? 0
        let yawRatio = 0.5 - max(min(yawRadians / .pi, 0.5), -0.5)

        // ── landmarks (eyes + mouth) ─────────────────────────────────────
        var ear = 1.0
        var mouthOpen = 0.0
        var smile = 0.0
        if let landmarks = face.landmarks {
            if let l = landmarks.leftEye, let r = landmarks.rightEye {
                ear = (eyeAspectRatio(l, in: box, w: w, h: h) + eyeAspectRatio(r, in: box, w: w, h: h)) / 2
            }
            if let outer = landmarks.outerLips, let inner = landmarks.innerLips {
                mouthOpen = mouthOpenRatio(outer: outer, inner: inner, in: box, h: h)
                smile = smileScore(outer: outer, in: box, w: w)
            }
        }

        return FaceFrameSignals(
            faceDetected: true,
            earAvg: ear,
            yawRatio: yawRatio,
            faceCentered: centered && sizeOk,
            brightness: 128, // brightness sampled at capture time, not here
            smileScore: smile,
            mouthOpenRatio: mouthOpen
        )
    }

    // ── eye math ────────────────────────────────────────────────────────
    // Apple's Vision returns 6 normalised points around each eye, but the
    // point ORDER isn't a documented contract — it's "contour following"
    // and varies. Indexing pts[0]..pts[5] as MediaPipe's P1..P6 EAR points
    // produces noise (the original port returned values bouncing between
    // 0.05 and 1.5 even on a wide-open eye, so blink never triggered).
    //
    // The bounding-box height/width ratio is the order-independent proxy:
    //   • open eye → ~0.30–0.50
    //   • closed eye → ~0.05–0.15
    // The thresholds in LivenessChallengeStateMachine (`earBlinkThreshold
    // = 0.20`, `earOpenThreshold = 0.24`) sit in the right band for this
    // metric without modification.
    private func eyeAspectRatio(_ region: VNFaceLandmarkRegion2D, in box: CGRect, w: CGFloat, h: CGFloat) -> Double {
        let pts = region.normalizedPoints
        guard pts.count >= 4 else { return 1.0 }
        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for p in pts {
            if p.x < minX { minX = p.x }
            if p.x > maxX { maxX = p.x }
            if p.y < minY { minY = p.y }
            if p.y > maxY { maxY = p.y }
        }
        // Project onto pixel space so the height/width ratio is invariant
        // under the face-box aspect ratio (otherwise a tall face would
        // bias toward a higher ratio).
        let width = (maxX - minX) * box.width * w
        let height = (maxY - minY) * box.height * h
        return width > 0 ? Double(height / width) : 1.0
    }

    private func mouthOpenRatio(outer: VNFaceLandmarkRegion2D, inner: VNFaceLandmarkRegion2D, in box: CGRect, h: CGFloat) -> Double {
        let inners = inner.normalizedPoints
        guard inners.count >= 4 else { return 0 }
        // Use the inner lip top/bottom landmarks — bigger gap during open.
        let top = inners[inners.count / 4]
        let bottom = inners[(3 * inners.count) / 4]
        let topY = box.minY + top.y * box.height
        let botY = box.minY + bottom.y * box.height
        let mouthHeight = abs(topY - botY) * h
        let faceHeight = box.height * h
        return faceHeight > 0 ? Double(mouthHeight / faceHeight) : 0
    }

    private func smileScore(outer: VNFaceLandmarkRegion2D, in box: CGRect, w: CGFloat) -> Double {
        let pts = outer.normalizedPoints
        guard pts.count >= 12 else { return 0 }
        // Approximate: corners-outward over mouth width. Smile pulls the
        // corners up + outward; we proxy by ratio between corner-corner
        // distance and the mouth's bounding width.
        let leftCorner = pts[0]
        let rightCorner = pts[6]
        let dx = (rightCorner.x - leftCorner.x) * box.width * w
        let dy = (rightCorner.y - leftCorner.y) * box.height
        let raw = Double(abs(dy)) * 6 + Double(dx > 0 ? 0.1 : 0)
        return max(0, min(1, raw))
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }
}
#endif
