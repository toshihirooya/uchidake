import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// 最後のキーフレームから最新のコマまでを覚える。
/// 写真を撮るときは、これを頭から復元すれば今見えている 1 枚になる。
struct GopBuffer {
    private(set) var frames: [Data] = []

    /// キーフレーム（先頭バイトが 1）なら、それまでを捨ててから足す。
    /// キーフレームをまだ 1 つも受けていなければ、差分のコマは足さない。
    mutating func append(_ frame: Data) {
        if frame.first == 1 {
            frames = [frame]
        } else if !frames.isEmpty {
            frames.append(frame)
        }
    }

    mutating func reset() {
        frames = []
    }

    var isEmpty: Bool { frames.isEmpty }
}

/// 届いた H.264 のコマから、写真にする 1 枚を復元する。
enum StillDecoder {
    /// コマを順に復元して、最後の 1 枚を返す。先頭がキーフレームでなければ nil。
    /// 呼んだスレッドで最後まで待つ（`VTDecompressionSessionWaitForAsynchronousFrames`）。
    /// 途中のコマが壊れていたら、そこで止めて、その手前までで最後に復元できた 1 枚を返す。
    static func lastImage(from frames: [Data]) -> CGImage? {
        guard frames.first?.first == 1 else { return nil }

        var format: CMFormatDescription?
        var samples: [CMSampleBuffer] = []
        for (index, frame) in frames.enumerated() {
            let time = CMTime(value: CMTimeValue(index), timescale: 30)
            guard let sample = VideoFrames.timedSampleBuffer(from: frame, format: &format, at: time) else { break }
            samples.append(sample)
        }
        guard let firstFormat = samples.first?.formatDescription else { return nil }

        var created: VTDecompressionSession?
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        VTDecompressionSessionCreate(
            allocator: nil, formatDescription: firstFormat, decoderSpecification: nil,
            imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &created)
        guard let session = created else { return nil }
        defer { VTDecompressionSessionInvalidate(session) }

        let latest = LatestImage()
        for sample in samples {
            let status = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
            ) { status, _, imageBuffer, _, _ in
                if status == noErr, let imageBuffer {
                    latest.set(imageBuffer)
                } else {
                    latest.markFailed()
                }
            }
            if status != noErr || latest.failed { break }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)

        guard let buffer = latest.buffer else { return nil }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        return image
    }

    /// 品質 0.9 の JPEG。
    static func jpegData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// 復元の出力（VideoToolbox のスレッドから呼ばれることがある）を受け取る入れ物
    private final class LatestImage {
        private let lock = NSLock()
        private var storedBuffer: CVImageBuffer?
        private var storedFailed = false

        var buffer: CVImageBuffer? { lock.withLock { storedBuffer } }
        var failed: Bool { lock.withLock { storedFailed } }

        func set(_ buffer: CVImageBuffer) { lock.withLock { storedBuffer = buffer } }
        func markFailed() { lock.withLock { storedFailed = true } }
    }
}
