import Foundation

/// カメラが 2 秒ごとに見る側へ知らせる、自分の状態。
struct CameraStatus: Codable, Equatable {
    var name: String
    /// 電池残量（0〜100）。分からなければ nil。
    var battery: Int?
    var isCharging: Bool
    /// いま見ている端末の数
    var viewers: Int
    var usesFrontCamera: Bool
    /// 録画中の見る側の数。古い版の通知には無いので、無ければ 0。
    var recorders: Int = 0

    init(name: String, battery: Int?, isCharging: Bool, viewers: Int, usesFrontCamera: Bool, recorders: Int = 0) {
        self.name = name
        self.battery = battery
        self.isCharging = isCharging
        self.viewers = viewers
        self.usesFrontCamera = usesFrontCamera
        self.recorders = recorders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        battery = try container.decodeIfPresent(Int.self, forKey: .battery)
        isCharging = try container.decode(Bool.self, forKey: .isCharging)
        viewers = try container.decode(Int.self, forKey: .viewers)
        usesFrontCamera = try container.decode(Bool.self, forKey: .usesFrontCamera)
        recorders = try container.decodeIfPresent(Int.self, forKey: .recorders) ?? 0
    }

    /// 電池が少なく、充電もされていない
    var needsCharging: Bool {
        guard let battery else { return false }
        return battery <= 20 && !isCharging
    }
}

/// 見る側からカメラへの操作
enum CameraCommand: UInt8 {
    case switchCamera = 1
}

/// DTLS の中を流れる 1 データグラムの組み立てと読み取り（docs/spec.md の5章）。
/// 先頭 1 バイトが種類。数値はビッグエンディアン。
enum MediaPacket: Equatable {
    case video(frameID: UInt32, index: Int, count: Int, payload: Data)
    case audio(sequence: UInt32, pcm: Data)
    case keyframeRequest
    /// 見る側の生存通知。フラグのビット 0 が「録画中」。
    case keepAlive(isRecording: Bool)
    case status(CameraStatus)
    case command(CameraCommand, sequence: UInt32)

    private enum Kind: UInt8 {
        case video = 1, audio, keyframeRequest, keepAlive, status, command
    }

    /// 1 パケットに入れる映像データの上限。経路の MTU（約1500）に DTLS などの分の余裕を見た値。
    static let maxFragmentSize = 1100

    /// 1 フレームを、送れる大きさのパケットに分ける。
    static func videoPackets(frame: Data, frameID: UInt32) -> [Data] {
        let count = (frame.count + maxFragmentSize - 1) / maxFragmentSize
        guard count > 0, count <= Int(UInt16.max) else { return [] }
        return (0..<count).map { index in
            let start = frame.startIndex + index * maxFragmentSize
            let end = min(start + maxFragmentSize, frame.endIndex)
            return MediaPacket.video(frameID: frameID, index: index, count: count, payload: frame[start..<end]).encoded()
        }
    }

    func encoded() -> Data {
        switch self {
        case .video(let frameID, let index, let count, let payload):
            var data = Data([Kind.video.rawValue])
            data.append(bigEndian: frameID)
            data.append(bigEndian: UInt16(truncatingIfNeeded: index))
            data.append(bigEndian: UInt16(truncatingIfNeeded: count))
            data.append(payload)
            return data
        case .audio(let sequence, let pcm):
            var data = Data([Kind.audio.rawValue])
            data.append(bigEndian: sequence)
            data.append(pcm)
            return data
        case .keyframeRequest:
            return Data([Kind.keyframeRequest.rawValue])
        case .keepAlive(let isRecording):
            return Data([Kind.keepAlive.rawValue, isRecording ? 1 : 0])
        case .status(let status):
            var data = Data([Kind.status.rawValue])
            data.append((try? JSONEncoder().encode(status)) ?? Data())
            return data
        case .command(let command, let sequence):
            var data = Data([Kind.command.rawValue])
            data.append(bigEndian: sequence)
            data.append(command.rawValue)
            return data
        }
    }

