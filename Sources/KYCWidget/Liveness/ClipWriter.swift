#if canImport(AVFoundation)
import AVFoundation

final class ClipWriter {
    private let url: URL
    private let maxSeconds: Double
    private let bitsPerSecond: Int
    private let queue = DispatchQueue(label: "kyc.liveness.clipwriter")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstTime: CMTime?
    private var lastTime: CMTime?
    private var armed = false
    private var closed = false

    init(url: URL, maxSeconds: Double = 60, bitsPerSecond: Int = 600_000) {
        self.url = url
        self.maxSeconds = maxSeconds
        self.bitsPerSecond = bitsPerSecond
    }

    func arm() {
        queue.sync { armed = true }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        queue.sync {
            guard armed, !closed, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if writer == nil, !start(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image), at: time) {
                closed = true
                return
            }
            guard let firstTime, let input, input.isReadyForMoreMediaData else { return }
            if CMTimeGetSeconds(CMTimeSubtract(time, firstTime)) > maxSeconds {
                closed = true
                return
            }
            if input.append(sampleBuffer) { lastTime = time }
        }
    }

    func finish() async -> RecordedClip? {
        let state: (AVAssetWriter, CMTime)? = queue.sync {
            closed = true
            guard let writer = self.writer, let input, let lastTime, writer.status == .writing else {
                if self.writer?.status == .writing { self.writer?.cancelWriting() }
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            input.markAsFinished()
            return (writer, lastTime)
        }
        guard let state else { return nil }
        let (writer, end) = state
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return RecordedClip(url: url, contentType: "video/mp4")
    }

    private func start(width: Int, height: Int, at time: CMTime) -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitsPerSecond],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: time)
        self.writer = writer
        self.input = input
        firstTime = time
        return true
    }
}
#endif
