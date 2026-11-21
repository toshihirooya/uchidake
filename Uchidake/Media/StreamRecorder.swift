import AVFoundation
import CoreMedia

/// 音声のコマに時刻を付ける。届いた順に連続で並べ、届いた時刻より 0.2 秒以上遅れたら合わせ直す。
///
/// 届く間隔はゆらぐので、届いた時刻をそのまま使うと音が重なったり途切れたりする。
/// 続けて並べつつ、パケットが抜けたときなどに届いた時刻より大きく遅れたら、届いた時刻まで進める。
/// 進めたぶんは無音で埋める（書き手は時刻を飛ばしても詰めて書くので、埋めないと音が映像より先に進む）。
/// 戻すことはしない（止まったあとにまとめて届いても、前の音に重ねない）。
struct AudioTimeline {
    static let sampleRate: Int32 = 16_000
    static let resyncThreshold = CMTime(value: 1, timescale: 5)

    /// パケットを置く場所
    struct Placement {
        /// パケットの始まりの時刻
        let start: CMTime
        /// パケットの前に入れる無音のサンプル数（0 なら入れない）。無音は `silenceStart` から `start` まで
        let silence: Int

        var silenceStart: CMTime {
            start - CMTime(value: CMTimeValue(silence), timescale: AudioTimeline.sampleRate)
        }
    }

    /// 前のパケットの続きになる時刻
    private var next: CMTime?

    mutating func place(sampleCount: Int, arrival: CMTime) -> Placement {
        var start = arrival
        var silence = 0
        if let next {
            start = next
            if arrival - next >= Self.resyncThreshold {
                // 届いた時刻まで、サンプル単位で進める（音がとぎれずに続くように）
                silence = Int(((arrival - next).seconds * Double(Self.sampleRate)).rounded())
                start = next + CMTime(value: CMTimeValue(silence), timescale: Self.sampleRate)
            }
        }
        next = start + CMTime(value: CMTimeValue(sampleCount), timescale: Self.sampleRate)
        return Placement(start: start, silence: silence)
    }
}

/// 届いたコマをそのまま MP4 に書く。1 つの直列キューの上だけで使う（スレッド安全ではない）。
///
/// 映像は圧縮し直さずに書き、音声（16kHz・モノラル・16 ビットの PCM）は AAC にして書く。
/// 映像の大きさが変わる（SPS・PPS が変わる）とそのままでは書けないので、ファイルを分ける。
///
/// `onFileFinished`・`onFailure`・`finish` の `completion` は、内部の直列キューから、起きた順に呼ぶ。
final class StreamRecorder {
    /// 書き終えたファイルができるたびに呼ばれる（大きさが変わって分かれたとき、`finish` のとき）。
    var onFileFinished: ((URL) -> Void)?
    /// 書き込みに失敗した（以後は何も書かない）。
    var onFailure: (() -> Void)?
    /// 映像を 1 コマでも書いたか。
    private(set) var hasContent = false

    private static let audioBitRate = 32_000

    private let directory: URL
    /// コールバックを順に呼ぶためのキュー。閉じ終えるのを待つあいだ、ここを止める。
    private let callbackQueue = DispatchQueue(label: "StreamRecorder.callbacks")
    private var file: File?
    private var videoFormat: CMFormatDescription?
    private var timeline = AudioTimeline()
    private var hasFailed = false
    private var isFinished = false
    /// 映像のコマを落としたあと。差分のコマは落としたコマを参照して壊れるので、次のキーフレームまで書かない
    private var needsKeyframe = false

    /// テスト用: 映像の入力がコマを受け取れるかの判定を差し替える（nil なら `isReadyForMoreMediaData`）
    var videoReadinessOverride: ((CMTime) -> Bool)?