    /// 受け取ったデータグラムを読む。形式が合わなければ nil。
    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard let first = bytes.first, let kind = Kind(rawValue: first) else { return nil }
        switch kind {
        case .video:
            guard bytes.count > 9 else { return nil }
            self = .video(
                frameID: Self.uint32(bytes, at: 1),
                index: Int(bytes[5]) << 8 | Int(bytes[6]),
                count: Int(bytes[7]) << 8 | Int(bytes[8]),
                payload: Data(bytes[9...]))
        case .audio:
            guard bytes.count > 5 else { return nil }
            self = .audio(sequence: Self.uint32(bytes, at: 1), pcm: Data(bytes[5...]))
        case .keyframeRequest:
            self = .keyframeRequest
        case .keepAlive:
            // 古い版はフラグが無い。無ければ録画していない。ビット 0 以外は無視する。
            self = .keepAlive(isRecording: bytes.count > 1 && bytes[1] & 1 != 0)
        case .status:
            guard let status = try? JSONDecoder().decode(CameraStatus.self, from: Data(bytes[1...])) else { return nil }
            self = .status(status)
        case .command:
            guard bytes.count == 6, let command = CameraCommand(rawValue: bytes[5]) else { return nil }
            self = .command(command, sequence: Self.uint32(bytes, at: 1))
        }
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    mutating func append(bigEndian value: UInt16) {
        append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)])
    }
}

/// 届いた映像の断片を 1 フレームに戻し、そのフレームを表示してよいかを決める。
///
/// UDP は届かないことも、順番が入れ替わることもある。再送はしないので、
/// そろわなかったフレームは捨てる。差分フレームは直前のフレームを元に復元するため、
/// 途中が抜けたら次のキーフレームが来るまで表示を止める。
struct VideoAssembler {
    enum Result: Equatable {
        /// まだ 1 フレームぶんそろっていない（または捨てた）
        case incomplete
        /// そろった。表示してよい。
        case show(Data)
        /// そろったが、キーフレームを待っているので表示できない。カメラにキーフレームを頼むこと。
        case waitForKeyframe
    }

    private var assemblingID: UInt32?
    private var assemblingCount = 0
    private var fragments: [Int: Data] = [:]
    private var lastFrameID: UInt32?
    private var needsKeyframe = true

    /// 表示に失敗したとき（復元できなかったとき）に呼ぶ。次のキーフレームまで待つようになる。
    mutating func decodeFailed() {
        needsKeyframe = true
    }

    mutating func receive(frameID: UInt32, index: Int, count: Int, payload: Data) -> Result {
        guard count > 0, index >= 0, index < count else { return .incomplete }
        // すでに終えたフレームより古い断片は、遅れて届いたものなので捨てる
        if let lastFrameID, frameID <= lastFrameID, lastFrameID - frameID < 1_000_000 { return .incomplete }

        if assemblingID != frameID {
            // 新しいフレームが始まった。そろわなかった前のフレームはあきらめる。
            assemblingID = frameID
            assemblingCount = count
            fragments.removeAll(keepingCapacity: true)
        }
        guard count == assemblingCount else { return .incomplete }
        fragments[index] = payload
        guard fragments.count == assemblingCount else { return .incomplete }

        var frame = Data()
        for part in 0..<assemblingCount {
            frame.append(fragments[part] ?? Data())
        }
        assemblingID = nil
        fragments.removeAll(keepingCapacity: true)

        let isKeyframe = frame.first == 1
        if let lastFrameID, frameID != lastFrameID &+ 1, !isKeyframe {
            needsKeyframe = true
        }
        lastFrameID = frameID
        if needsKeyframe && !isKeyframe {
            return .waitForKeyframe
        }
        needsKeyframe = false
        return .show(frame)
    }
}
