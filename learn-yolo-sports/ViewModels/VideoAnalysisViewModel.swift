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
    case detecting
    case analyzing

    var label: String {
        switch self {
        case .idle: return "待機中"
        case .detecting: return "物体検出"
        case .analyzing: return "戦術分析"
        }
    }
}

/// 解析する区間と抽出レート
struct AnalysisSettings: Equatable {
    /// 1秒あたりに検出するフレーム数
    var framesPerSecond = 5
    /// 解析を始める時刻（秒）
    var startTime = 0.0
    /// 解析する長さ（秒）
    var duration = 60.0
}

/// 動画解析のビューモデル
///
/// App で1つだけ生成して Environment で共有する。解析は View のライフサイクルから切り離した
/// Task で実行するため、タブを移動しても、アプリがバックグラウンドに移っても継続する。
@MainActor
@Observable
class VideoAnalysisViewModel {

    // MARK: - State

    private(set) var videoURL: URL?
    /// 動画の長さ（秒）
    private(set) var videoDuration: Double?
    var settings = AnalysisSettings()
    /// コート・チームの設定
    private(set) var setup: AnalysisSetup?
    /// コート設定に使った画像（カメラが動いたかの判定の基準にもする）
    private(set) var setupImage: CGImage?

    var isAnalyzing = false
    var phase: AnalysisPhase = .idle
    var analysisProgress: Double = 0.0
    var currentFrame: Int = 0
    var totalFrames: Int = 0
    var errorMessage: String?

    /// 直近の解析結果の保存 ID（AnalysisStore から参照する）
    var currentRecordID: UUID?

    /// 解析タブで未確認の解析結果があるか
    var hasUnseenResult = false

    /// 実モデルで動作しているか（nil: 未確認, false: モックモード）
    var isUsingRealModel: Bool?

    // MARK: - Computed Properties

    var hasResults: Bool {
        currentRecordID != nil
    }

    /// 進捗の短い説明（例: 物体検出 12/30）
    var progressDescription: String {
        phase == .analyzing ? phase.label : "\(phase.label) \(currentFrame)/\(totalFrames)"
    }

    // MARK: - Dependencies

    private let store: AnalysisStore
    private let frameExtractor = VideoFrameExtractor()
    private let detector = YOLODetector()

    private var analysisTask: Task<Void, Never>?
    private var backgroundSession: ContinuedProcessingSession?

    init(store: AnalysisStore) {
        self.store = store
    }

    // MARK: - Methods

    /// モデルの読み込み状態を確認
    func checkModel() async {
        isUsingRealModel = await detector.isModelLoaded
    }

    /// 解析する動画を選ぶ（コート設定は動画ごとにやり直す）
    func selectVideo(_ url: URL) async {
        reset()
        videoURL = url
        do {
            let duration = try await frameExtractor.duration(of: url)
            videoDuration = duration
            settings.startTime = 0
            settings.duration = min(60, max(1, duration.rounded(.down)))
        } catch {
            errorMessage = "動画の長さを取得できませんでした: \(error.localizedDescription)"
        }
    }

    /// コート設定に使うフレーム（解析の開始時刻）
    func loadSetupFrame() async -> CGImage? {
        guard let videoURL else { return nil }
        do {
            return try await frameExtractor.frame(from: videoURL, at: settings.startTime)
        } catch {
            errorMessage = "フレームを取得できませんでした: \(error.localizedDescription)"
            return nil
        }
    }

    func applySetup(_ setup: AnalysisSetup, image: CGImage) {
        self.setup = setup
        self.setupImage = image
    }

    func clearSetup() {
        setup = nil
        setupImage = nil
    }

    /// 解析を開始（View から切り離した Task で実行する）
    func startAnalysis() {
        guard !isAnalyzing, let url = videoURL else { return }

        isAnalyzing = true
        let settings = settings
        let setup = setup
        let setupImage = setupImage
        analysisTask = Task {
            await analyzeVideo(url: url, settings: settings, setup: setup, setupImage: setupImage)
        }
    }

