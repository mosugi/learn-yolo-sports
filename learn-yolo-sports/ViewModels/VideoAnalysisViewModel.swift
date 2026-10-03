//
//  VideoAnalysisViewModel.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation
import SwiftUI
import AVFoundation

/// 解析の進行段階
enum AnalysisPhase {
    case idle
    case extracting
    case detecting
    
    var label: String {
        switch self {
        case .idle: return "待機中"
        case .extracting: return "フレーム抽出"
        case .detecting: return "物体検出"
        }
    }
}

/// 動画解析のビューモデル
///
/// App で1つだけ生成して Environment で共有する。解析は View のライフサイクルから切り離した
/// Task で実行するため、タブを移動しても、アプリがバックグラウンドに移っても継続する。
@MainActor
@Observable
class VideoAnalysisViewModel {

    // MARK: - State

    var videoURL: URL?
    var isAnalyzing = false
    var phase: AnalysisPhase = .idle
    var analysisProgress: Double = 0.0
    var currentFrame: Int = 0
    var totalFrames: Int = 0
    var errorMessage: String?

    var detectionResults: [FrameDetectionResult] = []
    var selectedFrameIndex: Int = 0

    var analysisResult: VideoAnalysisResult?

    /// 解析タブで未確認の解析結果があるか
    var hasUnseenResult = false
    
    /// 実モデルで動作しているか（nil: 未確認, false: モックモード）
    var isUsingRealModel: Bool?

    // MARK: - Computed Properties

    var selectedFrameResult: FrameDetectionResult? {
        guard selectedFrameIndex < detectionResults.count else { return nil }
        return detectionResults[selectedFrameIndex]
    }

    var hasResults: Bool {
        !detectionResults.isEmpty
    }
    
    /// 進捗の短い説明（例: 物体検出 12/30）
    var progressDescription: String {
        "\(phase.label) \(currentFrame)/\(totalFrames)"
    }

    // MARK: - Dependencies

    private let frameExtractor = VideoFrameExtractor()
    private let detector = YOLODetector()

    private var analysisTask: Task<Void, Never>?
    private var backgroundSession: ContinuedProcessingSession?

    // MARK: - Methods

    /// モデルの読み込み状態を確認
    func checkModel() async {
        isUsingRealModel = await detector.isModelLoaded
    }

    /// 解析を開始（View から切り離した Task で実行する）
    func startAnalysis(url: URL, framesPerSecond: Int = 1, maxFrames: Int = 30) {
        guard !isAnalyzing else { return }

        isAnalyzing = true
        analysisTask = Task {
            await analyzeVideo(url: url, framesPerSecond: framesPerSecond, maxFrames: maxFrames)
        }
    }

    /// 動画を解析
    private func analyzeVideo(url: URL, framesPerSecond: Int, maxFrames: Int) async {
        isAnalyzing = true
        phase = .extracting
        hasUnseenResult = false
        analysisProgress = 0.0
        currentFrame = 0
        totalFrames = 0
        errorMessage = nil
        detectionResults = []
        selectedFrameIndex = 0
        analysisResult = nil
        videoURL = url

        let session = ContinuedProcessingSession { [weak self] in
            self?.cancelAnalysis()
        }
        session.begin(title: "動画を解析中", subtitle: url.lastPathComponent)
        backgroundSession = session

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
                await self.updateExtractionProgress(current: current, total: total)
            }

            totalFrames = frames.count
            print("✅ フレーム抽出完了: \(frames.count)フレーム")

            // 各フレームで物体検出
            print("🤖 物体検出中...")
            var results: [FrameDetectionResult] = []
            phase = .detecting
            currentFrame = 0
            
            for (index, frame) in frames.enumerated() {
                try Task.checkCancellation()

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
                session.update(fraction: analysisProgress, subtitle: "物体検出 \(index + 1)/\(frames.count)")

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

            hasUnseenResult = true
            session.finish(success: true)

        } catch is CancellationError {
            print("⏹️ 解析をキャンセルしました")
            analysisProgress = 0.0
            currentFrame = 0
            session.finish(success: false)

        } catch {
            errorMessage = "エラー: \(error.localizedDescription)"
            print("❌ エラー: \(error)")
            session.finish(success: false)
        }

        isAnalyzing = false
        phase = .idle
        analysisTask = nil
        backgroundSession = nil
    }

    /// フレーム抽出の進捗を反映（全体の 0%〜50%）
    private func updateExtractionProgress(current: Int, total: Int) {
        guard isAnalyzing, phase == .extracting else { return }
        currentFrame = current
        totalFrames = total
        analysisProgress = Double(current) / Double(total) * 0.5
        backgroundSession?.update(fraction: analysisProgress, subtitle: "フレーム抽出 \(current)/\(total)")
    }

    /// 解析結果を確認済みにする
    func markResultSeen() {
        hasUnseenResult = false
    }
    
    /// 解析をキャンセル
    func cancelAnalysis() {
        analysisTask?.cancel()
    }

    /// リセット
    func reset() {
        cancelAnalysis()
        videoURL = nil
        analysisProgress = 0.0
        currentFrame = 0
        totalFrames = 0
        errorMessage = nil
        detectionResults = []
        selectedFrameIndex = 0
        analysisResult = nil
        hasUnseenResult = false
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
