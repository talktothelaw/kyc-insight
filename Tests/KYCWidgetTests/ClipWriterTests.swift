#if canImport(AVFoundation) && canImport(UIKit)
import XCTest
import AVFoundation
@testable import KYCWidget

final class ClipWriterTests: XCTestCase {
    private func sampleBuffer(at seconds: Double) -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer!, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer!, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &buffer)
        return buffer!
    }

    private func feed(_ writer: ClipWriter, frames: Range<Int>) async throws {
        for i in frames {
            writer.append(sampleBuffer(at: Double(i) / 30))
            try await Task.sleep(nanoseconds: 33_000_000)
        }
    }

    func testWritesAPlayableMp4() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let writer = ClipWriter(url: url)
        writer.arm()
        try await feed(writer, frames: 0..<30)
        let clip = await writer.finish()
        XCTAssertEqual(clip?.contentType, "video/mp4")
        XCTAssertGreaterThan(clip?.sizeBytes ?? 0, 0)
        let duration = try await AVURLAsset(url: url).load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0.5)
    }

    func testStopsAppendingAtTheCap() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let writer = ClipWriter(url: url, maxSeconds: 1)
        writer.arm()
        try await feed(writer, frames: 0..<90)
        _ = await writer.finish()
        let duration = try await AVURLAsset(url: url).load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0.5)
        XCTAssertLessThanOrEqual(duration.seconds, 1.1)
    }

    func testFinishWithoutFramesReturnsNil() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let clip = await ClipWriter(url: url).finish()
        XCTAssertNil(clip)
    }

    func testIgnoresFramesUntilArmed() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let writer = ClipWriter(url: url)
        for i in 0..<30 { writer.append(sampleBuffer(at: Double(i) / 30)) }
        writer.arm()
        try await feed(writer, frames: 30..<60)
        let clip = await writer.finish()
        XCTAssertNotNil(clip)
        let duration = try await AVURLAsset(url: url).load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0.5)
        XCTAssertLessThanOrEqual(duration.seconds, 1.1)
    }

    func testUnarmedFinishReturnsNilAndLeavesNoFile() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let writer = ClipWriter(url: url)
        for i in 0..<30 { writer.append(sampleBuffer(at: Double(i) / 30)) }
        let clip = await writer.finish()
        XCTAssertNil(clip)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
#endif
