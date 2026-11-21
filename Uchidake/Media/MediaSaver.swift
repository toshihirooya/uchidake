import Foundation
import Observation
import Photos

/// 「写真」アプリとのやり取り。テストでは偽物に差し替える。
protocol PhotoLibrary {
    /// 「追加のみ」の許可。未回答なら求める。
    func requestAddPermission() async -> Bool
    /// いま許可されているか（求めない）。
    var hasAddPermission: Bool { get }
    func addPhoto(_ jpeg: Data) async throws
    func addVideo(at url: URL) async throws
}

/// PHPhotoLibrary（追加のみ）を使う本物。
struct SystemPhotoLibrary: PhotoLibrary {
    private struct SaveFailed: Error {}

    private static func isAllowed(_ status: PHAuthorizationStatus) -> Bool {
        status == .authorized || status == .limited
    }

    func requestAddPermission() async -> Bool {
        Self.isAllowed(await PHPhotoLibrary.requestAuthorization(for: .addOnly))
    }

    var hasAddPermission: Bool {
        Self.isAllowed(PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }

    func addPhoto(_ jpeg: Data) async throws {
        try await perform {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: jpeg, options: nil)
        }
    }

    func addVideo(at url: URL) async throws {
        try await perform {
            let options = PHAssetResourceCreationOptions()
            // 消すかどうかは MediaSaver が決める（失敗したら残す）
            options.shouldMoveFile = false
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: options)
        }
    }

    private func perform(_ changes: @escaping () -> Void) async throws {
        try await PHPhotoLibrary.shared().performChanges(changes)
    }
}

/// 写真と動画を「写真」に入れる。見ている画面より長く生きる（アプリ全体で 1 つ）。
@MainActor
@Observable
final class MediaSaver {
    enum Notice: Equatable {
        case photoSaved, videoSaved, photoFailed, videoFailed, permissionDenied, lowStorage
    }

    /// 録画を始める・続けるのに必要な空き容量
    static let minimumFreeBytes: Int64 = 200_000_000
    /// 知らせを出しておく長さ（秒）
    private static let noticeSeconds: UInt64 = 3

    /// Application Support の中の `Recordings`。無ければ作る。バックアップの対象から外す。
    nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var directory = base.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return directory
    }

    let directory: URL

    /// いま出す知らせ。出してから 3 秒で nil に戻る。
    private(set) var notice: Notice?
    /// 保存の途中の動画の数（画面が「保存中」を出すため）。
    private(set) var pendingVideos = 0

    @ObservationIgnored private let library: PhotoLibrary
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(library: PhotoLibrary = SystemPhotoLibrary(), directory: URL = MediaSaver.defaultDirectory) {
        self.library = library
        self.directory = directory
    }

    /// 許可を確かめる。断られていたら notice を `.permissionDenied` にして false。
    func ensurePermission() async -> Bool {
        if await library.requestAddPermission() { return true }
        report(.permissionDenied)
        return false
    }

    /// 空き容量が足りるか。足りなければ notice を `.lowStorage` にして false。
    /// 空きを調べられないときは止めない。
    func ensureStorage() -> Bool {
        if let free = Self.freeBytes(at: directory), free < Self.minimumFreeBytes {
            report(.lowStorage)
            return false
        }
        return true
    }

    /// `directory` のあるボリュームの空き。
    nonisolated static func freeBytes(at directory: URL) -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    func savePhoto(_ jpeg: Data) async {
        do {
            try await library.addPhoto(jpeg)
            report(.photoSaved)
        } catch {
            report(.photoFailed)
        }
    }

    /// 成功したらファイルを消す。失敗したら残す（次の起動で `recoverLeftovers` が拾う）。
    func saveVideo(at url: URL) async {
        pendingVideos += 1
        defer { pendingVideos -= 1 }
        do {
            try await library.addVideo(at: url)
            try? FileManager.default.removeItem(at: url)
            report(.videoSaved)
        } catch {
            report(.videoFailed)
        }
    }

    /// 起動時に 1 回呼ぶ。`*.partial.mp4` を消し、残っている `*.mp4` をもう一度追加する。
    /// 許可が無いときは何もしない（ファイルは残す。許可は求めない）。
    func recoverLeftovers() async {
        guard library.hasAddPermission else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "mp4" {
            if url.lastPathComponent.hasSuffix(".partial.mp4") {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            // 起動時に黙って戻す。知らせは出さない
            if (try? await library.addVideo(at: url)) != nil {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// エンジン側で起きたこと（容量が減って止めた、写真を復元できなかった）を知らせとして出す。
    func report(_ notice: Notice) {
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.noticeSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
