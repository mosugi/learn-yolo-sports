//
//  VideoFrameExtractor.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import AVFoundation
import CoreImage
import UIKit

/// 抽出したフレーム
nonisolated struct ExtractedFrame {
    let image: CGImage
    /// 動画先頭からの時刻（秒）
    let timestamp: Double
}

/// 動画からフレームを抽出するクラス
///
/// フレームを配列に溜めずに1枚ずつ渡すため、抽出レートや解析時間を増やしてもメモリ使用量は増えない。
actor VideoFrameExtractor {

    private let context = CIContext()

    /// 動画の長さ（秒）
    func duration(of url: URL) async throws -> Double {
        let duration = try await AVURLAsset(url: url).load(.duration)
        return CMTimeGetSeconds(duration)
    }

    /// 指定した区間のフレームを一定間隔で取り出し、1枚ずつ処理する
    /// - Parameters:
    ///   - url: 動画のURL
    ///   - startTime: 開始時刻（秒）
    ///   - duration: 区間の長さ（秒）
    ///   - fps: 取り出すフレームレート
    ///   - limit: 取り出す最大枚数
    ///   - body: フレームと通し番号を受け取る処理。終わるまで次のフレームは読み込まない
    func forEachFrame(
        from url: URL,
        startTime: Double,
        duration: Double,
        fps: Int,
        limit: Int = .max,
        body: @Sendable (ExtractedFrame, Int) async throws -> Void
    ) async throws {
        let asset = AVURLAsset(url: url)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw FrameExtractionError.noVideoTrack
        }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: startTime, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )

        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? FrameExtractionError.failedToCreateReader
        }
        defer { reader.cancelReading() }

        let interval = 1.0 / Double(max(1, fps))
        // 小さな誤差でフレームを取りこぼさないよう、半フレーム分の許容をとる
        let tolerance = 0.01
        var nextTime = startTime
        let endTime = startTime + duration
        var index = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()

            let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            guard timestamp + tolerance >= nextTime else { continue }
            guard timestamp < endTime else { break }

            guard let image = createCGImage(from: sampleBuffer) else { continue }
            try await body(ExtractedFrame(image: image, timestamp: timestamp), index)
            index += 1

            // 抽出レートより動画のフレームレートが低い場合も、時刻が前に進むようにする
            while nextTime <= timestamp + tolerance {
                nextTime += interval
            }
        }

        if reader.status == .failed, let error = reader.error {
            throw error
        }
    }

    /// 指定した時刻のフレームを1枚取り出す（解析時と同じ向き・解像度）
    func frame(from url: URL, at time: Double) async throws -> CGImage {
        let box = ResultBox()
        try await forEachFrame(from: url, startTime: time, duration: 2, fps: 1, limit: 1) { frame, _ in
            box.set(frame.image)
        }
        guard let image = box.image else { throw FrameExtractionError.failedToCreateImage }
        return image
    }

    /// サンプルバッファからCGImageを作成
    private func createCGImage(from sampleBuffer: CMSampleBuffer) -> CGImage? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        return context.createCGImage(ciImage, from: ciImage.extent)
    }
}

/// クロージャから結果を受け取るための入れ物
private nonisolated final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CGImage?

    var image: CGImage? {
        lock.withLock { stored }
    }

    func set(_ image: CGImage) {
        lock.withLock { stored = image }
    }
}

/// フレーム抽出エラー
nonisolated enum FrameExtractionError: Error, LocalizedError {
    case noVideoTrack
    case failedToCreateReader
    case failedToCreateImage

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "動画トラックが見つかりません"
        case .failedToCreateReader:
            return "動画リーダーの作成に失敗しました"
        case .failedToCreateImage:
            return "画像の作成に失敗しました"
        }
    }
}
