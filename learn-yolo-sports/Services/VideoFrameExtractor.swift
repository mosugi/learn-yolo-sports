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
actor VideoFrameExtractor {
    
    /// フレームごとに作り直すと重いため使い回す
    private let ciContext = CIContext()
    
    /// フレーム抽出の進捗を通知するクロージャ
    typealias ProgressHandler = @Sendable (Int, Int) async -> Void
    
    /// 動画URLからフレームを抽出
    /// - Parameters:
    ///   - url: 動画のURL
    ///   - fps: 抽出するフレームレート（デフォルト: 1フレーム/秒）
    ///   - maxFrames: 最大抽出フレーム数（デフォルト: 100）
    ///   - progressHandler: 進捗ハンドラー
    /// - Returns: 抽出されたフレームの配列
    func extractFrames(
        from url: URL,
        fps: Int = 1,
        maxFrames: Int = 100,
        progressHandler: ProgressHandler? = nil
    ) async throws -> [ExtractedFrame] {
        
        let asset = AVURLAsset(url: url)
        
        // 動画のトラックを取得
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw FrameExtractionError.noVideoTrack
        }
        
        // 動画の長さを取得
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        
        // フレームレートを取得
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        
        print("📹 動画情報:")
        print("  - 長さ: \(durationSeconds) 秒")
        print("  - FPS: \(nominalFrameRate)")
        
        // リーダーを作成
        let reader = try AVAssetReader(asset: asset)
        
        // 出力設定
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        
        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: outputSettings
        )
        
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }
        
        var frames: [ExtractedFrame] = []
        var frameCount = 0
        let frameInterval = max(1, Int(nominalFrameRate) / max(1, fps)) // 抽出間隔
        
        // 実際に抽出されるフレーム数（短い動画では maxFrames に届かないため、進捗の分母に使う）
        let sourceFrameCount = Int((durationSeconds * Double(nominalFrameRate)).rounded(.up))
        let expectedFrames = max(1, min(maxFrames, Int((Double(sourceFrameCount) / Double(frameInterval)).rounded(.up))))
        
        // フレームを抽出
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            
            // フレーム間隔をチェック
            if frameCount % frameInterval == 0 {
                
                if let cgImage = createCGImage(from: sampleBuffer) {
                    let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    frames.append(ExtractedFrame(image: cgImage, timestamp: CMTimeGetSeconds(time)))
                    
                    // 進捗を通知
                    // 見積もりより多く取れた場合も分母を超えないようにする
                    await progressHandler?(frames.count, max(expectedFrames, frames.count))
                    
                    print("🎬 フレーム抽出: \(frames.count)/\(expectedFrames)")
                    
                    // 最大フレーム数に達したら終了
                    if frames.count >= maxFrames {
                        break
                    }
                }
            }
            
            frameCount += 1
        }
        
        print("✅ フレーム抽出完了: \(frames.count)フレーム")
        
        return frames
    }
    
    /// 特定の時間のフレームを抽出
    /// - Parameters:
    ///   - url: 動画のURL
    ///   - time: 抽出する時間（秒）
    /// - Returns: 抽出されたCGImage
    func extractFrame(from url: URL, at time: Double) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceAfter = .zero
        imageGenerator.requestedTimeToleranceBefore = .zero
        
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        return try await imageGenerator.image(at: cmTime).image
    }
    
    /// サンプルバッファからCGImageを作成
    private func createCGImage(from sampleBuffer: CMSampleBuffer) -> CGImage? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }
        
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        
        return cgImage
    }
}

/// フレーム抽出エラー
enum FrameExtractionError: Error, LocalizedError {
    case noVideoTrack
    case failedToCreateReader
    case failedToCreateImage
    case noFrames
    
    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "動画トラックが見つかりません"
        case .failedToCreateReader:
            return "動画リーダーの作成に失敗しました"
        case .failedToCreateImage:
            return "画像の作成に失敗しました"
        case .noFrames:
            return "動画からフレームを取得できませんでした"
        }
    }
}
