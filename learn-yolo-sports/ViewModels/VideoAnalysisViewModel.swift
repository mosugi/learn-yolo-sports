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
    case saving

    var label: String {
        switch self {
        case .idle: return "待機中"
        case .extracting: return "フレーム抽出"
        case .detecting: return "物体検出"
        case .saving: return "保存"
        }
    }
}

/// 直近の解析で計測したフレームあたりの処理時間（次回の進捗配分と所要時間の見積もりに使う）
///
/// 実モデルとモックモードでは検出速度が大きく異なるため、別々に保存する。
nonisolated struct ProcessingRates {
    /// フレーム抽出にかかった時間（抽出 1 フレームあたり・秒）
    var extraction: Double
    /// 物体検出にかかった時間（1 フレームあたり・秒）
    var detection: Double

    private static func key(usesRealModel: Bool) -> String {
        usesRealModel ? "processingRates.real" : "processingRates.mock"
    }

    static func load(usesRealModel: Bool) -> ProcessingRates? {
        guard let values = UserDefaults.standard.array(forKey: key(usesRealModel: usesRealModel)) as? [Double],
              values.count == 2, values.allSatisfy({ $0 > 0 }) else {
            return nil
        }
        return ProcessingRates(extraction: values[0], detection: values[1])
    }

    func save(usesRealModel: Bool) {
        UserDefaults.standard.set([extraction, detection], forKey: Self.key(usesRealModel: usesRealModel))
    }

    /// 進捗バー全体のうちフレーム抽出が占める割合
    var extractionWeight: Double {
        min(0.9, max(0.1, extraction / (extraction + detection)))
    }

    /// 指定フレーム数の解析にかかる時間の目安
    func estimatedDuration(frames: Int) -> TimeInterval {
        (extraction + detection) * Double(frames)
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

    /// 直近の解析結果の保存 ID（AnalysisStore から参照する）
    var currentRecordID: UUID?

    /// 解析タブで未確認の解析結果があるか
    var hasUnseenResult = false

    /// 実モデルで動作しているか（nil: 未確認, false: モックモード）
    var isUsingRealModel: Bool?

    /// 解析の開始時刻
    var analysisStartDate: Date?

    /// 解析完了の見込み時刻（見積もれない間は nil）
    var estimatedCompletionDate: Date?

    // MARK: - Computed Properties

    var hasResults: Bool {
        !detectionResults.isEmpty
    }

    /// 進捗の短い説明（例: 物体検出 12/30・残り約45秒）
    var progressDescription: String {
        if phase == .saving {
            return "結果を保存中"
        }
        let base = "\(phase.label) \(currentFrame)/\(totalFrames)"
        guard let remaining = estimatedRemaining(now: Date()) else { return base }
        return base + "・残り" + DurationText.approximate(remaining)
    }

    /// 残り時間（見積もれない間は nil）
    func estimatedRemaining(now: Date) -> TimeInterval? {
        estimatedCompletionDate.map { max(0, $0.timeIntervalSince(now)) }
    }

    /// 解析を始める前の所要時間の目安（前回の計測値がない場合は nil）
    func estimatedDuration(for info: VideoInfo, framesPerSecond: Int, maxFrames: Int) -> TimeInterval? {
        guard let isUsingRealModel,
              let rates = ProcessingRates.load(usesRealModel: isUsingRealModel) else {
            return nil
        }
        return rates.estimatedDuration(frames: info.expectedFrameCount(fps: framesPerSecond, maxFrames: maxFrames))
    }

    // MARK: - Dependencies

    private let store: AnalysisStore
    private let frameExtractor = VideoFrameExtractor()
    private let detector = YOLODetector()

    private var analysisTask: Task<Void, Never>?
    private var backgroundSession: ContinuedProcessingSession?

    /// 現在のフェーズの開始時刻（フレームあたりの処理時間の計測に使う）
    private var phaseStartDate = Date()
    /// 進捗バー全体のうちフレーム抽出が占める割合
    private var extractionWeight = 0.5
    /// 前回の解析で計測した処理時間
    private var previousRates: ProcessingRates?

    init(store: AnalysisStore) {
        self.store = store
    }

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
        currentRecordID = nil
        videoURL = url

        let usesRealModel = isUsingRealModel ?? false
        previousRates = ProcessingRates.load(usesRealModel: usesRealModel)
        extractionWeight = previousRates?.extractionWeight ?? 0.5
        let startTime = Date()
        analysisStartDate = startTime
        phaseStartDate = startTime
        estimatedCompletionDate = nil

        let session = ContinuedProcessingSession { [weak self] in
            self?.cancelAnalysis()
        }
        session.begin(title: "動画を解析中", subtitle: url.lastPathComponent)
        backgroundSession = session

        do {
            print("🎬 動画解析開始: \(url.lastPathComponent)")

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

            guard !frames.isEmpty else {
                throw FrameExtractionError.noFrames
            }

            let extractionDuration = Date().timeIntervalSince(phaseStartDate)

            // 各フレームで物体検出
            print("🤖 物体検出中...")
            var results: [FrameDetectionResult] = []
            phase = .detecting
            phaseStartDate = Date()
            currentFrame = 0
            analysisProgress = extractionWeight
            updateEstimate()

            for (index, frame) in frames.enumerated() {
                try Task.checkCancellation()

                let detections = try await detector.detect(image: frame.image)

                let result = FrameDetectionResult(
                    frameNumber: index,
                    timestamp: frame.timestamp,
                    detections: detections,
                    image: frame.image
                )

                results.append(result)

                currentFrame = index + 1
                analysisProgress = extractionWeight + Double(index + 1) / Double(frames.count) * (1 - extractionWeight)
                updateEstimate()
                session.update(fraction: analysisProgress, subtitle: progressDescription)

                print("🎯 フレーム \(index + 1)/\(frames.count): \(detections.count)個検出")
            }

            // 最後のフレームの検出中にキャンセルされた場合は保存しない
            try Task.checkCancellation()
            
            let detectionDuration = Date().timeIntervalSince(phaseStartDate)
            let duration = Date().timeIntervalSince(startTime)

            // 次回の見積もりのために、フレームあたりの処理時間を記録する
            let frameCount = Double(frames.count)
            ProcessingRates(
                extraction: max(0.001, extractionDuration / frameCount),
                detection: max(0.001, detectionDuration / frameCount)
            ).save(usesRealModel: usesRealModel)

            let record = SavedAnalysis(
                videoName: url.lastPathComponent,
                framesPerSecond: framesPerSecond,
                processingDuration: duration,
                usedRealModel: isUsingRealModel ?? false,
                results: results
            )

            print("✅ 解析完了!")
            print("  - 処理時間: \(String(format: "%.2f", duration))秒")
            print("  - 総検出数: \(record.totalDetections)")
            print("  - 平均検出数: \(String(format: "%.2f", record.averageDetectionsPerFrame))")

            // 解析結果を保存（JPEG の書き出しに時間がかかるため段階を表示する）
            phase = .saving
            estimatedCompletionDate = nil
            session.update(fraction: analysisProgress, subtitle: progressDescription)
            let images = Dictionary(uniqueKeysWithValues: results.compactMap { result in
                result.image.map { (result.frameNumber, $0) }
            })
            do {
                try await store.save(record, images: images)
                print("💾 解析結果を保存しました: \(record.id)")
            } catch {
                errorMessage = "解析結果の保存に失敗しました: \(error.localizedDescription)"
                print("❌ 保存エラー: \(error)")
            }

            // 保存が終わってから結果画面に切り替える（保存中は進捗カードを表示し続ける）
            detectionResults = results
            currentRecordID = record.id

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
        analysisStartDate = nil
        estimatedCompletionDate = nil
        analysisTask = nil
        backgroundSession = nil
    }

    /// フレーム抽出の進捗を反映（全体の 0%〜extractionWeight）
    private func updateExtractionProgress(current: Int, total: Int) {
        guard isAnalyzing, phase == .extracting else { return }
        currentFrame = current
        totalFrames = total
        analysisProgress = Double(current) / Double(total) * extractionWeight
        updateEstimate()
        backgroundSession?.update(fraction: analysisProgress, subtitle: progressDescription)
    }

    /// 現在のフェーズの実測ペースと前回の計測値から、完了見込み時刻を更新する
    private func updateEstimate() {
        let now = Date()
        let elapsed = now.timeIntervalSince(phaseStartDate)
        let remainingFrames = Double(max(0, totalFrames - currentFrame))

        // 数フレーム処理するまでは実測値のばらつきが大きいため、前回の計測値を優先する
        func rate(measuredAfter minimumFrames: Int, fallback: Double?) -> Double? {
            if currentFrame >= minimumFrames {
                return elapsed / Double(currentFrame)
            }
            return fallback
        }

        let remaining: TimeInterval?
        switch phase {
        case .extracting:
            if let extraction = rate(measuredAfter: 3, fallback: previousRates?.extraction),
               let detection = previousRates?.detection {
                remaining = extraction * remainingFrames + detection * Double(totalFrames)
            } else {
                remaining = nil
            }
        case .detecting:
            remaining = rate(measuredAfter: 2, fallback: previousRates?.detection).map { $0 * remainingFrames }
        case .idle, .saving:
            remaining = nil
        }

        estimatedCompletionDate = remaining.map { now.addingTimeInterval($0) }
    }

    /// スクリーンショット用のデモデータを解析結果として表示する
    func showDemo(record: SavedAnalysis, frames: [FrameDetectionResult]) {
        videoURL = URL.temporaryDirectory.appending(path: record.videoName)
        detectionResults = frames
        currentRecordID = record.id
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
        currentRecordID = nil
        hasUnseenResult = false
        estimatedCompletionDate = nil
    }
}
