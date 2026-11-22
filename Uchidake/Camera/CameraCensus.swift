import CryptoKit
import Foundation
import Network

/// カメラが Bonjour の広告（TXT レコード）に載せる情報（docs/spec.md の3章）。
///
/// 家族プランの無いカメラが、同じ鍵の組にすでにいるかを、つながずに数えるために使う。
struct CameraAdvert: Equatable {
    /// 組の目印。鍵から作るが、鍵は逆算できない。
    var familyTag: String
    /// この端末で家族プランが有効か
    var hasPlan: Bool
    /// 起動時の確認を終えて動いているか（確認中は false）
    var isRunning: Bool
    /// この端末を最初にカメラにした時刻（UNIX 秒）
    var since: Int
    /// この端末の ID
    var deviceID: String

    init(familyTag: String, hasPlan: Bool, isRunning: Bool, since: Int, deviceID: String) {
        self.familyTag = familyTag
        self.hasPlan = hasPlan
        self.isRunning = isRunning
        self.since = since
        self.deviceID = deviceID
    }

    /// 欠けていたり読めなかったりすれば nil（ほかのアプリや古い版の広告）。
    init?(txt: [String: String]) {
        guard let familyTag = txt["f"], let plan = Self.flag(txt["p"]), let running = Self.flag(txt["r"]),
              let since = txt["s"].flatMap(Int.init), let deviceID = txt["i"], !deviceID.isEmpty else { return nil }
        self.init(familyTag: familyTag, hasPlan: plan, isRunning: running, since: since, deviceID: deviceID)
    }

    var txt: [String: String] {
        ["f": familyTag, "p": hasPlan ? "1" : "0", "r": isRunning ? "1" : "0", "s": String(since), "i": deviceID]
    }

    /// HMAC-SHA256(鍵, "Uchidake-v2-family-tag") の先頭 8 バイトを、小文字の 16 進で。
    static func familyTag(key: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("Uchidake-v2-family-tag".utf8), using: SymmetricKey(data: key))
        return mac.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func flag(_ value: String?) -> Bool? {
        switch value {
        case "1": true
        case "0": false
        default: nil
        }
    }
}

/// 家族プランの無いカメラを始めてよいかの判断と、そのための探索。
///
/// 決まり: 家族プランの無いカメラは、同じ鍵の組に 1 台まで。
enum CameraCensus {
    enum Decision: Equatable {
        case start
        /// 同じ組で、家族プランの無いカメラがすでにいる（その広告名）
        case blocked(by: String)
    }

    /// - Parameter others: 探索で見つかった（広告名, 広告）。自分自身や、読めなかった広告が混ざっていてよい
    static func decide(me: CameraAdvert, others: [(name: String, advert: CameraAdvert?)]) -> Decision {
        guard !me.hasPlan else { return .start }
        // 判断できないもの（読めない・別の組）と、自分自身、家族プランのあるカメラは数えない
        let rivals = others.compactMap { other -> (name: String, advert: CameraAdvert)? in
            guard let advert = other.advert, advert.deviceID != me.deviceID,
                  advert.familyTag == me.familyTag, !advert.hasPlan else { return nil }
            return (other.name, advert)
        }
        .sorted { $0.name < $1.name }
        if let running = rivals.first(where: { $0.advert.isRunning }) {
            return .blocked(by: running.name)
        }
        // 同時に始めようとしている相手とは、先にカメラになったほうが残る
        if let older = rivals.first(where: { ($0.advert.since, $0.advert.deviceID) < (me.since, me.deviceID) }) {
            return .blocked(by: older.name)
        }
        return .start
    }

    /// 広告に出ているカメラが、いま本当に動いているか。その名前へつないで、ハンドシェイクが通るかで確かめる。
    ///
    /// Bonjour の広告は、電池切れなどで消えたカメラのものがしばらく残る。
    /// それで「すでにカメラがいる」と止めないために、止める前に確かめる。
    @MainActor
    static func isReachable(name: String, key: Data) async -> Bool {
        let connection = NWConnection(
            to: .service(name: name, type: MediaSecurity.serviceType, domain: "local.", interface: nil),
            using: MediaSecurity.parameters(key: key))
        let reached = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var answered = false
            func answer(_ value: Bool) {
                guard !answered else { return }
                answered = true
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: answer(true)
                case .failed, .cancelled: answer(false)
                default: break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { answer(false) }
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        return reached
    }

    /// しばらく探して、見つかったカメラの広告を返す。探せなければ空（＝止めずに始めることになる）。
    @MainActor
    static func survey(seconds: TimeInterval = 2) async -> [(name: String, advert: CameraAdvert?)] {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: MediaSecurity.serviceType, domain: nil), using: parameters)
        browser.start(queue: .main)
        try? await Task.sleep(for: .seconds(seconds))
        let results = browser.browseResults
        browser.cancel()
        return results.compactMap { result in
            guard case .service(let name, _, _, _) = result.endpoint else { return nil }
            guard case .bonjour(let record) = result.metadata else { return (name, nil) }
            return (name, CameraAdvert(txt: record.dictionary))
        }
    }
}
