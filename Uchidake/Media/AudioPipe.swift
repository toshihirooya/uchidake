import AVFoundation

/// 音声。マイクの音を取り込んで送れる形にし、届いた音をスピーカーから鳴らす。
///
/// 回線に流す形式は 16kHz・モノラル・16ビットの無圧縮 PCM。
/// 圧縮しないぶん単純で、家の中の通信なら帯域（約 256kbps）も問題にならない。
///
/// マイクを使うかどうかは `start` で決める。使わないときは再生だけを行い、
/// 端末のマイク使用中の表示も出ない。
///
/// シミュレータでは、Mac のマイクとスピーカーを複数のシミュレータが共有してハウリングするため、
/// マイクも再生も使わない。代わりに、マイクを使う設定のときだけ2秒ごとの短い確認音を送る。
///
/// `start` / `stop` / `play` は、同じ直列キューの上から呼ぶこと。
final class AudioPipe {
    static let sampleRate: Double = 16_000
    /// 1パケットに入れる最大サンプル数（30ミリ秒ぶん）
    private static let samplesPerPacket = 480

    /// 送る音声データができるたびに呼ばれる（音声のスレッド上）
    var onPacket: ((Data) -> Void)?
    /// 届いた音を鳴らさない
    var isSpeakerMuted = false {
        didSet { player?.volume = isSpeakerMuted ? 0 : 1 }
    }

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let playFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioPipe.sampleRate, channels: 1, interleaved: false)!
    private let wireFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: AudioPipe.sampleRate, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var pendingBuffers = 0
    private var timer: DispatchSourceTimer?
    private var tonePhase = 0

    /// - Parameter useMicrophone: マイクの音を取り込んで `onPacket` に渡すか
    func start(useMicrophone: Bool) {
        stop()
        #if targetEnvironment(simulator)
        if useMicrophone {
            startTestTone()
        }
        #else
        startEngine(useMicrophone: useMicrophone)
        #endif
    }

    func stop() {
        timer?.cancel()
        timer = nil
        guard let engine else { return }
        if converter != nil {
            engine.inputNode.removeTap(onBus: 0)
        }
        player?.stop()
        engine.stop()
        self.engine = nil
        player = nil
        converter = nil
        lock.lock()
        pendingBuffers = 0
        lock.unlock()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 届いた音声データを鳴らす。
    func play(_ data: Data) {
        guard let player else { return }
        let count = data.count / 2
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(count)) else { return }

        // 再生待ちがたまりすぎたら捨てる。ためると、その分だけ音が遅れて聞こえ続ける。
        lock.lock()
        let tooMany = pendingBuffers >= 8
        if !tooMany { pendingBuffers += 1 }
        lock.unlock()
        guard !tooMany else { return }

        buffer.frameLength = AVAudioFrameCount(count)
        let output = buffer.floatChannelData![0]
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<count {
                output[index] = Float(Int16(littleEndian: samples[index])) / 32768
            }
        }
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pendingBuffers = max(0, self.pendingBuffers - 1)
            self.lock.unlock()
        }
    }

    // MARK: - 実機

    private func startEngine(useMicrophone: Bool) {
        // マイクの許可が無ければ、再生だけにする
        let captures = useMicrophone && AVAudioApplication.shared.recordPermission == .granted
        let session = AVAudioSession.sharedInstance()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        do {
            if captures {
                try session.setCategory(.playAndRecord, mode: .videoChat, options: [.defaultToSpeaker])
            } else {
                try session.setCategory(.playback, mode: .spokenAudio)
            }
            try session.setActive(true)
            if captures {
                // スピーカーから出た相手の声をマイクが拾って送り返さないようにする（エコー除去）
                try engine.inputNode.setVoiceProcessingEnabled(true)
            }
        } catch {
            return
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        if captures {
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            if inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: wireFormat) {
                self.converter = converter
                input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                    self?.capture(buffer, inputFormat: inputFormat, converter: converter)
                }
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            if converter != nil {
                engine.inputNode.removeTap(onBus: 0)
                converter = nil
            }
            return
        }
        player.volume = isSpeakerMuted ? 0 : 1
        player.play()
        self.engine = engine
        self.player = player
    }

    /// マイクの音を回線用の形式に変換し、小分けにして送る。
    private func capture(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, converter: AVAudioConverter) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / inputFormat.sampleRate) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, converted.frameLength > 0, let samples = converted.int16ChannelData?[0] else { return }

        var offset = 0
        let total = Int(converted.frameLength)
        while offset < total {
            let count = min(Self.samplesPerPacket, total - offset)
            onPacket?(Data(bytes: samples + offset, count: count * 2))
            offset += count
        }
    }

    // MARK: - シミュレータ

    private func startTestTone() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "uchidake.audio.tone"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(30))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            var samples = [Int16](repeating: 0, count: Self.samplesPerPacket)
            // 2秒のうち最初の 0.12 秒だけ、小さめの 880Hz を鳴らす
            for index in 0..<samples.count {
                let position = self.tonePhase + index
                if position % Int(Self.sampleRate * 2) < Int(Self.sampleRate * 0.12) {
                    samples[index] = Int16(3000 * sin(2 * Double.pi * 880 * Double(position) / Self.sampleRate))
                }
            }
            self.tonePhase += samples.count
            self.onPacket?(samples.withUnsafeBufferPointer { Data(buffer: $0) })
        }
        timer.resume()
        self.timer = timer
    }
}
