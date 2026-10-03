//
//  VideoFrameExtractor.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import AVFoundation
import CoreImage
import UIKit

/// 動画からフレームを抽出するクラス
actor VideoFrameExtractor {
    
    /// フレーム抽出の進捗を通知するクロージャ
    typealias ProgressHandler = @Sendable (Int, Int) async -> Void
    
    /// 動画URLからフレームを抽出
    /// - Parameters:
    ///   - url: 動画のURL
    ///   - fps: 抽出するフレームレート（デフォルト: 1フレーム/秒）
    ///   - maxFrames: 最大抽出フレーム数（デフォルト: 100）
    ///   - progressHandler: 進捗ハンドラー
    /// - Returns: 抽出されたCGImageの配列
    func extractFrames(
        from url: URL,
        fps: Int = 1,
        maxFrames: Int = 100,
        progressHandler: ProgressHandler? = nil
    ) async throws -> [CGImage] {
        
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
        
        var frames: [CGImage] = []
        var frameCount = 0
        let frameInterval = max(1, Int(nominalFrameRate) / max(1, fps)) // 抽出間隔
        
        // フレームを抽出
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            
            // フレーム間隔をチェック
            if frameCount % frameInterval == 0 {
                
                if let cgImage = createCGImage(from: sampleBuffer) {
                    frames.append(cgImage)
                    
                    // 進捗を通知
                    await progressHandler?(frames.count, maxFrames)
                    
                    print("🎬 フレーム抽出: \(frames.count)/\(maxFrames)")
                    
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
        let context = CIContext()
        
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
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