    private let audioFormat: CMAudioFormatDescription? = {
        var description = AudioStreamBasicDescription(
            mSampleRate: Float64(AudioTimeline.sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        return format
    }()

    /// 書いている途中の 1 つのファイル
    private final class File {
        let writer: AVAssetWriter
        let video: AVAssetWriterInput
        let audio: AVAssetWriterInput
        let partialURL: URL
        let finalURL: URL
        let parameterSets: [Data]
        var hasFrames = false

        init(writer: AVAssetWriter, video: AVAssetWriterInput, audio: AVAssetWriterInput,
             partialURL: URL, finalURL: URL, parameterSets: [Data]) {
            self.writer = writer
            self.video = video
            self.audio = audio
            self.partialURL = partialURL
            self.finalURL = finalURL
            self.parameterSets = parameterSets
        }
    }

    /// `directory` に `recording-<UUID>.partial.mp4` を作りながら書き、
    /// 閉じ終えたら `.partial` を取って `recording-<UUID>.mp4` にする。
    init(directory: URL) {
        self.directory = directory
    }

    /// 最初のキーフレームが来るまでのコマは捨てる。
    /// SPS・PPS が前と変わったら、今のファイルを閉じて、このコマから新しいファイルを始める。
    func appendVideo(_ frame: Data, at time: CMTime) {
        guard !hasFailed, !isFinished else { return }
        let isKeyframe = frame.first == 1
        guard isKeyframe || file != nil else { return }
        guard let sample = VideoFrames.timedSampleBuffer(from: frame, format: &videoFormat, at: time) else {
            // 読めなかったコマも落としたのと同じ
            needsKeyframe = true
            return
        }

        if isKeyframe, let format = sample.formatDescription {
            let sets = Array(format.parameterSets)
            if file?.parameterSets != sets {
                closeFile()
                guard let opened = openFile(format: format, parameterSets: sets, startingAt: time) else {
                    fail()
                    return
                }
                file = opened
            }
        }
        guard let file else { return }
        if isKeyframe {
            needsKeyframe = false
        } else if needsKeyframe {
            return
        }
        // 書き込みが追いつかないときは、そのコマを落とす（遅れをためない）。
        // 後に続く差分のコマは、次のキーフレームが来るまで書かない
        guard videoReadinessOverride?(time) ?? file.video.isReadyForMoreMediaData else {
            needsKeyframe = true
            if !file.hasFrames {
                // 始めのキーフレームを落とした。このファイルは捨て、次のキーフレームの時刻から作り直す
                closeFile()
            }
            return
        }
        guard file.video.append(sample) else {
            fail()
            return
        }
        file.hasFrames = true
        hasContent = true
    }

    /// 映像を書き始める前の音声は捨てる。
    func appendAudio(_ pcm: Data, at time: CMTime) {
        guard !hasFailed, !isFinished, let file, file.hasFrames else { return }
        let sampleCount = pcm.count / 2
        guard sampleCount > 0 else { return }
        let placement = timeline.place(sampleCount: sampleCount, arrival: time)
        guard file.audio.isReadyForMoreMediaData else { return }
        if placement.silence > 0 {
            // 届かなかったあいだを無音で埋める
            guard let silence = makeAudioSample(
                Data(count: placement.silence * 2), sampleCount: placement.silence, at: placement.silenceStart) else { return }
            guard file.audio.append(silence) else {
                fail()
                return
            }
        }
        guard let sample = makeAudioSample(pcm, sampleCount: sampleCount, at: placement.start) else { return }
        if !file.audio.append(sample) {
            fail()
        }
    }

    /// 閉じる。閉じ終えたファイル（0 個以上）の `onFileFinished` をすべて呼んでから `completion` を呼ぶ。
    /// 2 回目以降の呼び出しは、何もせず `completion` だけ呼ぶ。
    func finish(completion: @escaping () -> Void) {
        if !isFinished {
            isFinished = true
            closeFile()
        }
        // それまでに閉じ始めたファイルの知らせは、すべてこのキューに先に積んである
        callbackQueue.async(execute: completion)
    }

    // MARK: - ファイル

    private func openFile(format: CMFormatDescription, parameterSets: [Data], startingAt time: CMTime) -> File? {
        let name = "recording-\(UUID().uuidString)"
        let partialURL = directory.appendingPathComponent("\(name).partial.mp4")
        let finalURL = directory.appendingPathComponent("\(name).mp4")
        guard let writer = try? AVAssetWriter(outputURL: partialURL, fileType: .mp4) else { return nil }

        // 映像は圧縮し直さない（素通し）。形式は届いたキーフレームから渡す
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        video.expectsMediaDataInRealTime = true

        var audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(AudioTimeline.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: Self.audioBitRate,
        ]
        if !writer.canApply(outputSettings: audioSettings, forMediaType: .audio) {
            audioSettings.removeValue(forKey: AVEncoderBitRateKey)
        }
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audio.expectsMediaDataInRealTime = true

        guard writer.canAdd(video), writer.canAdd(audio) else { return nil }
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else {
            try? FileManager.default.removeItem(at: partialURL)
            return nil
        }
        writer.startSession(atSourceTime: time)
        return File(writer: writer, video: video, audio: audio,
                    partialURL: partialURL, finalURL: finalURL, parameterSets: parameterSets)
    }

    /// 今のファイルを閉じ始める。閉じ終えたら `.partial` を取って `onFileFinished` を呼ぶ。
    /// 1 コマも書いていなければ、途中のファイルを消すだけにする。
    private func closeFile() {
        guard let file else { return }
        self.file = nil
        guard file.hasFrames else {
            file.writer.cancelWriting()
            try? FileManager.default.removeItem(at: file.partialURL)
            return
        }

        let closed = DispatchGroup()
        closed.enter()
        file.video.markAsFinished()
        file.audio.markAsFinished()
        file.writer.finishWriting { closed.leave() }

        let report = onFileFinished
        let failure = onFailure
        callbackQueue.async {
            // 閉じ始めた順に知らせるため、このファイルが閉じ終わるまでキューを止めて待つ
            closed.wait()
            if file.writer.status == .completed,
               (try? FileManager.default.moveItem(at: file.partialURL, to: file.finalURL)) != nil {
                report?(file.finalURL)
            } else {
                try? FileManager.default.removeItem(at: file.partialURL)
                failure?()
            }
        }
    }

    /// 書き込みに失敗した。閉じられないファイルは再生できないので消し、以後は何も書かない。
    private func fail() {
        hasFailed = true
        if let file {
            self.file = nil
            file.writer.cancelWriting()
            try? FileManager.default.removeItem(at: file.partialURL)
        }
        let failure = onFailure
        callbackQueue.async { failure?() }
    }

    // MARK: - 音声

    private func makeAudioSample(_ pcm: Data, sampleCount: Int, at time: CMTime) -> CMSampleBuffer? {
        guard let audioFormat else { return nil }
        let length = sampleCount * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block else { return nil }
        let copied = pcm.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == noErr else { return nil }

        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: audioFormat,
            sampleCount: sampleCount, presentationTimeStamp: time, packetDescriptions: nil,
            sampleBufferOut: &sample)
        return sample
    }
}
