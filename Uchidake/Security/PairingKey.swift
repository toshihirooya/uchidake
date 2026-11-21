import CoreImage
import Foundation
import Network
import Security
import UIKit

/// 端末どうしで共有する鍵（DTLS の PSK）。最初の 1 台がランダムに作り、
/// ほかの端末へは QR コードで渡す。仕様は docs/spec.md の4章。
enum PairingKey {
    static let keyLength = 32
    /// QR コードの中身の先頭。URL スキームにはしない（標準のカメラアプリで読んでも何も開かないようにする）。
    static let codePrefix = "UCHIDAKE1:"

    private static let service = "com.example.Uchidake.psk"
    private static let account = "v2"

    /// 新しい鍵を作る。
    static func generate() -> Data? {
        var bytes = [UInt8](repeating: 0, count: keyLength)
        guard SecRandomCopyBytes(kSecRandomDefault, keyLength, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }

    // MARK: - QR コードの中身

    /// 鍵を、パディング無しの base64url にする（検証用の起動オプションでも使う）。
    static func base64URL(_ key: Data) -> String {
        key.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func key(base64URL text: String) -> Data? {
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return nil
        }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), data.count == keyLength else { return nil }
        return data
    }

    static func code(for key: Data) -> String {
        codePrefix + base64URL(key)
    }

    /// 読み取った文字列から鍵を取り出す。うちだけカメラの QR コードでなければ nil。
    static func key(fromCode code: String) -> Data? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(codePrefix) else { return nil }
        return key(base64URL: String(trimmed.dropFirst(codePrefix.count)))
    }

    /// 鍵の QR コードの画像を作る。
    static func qrImage(for key: Data, side: CGFloat = 720) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(code(for: key).utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        // ぼやけないように、整数倍に引き伸ばす
        let scale = max(1, (side / output.extent.width).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // 小さな画像 1 枚なので CPU で描く（GPU の準備を待たない）
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - キーチェーン

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func load() -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == keyLength else { return nil }
        return data
    }

    @discardableResult
    static func save(_ key: Data) -> Bool {
        guard key.count == keyLength else { return false }
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = key
        // この端末だけに置く（iCloud キーチェーンやバックアップで他の端末へ移さない）
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete() -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// カメラと見る側をつなぐ接続の設定。UDP の上に、共有鍵を使った DTLS を張る。
enum MediaSecurity {
    /// Info.plist の NSBonjourServices と一致させること
    static let serviceType = "_uchidake._udp"
    private static let identity = "Uchidake-v2"

    /// 両端が同じ鍵を持っているときだけ、ハンドシェイクが成立する。
    static func parameters(key: Data) -> NWParameters {
        let dtls = NWProtocolTLS.Options()
        let security = dtls.securityProtocolOptions
        let pskData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let pskIdentity = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(security, pskData as __DispatchData, pskIdentity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            security, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(security, .DTLSv12)
        sec_protocol_options_set_max_tls_protocol_version(security, .DTLSv12)

        let parameters = NWParameters(dtls: dtls, udp: NWProtocolUDP.Options())
        // Wi-Fi ルーターが無くても端末同士が直接つながるようにする（AWDL）。
        // シミュレータには AWDL が無いので実機だけで有効にする。
        #if !targetEnvironment(simulator)
        parameters.includePeerToPeer = true
        #endif
        return parameters
    }
}