    /// 動画を解析
    private func analyzeVideo(url: URL, settings: AnalysisSettings, setup: AnalysisSetup?, setupImage: CGImage?) async {
        isAnalyzing = true
        phase = .detecting
        hasUnseenResult = false
        analysisProgress = 0.0
        currentFrame = 0
        errorMessage = nil
        currentRecordID = nil

        let duration = min(settings.duration, max(0, (videoDuration ?? settings.startTime + settings.duration) - settings.startTime))
        totalFrames = max(1, Int((duration * Double(settings.framesPerSecond)).rounded(.up)))

        let recordID = UUID()
        let processor = KeyframeProcessor(
            detector: detector,
            setup: setup,
            referenceImage: setupImage,
            outputDirectory: store.directoryURL(for: recordID),
            // 画像は 1 秒に 2 枚程度、長い区間では合計 600 枚程度までに抑える
            imageInterval: max(max(1, settings.framesPerSecond / 2), totalFrames / 600)
        )

        let session = ContinuedProcessingSession { [weak self] in
            self?.cancelAnalysis()
        }
        session.begin(title: "動画を解析中", subtitle: url.lastPathComponent)
        backgroundSession = session

        do {
            print("🎬 動画解析開始: \(url.lastPathComponent)（\(settings.startTime)秒から \(duration)秒、\(settings.framesPerSecond) FPS）")
            let startTime = Date()

            // フレームを1枚ずつ取り出して、その場で検出する
            try await frameExtractor.forEachFrame(
                from: url,
                startTime: settings.startTime,
                duration: duration,
                fps: settings.framesPerSecond
            ) { frame, index in
                _ = try await processor.process(frame, index: index)
                await self.updateDetectionProgress(current: index + 1)
            }

            // 最後のフレームの処理中にキャンセルされた場合は保存しない
            try Task.checkCancellation()

            let frames = await processor.results
            guard !frames.isEmpty else {
                throw AnalysisError.noFrames
            }
            let imageSize = await processor.imageSize ?? .zero

            // チーム分類・追跡・局面判定・解説の選定
            phase = .analyzing
            analysisProgress = 0.97
            session.update(fraction: analysisProgress, subtitle: "戦術分析")

            let fps = settings.framesPerSecond
            let analysis = await Task.detached(priority: .userInitiated) { () -> (result: MatchAnalysisResult, report: CoachReport, chapters: [MatchChapter])? in
                guard let setup else { return nil }
                let result = MatchAnalyzer.analyze(frames: frames, setup: setup)
                let report = CoachRules.report(analysis: result, setup: setup, framesPerSecond: fps)
                let chapters = GoalDetector.chapters(
                    states: result.states,
                    changes: result.possessionChanges,
                    setup: setup,
                    trackNumbers: result.trackNumbers
                )
                return (result, report, chapters)
            }.value
            let states = analysis?.result.statesByFrameIndex ?? [:]

            try Task.checkCancellation()

            let record = SavedAnalysis(
                id: recordID,
                createdAt: Date(),
                videoName: url.lastPathComponent,
                framesPerSecond: fps,
                imageWidth: Int(imageSize.width),
                imageHeight: Int(imageSize.height),
                processingDuration: Date().timeIntervalSince(startTime),
                usedRealModel: isUsingRealModel ?? false,
                frames: frames.map {
                    SavedFrame(processed: $0, assignments: analysis?.result.assignments[$0.index], state: states[$0.index])
                },
                setup: setup,
                coachReport: analysis?.report,
                chapters: analysis?.chapters,
                trackNumbers: analysis?.result.trackNumbers
            )

            print("✅ 解析完了: \(frames.count)フレーム、\(String(format: "%.1f", record.processingDuration))秒")
            if let analysis {
                print("📋 解説する場面: \(analysis.report.scenes.count)件、得点シーン: \(analysis.chapters.count)件、背番号を特定した追跡: \(analysis.result.trackNumbers.count)件")
            }

            do {
                try await store.save(record)
                currentRecordID = record.id
                print("💾 解析結果を保存しました: \(record.id)")
            } catch {
                errorMessage = "解析結果の保存に失敗しました: \(error.localizedDescription)"
                print("❌ 保存エラー: \(error)")
            }

            analysisProgress = 1.0
            hasUnseenResult = true
            session.finish(success: true)

        } catch is CancellationError {
            print("⏹️ 解析をキャンセルしました")
            store.discardPartial(id: recordID)
            analysisProgress = 0.0
            currentFrame = 0
            session.finish(success: false)

        } catch {
            store.discardPartial(id: recordID)
            errorMessage = "エラー: \(error.localizedDescription)"
            print("❌ エラー: \(error)")
            session.finish(success: false)
        }

        isAnalyzing = false
        phase = .idle
        analysisTask = nil
        backgroundSession = nil
    }

    /// 検出の進捗を反映（全体の 0%〜95%）
    private func updateDetectionProgress(current: Int) {
        guard isAnalyzing, phase == .detecting else { return }
        currentFrame = current
        totalFrames = max(totalFrames, current)
        analysisProgress = Double(current) / Double(totalFrames) * 0.95
        backgroundSession?.update(fraction: analysisProgress, subtitle: "物体検出 \(current)/\(totalFrames)")
    }

    /// 解析結果を確認済みにする
    func markResultSeen() {
        hasUnseenResult = false
    }

    /// 解析をキャンセル
    func cancelAnalysis() {
        analysisTask?.cancel()
    }

    /// 解析結果を閉じて、同じ動画・設定で解析をやり直せる状態に戻す
    func closeResult() {
        currentRecordID = nil
        hasUnseenResult = false
        errorMessage = nil
    }

    /// リセット
    func reset() {
        cancelAnalysis()
        videoURL = nil
        videoDuration = nil
        setup = nil
        setupImage = nil
        analysisProgress = 0.0
        currentFrame = 0
        totalFrames = 0
        errorMessage = nil
        currentRecordID = nil
        hasUnseenResult = false
    }
}

/// 解析のエラー
nonisolated enum AnalysisError: Error, LocalizedError {
    case noFrames

    var errorDescription: String? {
        switch self {
        case .noFrames:
            return "指定した区間からフレームを取り出せませんでした"
        }
    }
}
