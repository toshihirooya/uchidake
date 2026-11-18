import AVFoundation
import CoreMedia
import VideoToolbox

/// カメラの画像を H.264 に圧縮する。カメラ側で使う。
///
/// 出力する1フレームのバイト列:
///   [0]      1 = キーフレーム / 0 = 差分フレーム
///   キーフレームのときだけ: SPS の長さ(2) + SPS + PPS の長さ(2) + PPS
///   残り     圧縮データ（各 NAL の前に4バイトの長さが付いた AVCC 形式）
final class H264Encoder {
    /// 圧縮が終わるたびに呼ばれる（VideoToolbox のスレッド上）
    var onFrame: ((Data) -> Void)?

    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private let lock = NSLock()
    private var wantsKeyframe = true

    /// 次のフレームをキーフレームにする。相手が映像を復元できなくなったときに使う。
    func requestKeyframe() {
        lock.lock()
        wantsKeyframe = true
        lock.unlock()
    }

    func encode(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        let w = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let h = Int32(CVPixelBufferGetHeight(pixelBuffer))
        if session == nil || w != width || h != height {
            makeSession(width: w, height: h)
        }
        guard let session else { return }

        lock.lock()
        let force = wantsKeyframe
        wantsKeyframe = false
        lock.unlock()
        let properties = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil

        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: time, duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let frame = Self.serialize(sampleBuffer) else { return }
            self?.onFrame?(frame)
        }
    }

    func stop() {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    private func makeSession(width: Int32, height: Int32) {
        stop()
        var created: VTCompressionSession?
        VTCompressionSessionCreate(
            allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard let created else { return }
        // 中継向けの設定: 遅延を出さない、フレームの並べ替え（Bフレーム）をしない
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate, value: 800_000 as CFNumber)
        // パケットが欠けても2秒以内に立ち直れるよう、定期的にキーフレームを入れる
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
        self.width = width
        self.height = height
        requestKeyframe()
    }

    private static func serialize(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard let format = sampleBuffer.formatDescription,
              let body = try? sampleBuffer.dataBuffer?.dataBytes() else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)

        var frame = Data()
        if isKeyframe {
            // 復元に必要な設定情報（SPS / PPS）はキーフレームに毎回付ける
            let sets = format.parameterSets
            guard sets.count >= 2 else { return nil }
            frame.append(1)
            for set in sets.prefix(2) {
                frame.append(UInt8(set.count >> 8))
                frame.append(UInt8(set.count & 0xFF))
                frame.append(set)
            }
        } else {
            frame.append(0)
        }
        frame.append(body)
        return frame
    }
}

/// 受け取ったフレームや撮った画像を、画面表示用の CMSampleBuffer にする。
/// 表示は AVSampleBufferDisplayLayer に任せる（H.264 の復元もそこで行われる）。
enum VideoFrames {
    /// `H264Encoder` が作ったフレームから。`format` はキーフレームを受けるたびに更新される。
    static func compressedSampleBuffer(from frame: Data, format: inout CMFormatDescription?) -> CMSampleBuffer? {
        let bytes = [UInt8](frame)
        guard !bytes.isEmpty else { return nil }
        var offset = 1
        if bytes[0] == 1 {
            var sets: [Data] = []
            for _ in 0..<2 {
                guard offset + 2 <= bytes.count else { return nil }
                let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                offset += 2
                guard offset + length <= bytes.count else { return nil }
                sets.append(Data(bytes[offset..<offset + length]))
                offset += length
            }
            format = try? CMVideoFormatDescription(h264ParameterSets: sets, nalUnitHeaderLength: 4)
        }
        guard let format, offset < bytes.count else { return nil }
        let length = bytes.count - offset

        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block else { return nil }
        bytes.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress! + offset, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = length
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer)
        if let sampleBuffer {
            markDisplayImmediately(sampleBuffer)
        }
        return sampleBuffer
    }

    /// 圧縮していない画像から（自分の映像のプレビュー用）
    static func rawSampleBuffer(from pixelBuffer: CVPixelBuffer, at time: CMTime) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
        if let sampleBuffer {
            markDisplayImmediately(sampleBuffer)
        }
        return sampleBuffer
    }

    /// 時刻合わせをせず、届いたらすぐ表示させる（遅れないことを優先する）
    private static func markDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(array) > 0 else { return }
        let attachments = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            attachments,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
}
