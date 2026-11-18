import CommonCrypto
import Foundation
import Network
import Security

/// 合言葉から作る共有鍵（DTLS の PSK）と、そのキーチェーンへの保管。
/// 仕様は docs/spec.md の4章。
enum PassphraseKey {
    static let minimumLength = 8
    private static let salt = Data("Uchidake-v1-psk".utf8)
    private static let iterations: UInt32 = 210_000
    private static let keyLength = 32

    private static let service = "com.example.Uchidake.psk"
    private static let account = "v1"

    /// 入力の揺れ（前後の空白、濁点の合成のしかた）で鍵が変わらないようにそろえる。
    static func normalize(_ passphrase: String) -> String {
        passphrase.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    static func isValid(_ passphrase: String) -> Bool {
        normalize(passphrase).count >= minimumLength
    }

    /// 覚えなくてよい人向けに、入力しやすい合言葉を作る（例: `k7m2-x9qd-4pwe`）。
    /// 見間違えやすい文字（0 と o、1 と l など）は使わない。
    static func suggestion() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        var generator = SystemRandomNumberGenerator()
        let groups = (0..<3).map { _ in
            String((0..<4).map { _ in alphabet.randomElement(using: &generator)! })
        }
        return groups.joined(separator: "-")
    }

    /// PBKDF2-HMAC-SHA256 で 32 バイトの鍵を作る。数百ミリ秒かかるのでメインスレッドでは呼ばない。
    static func derive(from passphrase: String) -> Data? {
        let password = Array(normalize(passphrase).utf8)
        guard !password.isEmpty else { return nil }
        var key = [UInt8](repeating: 0, count: keyLength)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                password.map { Int8(bitPattern: $0) }, password.count,
                saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                iterations,
                &key, keyLength
            )
        }
        return status == kCCSuccess ? Data(key) : nil
    }

    // MARK: - キーチェーン

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func load() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == keyLength else { return nil }
        return data
    }

    @discardableResult
    static func save(_ key: Data) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = key
        // この端末だけに置く（iCloud キーチェーンやバックアップで他の端末へ移さない）
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}

/// カメラと見る側をつなぐ接続の設定。UDP の上に、合言葉の鍵を使った DTLS を張る。
enum MediaSecurity {
    /// Info.plist の NSBonjourServices と一致させること
    static let serviceType = "_uchidake._udp"
    private static let identity = "Uchidake-v1"

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
