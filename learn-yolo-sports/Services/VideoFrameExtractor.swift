//
//  VideoFrameExtractor.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import AVFoundation
import CoreGraphics

/// 動画の長さと、指定の間隔で抽出した場合の総フレーム数
nonisolated struct VideoInfo: Sendable {
    let duration: Double
    let totalFrames: Int
}

/// 動画から指定秒のフレームを抽出するクラス
///
/// 動画ごとに `AVAssetImageGenerator` をキャッシュして再利用する。actor は await で中断するたびに
/// 再入可能になるため、このキャッシュ検索自体はすぐ戻り、複数フレームの生成は並行に進む。
/// 毎フレームごとに asset を作り直すと、ファイルの再オープンと moov atom の再解析が
/// フレーム数分繰り返されるため、ここでまとめて避ける。
actor VideoFrameExtractor {

    private var generators: [URL: AVAssetImageGenerator] = [:]

    /// 動画の長さを取得する
    /// - Parameter framesPerSecond: 1秒あたりに抽出するフレーム数
    func videoInfo(for url: URL, framesPerSecond: Int) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)

        guard try await asset.loadTracks(withMediaType: .video).first != nil else {
            throw FrameExtractionError.noVideoTrack
        }

        let duration = try await asset.load(.duration)
        let seconds = max(0, CMTimeGetSeconds(duration))
        // 0秒時点のフレームも含めるため +1
        let totalFrames = max(1, Int((seconds * Double(max(1, framesPerSecond))).rounded(.down)) + 1)

        return VideoInfo(duration: seconds, totalFrames: totalFrames)
    }

    /// 指定秒のフレームを抽出する（並行に呼び出してよい）
    /// - Parameters:
    ///   - url: 動画のURL
    ///   - time: 抽出する時刻（秒）
    ///   - maximumDimension: 長辺の最大ピクセル数（同じ url への最初の呼び出しでのみ適用される）
    func extractFrame(from url: URL, at time: Double, maximumDimension: CGFloat = 1280) async throws -> CGImage {
        let generator = generator(for: url, maximumDimension: maximumDimension)
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        return try await generator.image(at: cmTime).image
    }

    private func generator(for url: URL, maximumDimension: CGFloat) -> AVAssetImageGenerator {
        if let existing = generators[url] {
            return existing
        }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maximumDimension, height: maximumDimension)
        generators[url] = generator
        return generator
    }
}

/// フレーム抽出エラー
nonisolated enum FrameExtractionError: Error, LocalizedError {
    case noVideoTrack

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "動画トラックが見つかりません"
        }
    }
}
