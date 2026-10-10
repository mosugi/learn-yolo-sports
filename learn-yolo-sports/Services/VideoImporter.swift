//
//  VideoImporter.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/10.
//

import AVFoundation
import Foundation
import PhotosUI
import SwiftUI

/// 読み込んだ動画の基本情報
nonisolated struct VideoInfo: Sendable {
    /// 長さ（秒）
    let duration: Double
    /// 解像度（回転補正なし）
    let size: CGSize
    /// フレームレート
    let frameRate: Float
    /// ファイルサイズ（バイト）
    let fileSize: Int64?

    /// 抽出設定から解析対象のフレーム数を見積もる（VideoFrameExtractor と同じ間引き方）
    func expectedFrameCount(fps: Int, maxFrames: Int) -> Int {
        let interval = max(1, Int(frameRate) / max(1, fps))
        let sourceFrames = Int((duration * Double(frameRate)).rounded(.up))
        let extracted = Int((Double(sourceFrames) / Double(interval)).rounded(.up))
        return max(1, min(maxFrames, extracted))
    }

    /// 動画の情報を読み込む
    static func load(from url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw FrameExtractionError.noVideoTrack
        }
        let size = try await track.load(.naturalSize)
        let frameRate = try await track.load(.nominalFrameRate)
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        return VideoInfo(
            duration: CMTimeGetSeconds(duration),
            size: size,
            frameRate: frameRate,
            fileSize: fileSize
        )
    }
}

/// フォトライブラリからの動画読み込み（iCloud からのダウンロードとコピー）の進捗を管理する
///
/// PhotosPickerItem.loadTransferable が返す Progress を監視して、ローディングバーに反映する。
@MainActor
@Observable
final class VideoImporter {

    /// 読み込み中か
    private(set) var isLoading = false
    /// 進捗（0.0〜1.0）。総量が分からない間は nil
    private(set) var fraction: Double?
    /// 読み込み開始からの経過時間の基準
    private(set) var startDate: Date?

    private var progress: Progress?
    /// 読み込み直したときに、前回分の後始末が新しい状態を上書きしないための識別子
    private var currentLoadID: UUID?

    /// 経過時間と進捗から残り時間を見積もる
    func estimatedRemaining(now: Date) -> TimeInterval? {
        guard let startDate, let fraction, fraction > 0.05, fraction < 1 else { return nil }
        let elapsed = now.timeIntervalSince(startDate)
        // 開始直後はばらつきが大きいため見積もらない
        guard elapsed > 1 else { return nil }
        return elapsed / fraction * (1 - fraction)
    }

    /// 動画を読み込む。キャンセルされた場合は CancellationError を投げる
    func load(_ item: PhotosPickerItem) async throws -> VideoTransferable {
        cancel()

        let loadID = UUID()
        currentLoadID = loadID
        isLoading = true
        fraction = nil
        startDate = Date()
        defer {
            if currentLoadID == loadID {
                currentLoadID = nil
                isLoading = false
                fraction = nil
                startDate = nil
                progress = nil
            }
        }

        let (stream, continuation) = AsyncStream<Result<VideoTransferable?, Error>>.makeStream()
        let progress = item.loadTransferable(type: VideoTransferable.self) { result in
            continuation.yield(result)
            continuation.finish()
        }
        self.progress = progress

        // Progress の KVO は任意のスレッドから通知されるため、一定間隔で読み取る
        let monitor = Task { [weak self] in
            while !Task.isCancelled, self?.currentLoadID == loadID {
                let total = progress.totalUnitCount
                let value: Double? = (total > 0 && !progress.isIndeterminate) ? progress.fractionCompleted : nil
                self?.fraction = value
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { monitor.cancel() }

        let result = await withTaskCancellationHandler {
            var received: Result<VideoTransferable?, Error> = .failure(CancellationError())
            for await value in stream {
                received = value
            }
            return received
        } onCancel: {
            progress.cancel()
        }

        if progress.isCancelled {
            throw CancellationError()
        }
        guard let movie = try result.get() else {
            throw VideoImportError.unsupported
        }
        return movie
    }

    /// 読み込みを中止する
    func cancel() {
        progress?.cancel()
    }
}

/// 動画読み込みエラー
nonisolated enum VideoImportError: Error, LocalizedError {
    case unsupported

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "動画の読み込みに失敗しました"
        }
    }
}

/// 残り時間などの表示用フォーマット
nonisolated enum DurationText {
    /// 例: 「約45秒」「約2分10秒」
    static func approximate(_ seconds: TimeInterval) -> String {
        let total = max(1, Int(seconds.rounded()))
        // 1分以上は10秒単位に丸めて、表示が細かく揺れないようにする
        let rounded = total >= 60 ? Int((Double(total) / 10).rounded()) * 10 : total
        let minutes = rounded / 60
        let secs = rounded % 60
        if minutes == 0 {
            return "約\(secs)秒"
        }
        return secs == 0 ? "約\(minutes)分" : "約\(minutes)分\(secs)秒"
    }

    /// 例: 「0:45」「12:03」
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
