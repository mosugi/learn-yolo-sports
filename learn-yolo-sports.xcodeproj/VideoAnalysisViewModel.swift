//
//  VideoAnalysisViewModel.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation
import SwiftUI
import AVFoundation

/// 動画解析のビューモデル
@MainActor
@Observable
class VideoAnalysisViewModel {
    
    // MARK: - State
    
    var videoURL: URL?
    var isAnalyzing = false
    var analysisProgress: Double = 0.0
    var currentFrame: Int = 0
    var totalFrames: Int = 0
    var errorMessage: String?
    
    var detectionResults: [FrameDetectionResult] = []
    var selectedFrameIndex: Int = 0
    
    var analysisResult: VideoAnalysisResult?
    
    // MARK: - Computed Properties
    
    var selectedFrameResult: FrameDetectionResult? {
        guard selectedFrameIndex < detectionResults.count else { return nil }
        return detectionResults[selectedFrameIndex]
    }
    
    var hasResults: Bool {
        !detectionResults.isEmpty
    }
    
    // MARK: - Dependencies
    
    private let frameExtractor = VideoFrameExtractor()
    private let detector = YOLODetector()
    
    // MARK: - Methods
    
    /// 動画を解析
    func analyzeVideo(url: URL, framesPerSecond: Int = 1, maxFrames: Int = 30) async {
        isAnalyzing = true
        analysisProgress = 0.0
        currentFrame = 0
        errorMessage = nil
        detectionResults = []
        videoURL = url
        
        do {
            print("🎬 動画解析開始: \(url.lastPathComponent)")
            
            let startTime = Date()
            
            // フレームを抽出
            print("📹 フレームを抽出中...")
            let frames = try await frameExtractor.extractFrames(
                from: url,
                fps: framesPerSecond,
                maxFrames: maxFrames
            ) { current, total in
                Task { @MainActor in
                    self.currentFrame = current
                    self.totalFrames = total
                    self.analysisProgress = Double(current) / Double(total) * 0.5 // 50%まで
                }
            }
            
            totalFrames = frames.count
            print("✅ フレーム抽出完了: \(frames.count)フレーム")
            
            // 各フレームで物体検出
            print("🤖 物体検出中...")
            var results: [FrameDetectionResult] = []
            
            for (index, frame) in frames.enumerated() {
                let detections = try await detector.detect(image: frame)
                
                let result = FrameDetectionResult(
                    frameNumber: index,
                    timestamp: Double(index) / Double(framesPerSecond),
                    detections: detections,
                    image: frame
                )
                
                results.append(result)
                
                currentFrame = index + 1
                analysisProgress = 0.5 + (Double(index + 1) / Double(frames.count) * 0.5) // 50%〜100%
                
                print("🎯 フレーム \(index + 1)/\(frames.count): \(detections.count)個検出")
            }
            
            detectionResults = results
            
            let endTime = Date()
            let duration = endTime.timeIntervalSince(startTime)
            
            // 解析結果を作成
            analysisResult = VideoAnalysisResult(
                totalFrames: frames.count,
                processedFrames: frames.count,
                detectionResults: results,
                duration: duration
            )
            
            print("✅ 解析完了!")
            print("  - 処理時間: \(String(format: "%.2f", duration))秒")
            print("  - 総検出数: \(analysisResult?.totalDetections ?? 0)")
            print("  - 平均検出数: \(String(format: "%.2f", analysisResult?.averageDetectionsPerFrame ?? 0))")
            
            isAnalyzing = false
            
        } catch {
            errorMessage = "エラー: \(error.localizedDescription)"
            isAnalyzing = false
            print("❌ エラー: \(error)")
        }
    }
    
    /// 解析をキャンセル
    func cancelAnalysis() {
        isAnalyzing = false
        analysisProgress = 0.0
        currentFrame = 0
    }
    
    /// リセット
    func reset() {
        videoURL = nil
        isAnalyzing = false
        analysisProgress = 0.0
        currentFrame = 0
        totalFrames = 0
        errorMessage = nil
        detectionResults = []
        selectedFrameIndex = 0
        analysisResult = nil
    }
    
    /// 次のフレームへ
    func nextFrame() {
        if selectedFrameIndex < detectionResults.count - 1 {
            selectedFrameIndex += 1
        }
    }
    
    /// 前のフレームへ
    func previousFrame() {
        if selectedFrameIndex > 0 {
            selectedFrameIndex -= 1
        }
    }
}
