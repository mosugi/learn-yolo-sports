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
    case segmenting
    case commentating

    var label: String {
        switch self {
        case .idle: return "待機中"
        case .detecting: return "物体検出"
        case .segmenting: return "シーンを区切っています"
        case .commentating: return "シーン解説"
        }
    }
}

/// 動画解析のビューモデル
///
/// App で1つだけ生成して Environment で共有する。解析は View のライフサイクルから切り離した
/// Task で実行するため、タブを移動しても、アプリがバックグラウンドに移っても継続する。
/// 動画選択から検出・チーム分け・シーン区切り・AI解説の生成までを1つのパイプラインとして流す。
@MainActor
@Observable
final class VideoAnalysisViewModel {

    /// 1秒おきにフレームを抽出する
    private static let framesPerSecond = 1
    /// 背番号OCRを試す間隔（秒）。処理時間を抑えるため毎フレームは行わない
    private nonisolated static let jerseyOCRInterval = 5
    /// 1度に並行して処理するフレーム数
    private static let batchSize = 4

    // MARK: - State

    /// 現在表示・解析中の動画（解析の進行とともに Documents → 解析ディレクトリへ移る）
    var activeVideoURL: URL?
    var isAnalyzing = false
    var phase: AnalysisPhase = .idle
    var analysisProgress: Double = 0.0
    var currentFrame: Int = 0
    var totalFrames: Int = 0
    var currentScene: Int = 0
    var totalScenes: Int = 0
    var errorMessage: String?

    /// 直近の解析結果の保存 ID（AnalysisStore から参照する）
    var currentRecordID: UUID?

    /// 解析タブで未確認の解析結果があるか
    var hasUnseenResult = false

    /// 実モデルで動作しているか（nil: 未確認, false: モックモード）
    var isUsingRealModel: Bool?

    /// 現在パイプラインが処理中のチェックポイント ID。
    /// store.interrupted には見かけ上まだ残っているため、他画面（履歴タブなど）が
    /// このIDを誤って「中断された解析」として再開・破棄しないよう判別に使う。
    private(set) var processingCheckpointID: UUID?

    // MARK: - Computed Properties

    var hasResults: Bool {
        currentRecordID != nil
    }

    /// 進捗の短い説明
    var progressDescription: String {
        switch phase {
        case .idle, .segmenting:
            return phase.label
        case .detecting:
            return "\(phase.label) \(currentFrame)/\(totalFrames)"
        case .commentating:
            return "\(phase.label) \(currentScene)/\(totalScenes)"
        }
    }

    // MARK: - Dependencies

    private let store: AnalysisStore
    private let frameExtractor = VideoFrameExtractor()
    private let detector = YOLODetector()
    private let attributeAnalyzer = PlayerAttributeAnalyzer()

    private var analysisTask: Task<Void, Never>?
    private var backgroundSession: ContinuedProcessingSession?
    private var isRetryingCommentary = false

    init(store: AnalysisStore) {
        self.store = store
    }

    // MARK: - Methods

    /// モデルの読み込み状態を確認
    func checkModel() async {
        isUsingRealModel = await detector.isModelLoaded
    }

    /// 新しく選んだ動画の解析を開始する（選んだ操作そのものがユーザー操作なので、そのままバックグラウンド継続を申請できる）
    func startNewAnalysis(videoAt url: URL) {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        analysisTask = Task {
            await self.beginAndRunPipeline(videoAt: url)
        }
    }

    /// 中断された解析を再開する（ボタンのタップがユーザー操作になる）
    func resumeAnalysis(_ checkpoint: AnalysisCheckpoint) {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        analysisTask = Task {
            await self.runPipeline(checkpoint: checkpoint)
        }
    }

    /// 解析を一時停止する（チェックポイントは残るので後で再開できる）
    func cancelAnalysis() {
        analysisTask?.cancel()
    }

    /// 解析結果を確認済みにする
    func markResultSeen() {
        hasUnseenResult = false
    }

    /// 結果画面から動画選択画面に戻る
    func reset() {
        cancelAnalysis()
        activeVideoURL = nil
        analysisProgress = 0.0
        currentFrame = 0
        totalFrames = 0
        currentScene = 0
        totalScenes = 0
        errorMessage = nil
        currentRecordID = nil
        hasUnseenResult = false
    }

    /// アプリがフォアグラウンドに戻ったときに呼ぶ。バックグラウンドで生成できなかったAI解説を再試行する
    func appDidBecomeActive() {
        guard !isAnalyzing, !isRetryingCommentary,
              let id = currentRecordID,
              let record = store.record(for: id),
              record.adviceUnavailableReason != nil else { return }

        isRetryingCommentary = true
        Task {
            await self.retryMissingAdvice(for: id)
            self.isRetryingCommentary = false
        }
    }

    // MARK: - Pipeline

    private func beginAndRunPipeline(videoAt url: URL) async {
        let id = UUID()
        phase = .detecting
        hasUnseenResult = false
        errorMessage = nil
        currentRecordID = nil
        activeVideoURL = url

        do {
            let info = try await frameExtractor.videoInfo(for: url)
            let destination = try await store.beginAnalysis(
                id: id,
                movingVideoFrom: url,
                info: info,
                framesPerSecond: Self.framesPerSecond
            )
            activeVideoURL = destination

            guard let checkpoint = store.checkpoint(for: id) else {
                errorMessage = "解析を開始できませんでした"
                isAnalyzing = false
                phase = .idle
                return
            }
            await runPipeline(checkpoint: checkpoint)
        } catch {
            errorMessage = "エラー: \(error.localizedDescription)"
            isAnalyzing = false
            phase = .idle
        }
    }

    private func runPipeline(checkpoint initialCheckpoint: AnalysisCheckpoint) async {
        isAnalyzing = true
        errorMessage = nil
        hasUnseenResult = false

        let id = initialCheckpoint.id
        let videoURL = store.videoURL(for: initialCheckpoint)
        activeVideoURL = videoURL
        processingCheckpointID = id
        let startTime = Date()

        let session = ContinuedProcessingSession { [weak self] in
            self?.cancelAnalysis()
        }
        session.begin(title: "動画を解析中", subtitle: initialCheckpoint.videoFileName)
        backgroundSession = session

        var checkpoint = initialCheckpoint
        var imageSize: CGSize? = checkpoint.imageWidth.flatMap { width in
            checkpoint.imageHeight.map { height in CGSize(width: width, height: height) }
        }

        do {
            let usingReal = await detector.isModelLoaded
            isUsingRealModel = usingReal
            checkpoint.usedRealModel = usingReal
            try store.updateCheckpoint(checkpoint)

            var frames = store.readAppendedFrames(id: id)
            totalFrames = checkpoint.totalFrames
            currentFrame = checkpoint.lastProcessedFrame
            phase = .detecting
            analysisProgress = Double(checkpoint.lastProcessedFrame) / Double(max(1, checkpoint.totalFrames)) * 0.85
            session.update(fraction: analysisProgress, subtitle: "検出 \(currentFrame)/\(totalFrames)")

            if checkpoint.lastProcessedFrame < checkpoint.totalFrames {
                imageSize = try await detectRemainingFrames(
                    id: id,
                    videoURL: videoURL,
                    duration: checkpoint.videoDuration,
                    checkpoint: &checkpoint,
                    frames: &frames,
                    session: session
                )
            }

            try Task.checkCancellation()

            // --- チーム分け・シーン区切り ---
            var teams = checkpoint.teams
            var segments = checkpoint.segments

            if teams == nil || segments == nil {
                phase = .segmenting
                session.update(fraction: 0.85, subtitle: "シーンを区切っています")
                checkpoint.stage = .segmenting
                checkpoint.updatedAt = Date()
                try store.updateCheckpoint(checkpoint)

                let colorRefs = collectPlayerColors(frames: frames)
                let classified = TeamClassifier.classify(colors: colorRefs.map(\.color))
                applyTeams(classified.assignments, refs: colorRefs, to: &frames)
                teams = classified.teams
                segments = SceneSegmenter.segments(frames: frames, duration: checkpoint.videoDuration)

                try await store.rewriteFrames(id: id, frames: frames)

                checkpoint.teams = teams
                checkpoint.segments = segments
                checkpoint.stage = .commentating
                checkpoint.updatedAt = Date()
                try store.updateCheckpoint(checkpoint)
            }

            try Task.checkCancellation()

            // --- 総評・シーン解説の生成 ---
            phase = .commentating
            var record = SavedAnalysis(
                id: id,
                createdAt: checkpoint.createdAt,
                videoName: checkpoint.videoFileName,
                framesPerSecond: Self.framesPerSecond,
                imageWidth: Int(imageSize?.width ?? 0),
                imageHeight: Int(imageSize?.height ?? 0),
                processingDuration: Date().timeIntervalSince(startTime),
                usedRealModel: checkpoint.usedRealModel,
                frames: frames,
                videoDuration: checkpoint.videoDuration,
                videoFileName: checkpoint.videoFileName,
                teams: teams,
                segments: segments
            )

            var adviceFailureReason: String? = IntelligenceAdvisor.unavailableReason

            if adviceFailureReason == nil {
                do {
                    record.advice = try await IntelligenceAdvisor.overallAdvice(for: record)
                } catch {
                    adviceFailureReason = IntelligenceAdvisor.errorMessage(for: error)
                }
            }

            var resolvedSegments = record.segments ?? []
            totalScenes = resolvedSegments.count
            for index in resolvedSegments.indices {
                try Task.checkCancellation()
                currentScene = index + 1
                session.update(
                    fraction: 0.85 + 0.15 * Double(index + 1) / Double(max(1, resolvedSegments.count)),
                    subtitle: "シーン解説 \(index + 1)/\(resolvedSegments.count)"
                )

                // 選択肢の矢印は Apple Intelligence が使えなくても出せるよう、解説より先に計算する
                let segmentFrames = frames.filter { resolvedSegments[index].contains($0.timestamp) }
                if resolvedSegments[index].tactics == nil {
                    resolvedSegments[index].tactics = TacticalPlanner.snapshot(
                        for: resolvedSegments[index],
                        frames: segmentFrames,
                        aspectRatio: Self.aspectRatio(width: record.imageWidth, height: record.imageHeight)
                    )
                }

                guard resolvedSegments[index].commentary == nil else { continue }
                guard IntelligenceAdvisor.unavailableReason == nil else {
                    adviceFailureReason = IntelligenceAdvisor.unavailableReason
                    continue
                }

                let segment = resolvedSegments[index]
                let metrics = AnalysisMetrics(
                    frames: segmentFrames,
                    duration: segment.endTime - segment.startTime,
                    teams: teams
                )

                do {
                    resolvedSegments[index].commentary = try await IntelligenceAdvisor.sceneCommentary(
                        for: segment,
                        metrics: metrics,
                        teams: teams,
                        usedRealModel: checkpoint.usedRealModel
                    )
                } catch {
                    adviceFailureReason = IntelligenceAdvisor.errorMessage(for: error)
                }

                checkpoint.segments = resolvedSegments
                checkpoint.updatedAt = Date()
                try store.updateCheckpoint(checkpoint)
            }
            record.segments = resolvedSegments
            record.adviceUnavailableReason = adviceFailureReason

            try Task.checkCancellation()
            record.processingDuration = Date().timeIntervalSince(startTime)
            try await store.finalize(record)

            currentRecordID = id
            hasUnseenResult = true
            session.finish(success: true)

        } catch is CancellationError {
            session.finish(success: false)
        } catch {
            errorMessage = "エラー: \(error.localizedDescription)"
            session.finish(success: false)
        }

        isAnalyzing = false
        phase = .idle
        analysisTask = nil
        backgroundSession = nil
        processingCheckpointID = nil
    }

    /// 未処理のフレームを検出する（画像生成・OCR・JPEG書き出しは TaskGroup で同時に数枚処理する）
    private func detectRemainingFrames(
        id: UUID,
        videoURL: URL,
        duration: Double,
        checkpoint: inout AnalysisCheckpoint,
        frames: inout [SavedFrame],
        session: ContinuedProcessingSession
    ) async throws -> CGSize? {
        var imageSize: CGSize?
        var index = checkpoint.lastProcessedFrame
        let totalFrames = checkpoint.totalFrames

        while index < totalFrames {
            try Task.checkCancellation()

            let batchEnd = min(index + Self.batchSize, totalFrames)
            let batchIndices = Array(index..<batchEnd)

            let frameExtractor = self.frameExtractor
            let detector = self.detector
            let attributeAnalyzer = self.attributeAnalyzer

            let batchResults = try await withThrowingTaskGroup(of: (Int, SavedFrame, CGImage?).self) { group in
                for frameIndex in batchIndices {
                    group.addTask {
                        try await Self.processFrame(
                            frameExtractor: frameExtractor,
                            detector: detector,
                            attributeAnalyzer: attributeAnalyzer,
                            videoURL: videoURL,
                            frameIndex: frameIndex,
                            duration: duration
                        )
                    }
                }

                var collected: [(Int, SavedFrame, CGImage?)] = []
                for try await result in group {
                    collected.append(result)
                }
                return collected.sorted { $0.0 < $1.0 }
            }

            for (_, frame, image) in batchResults {
                try await store.appendFrame(id: id, frame: frame, image: image)
                frames.append(frame)
                if imageSize == nil, let image {
                    imageSize = CGSize(width: image.width, height: image.height)
                    checkpoint.imageWidth = image.width
                    checkpoint.imageHeight = image.height
                }
            }

            index = batchEnd
            currentFrame = index
            analysisProgress = Double(index) / Double(totalFrames) * 0.85
            session.update(fraction: analysisProgress, subtitle: "検出 \(index)/\(totalFrames)")

            checkpoint.lastProcessedFrame = index
            checkpoint.updatedAt = Date()
            try store.updateCheckpoint(checkpoint)
        }

        return imageSize
    }

    /// 1フレームを抽出・検出・属性付与する（TaskGroup から並行に呼ばれる。self を捉えないよう static にしている）
    private nonisolated static func processFrame(
        frameExtractor: VideoFrameExtractor,
        detector: YOLODetector,
        attributeAnalyzer: PlayerAttributeAnalyzer,
        videoURL: URL,
        frameIndex: Int,
        duration: Double
    ) async throws -> (Int, SavedFrame, CGImage?) {
        let timestamp = duration > 0.05 ? min(Double(frameIndex), duration - 0.05) : 0
        let image = try await frameExtractor.extractFrame(from: videoURL, at: timestamp)
        let imageSize = CGSize(width: image.width, height: image.height)

        var detections = try await detector.detect(image: image)
        for detectionIndex in detections.indices {
            let detection = detections[detectionIndex]
            guard detection.label == SportsClass.player.rawValue || detection.label == SportsClass.goalkeeper.rawValue else { continue }

            detections[detectionIndex].uniformColor = attributeAnalyzer.uniformColor(in: image, boundingBox: detection.boundingBox)
            if frameIndex % Self.jerseyOCRInterval == 0 {
                detections[detectionIndex].jerseyNumber = attributeAnalyzer.jerseyNumber(in: image, boundingBox: detection.boundingBox)
            }
        }

        let savedDetections = detections.map { SavedDetection(detection: $0, imageSize: imageSize) }
        let frame = SavedFrame(
            frameNumber: frameIndex,
            timestamp: Double(frameIndex),
            imageFileName: AnalysisStore.imageFileName(for: frameIndex),
            detections: savedDetections
        )
        return (frameIndex, frame, image)
    }

    private nonisolated static func aspectRatio(width: Int, height: Int) -> Double {
        width > 0 && height > 0 ? Double(width) / Double(height) : 16.0 / 9.0
    }

    // MARK: - Teams

    private func collectPlayerColors(frames: [SavedFrame]) -> [(frameIndex: Int, detectionIndex: Int, color: RGBColor)] {
        var refs: [(frameIndex: Int, detectionIndex: Int, color: RGBColor)] = []
        for (frameIndex, frame) in frames.enumerated() {
            for (detectionIndex, detection) in frame.detections.enumerated() {
                guard detection.label == SportsClass.player.rawValue, let color = detection.uniformColor else { continue }
                refs.append((frameIndex, detectionIndex, color))
            }
        }
        return refs
    }

    private func applyTeams(
        _ assignments: [Int?],
        refs: [(frameIndex: Int, detectionIndex: Int, color: RGBColor)],
        to frames: inout [SavedFrame]
    ) {
        for (refIndex, ref) in refs.enumerated() {
            frames[ref.frameIndex].detections[ref.detectionIndex].team = assignments[refIndex]
        }
    }

    // MARK: - Advice retry

    private func retryMissingAdvice(for id: UUID) async {
        guard var record = store.record(for: id) else { return }
        var failureReason: String? = IntelligenceAdvisor.unavailableReason

        if failureReason == nil, record.advice == nil {
            do {
                record.advice = try await IntelligenceAdvisor.overallAdvice(for: record)
            } catch {
                failureReason = IntelligenceAdvisor.errorMessage(for: error)
            }
        }

        if var segments = record.segments {
            for index in segments.indices where segments[index].tactics == nil {
                segments[index].tactics = TacticalPlanner.snapshot(
                    for: segments[index],
                    frames: record.frames.filter { segments[index].contains($0.timestamp) },
                    aspectRatio: Self.aspectRatio(width: record.imageWidth, height: record.imageHeight)
                )
            }

            for index in segments.indices where segments[index].commentary == nil {
                guard IntelligenceAdvisor.unavailableReason == nil else {
                    failureReason = IntelligenceAdvisor.unavailableReason
                    break
                }

                let segment = segments[index]
                let segmentFrames = record.frames.filter { segment.contains($0.timestamp) }
                let metrics = AnalysisMetrics(
                    frames: segmentFrames,
                    duration: segment.endTime - segment.startTime,
                    teams: record.teams
                )
                do {
                    segments[index].commentary = try await IntelligenceAdvisor.sceneCommentary(
                        for: segment,
                        metrics: metrics,
                        teams: record.teams,
                        usedRealModel: record.usedRealModel
                    )
                } catch {
                    failureReason = IntelligenceAdvisor.errorMessage(for: error)
                }
            }
            record.segments = segments
        }

        record.adviceUnavailableReason = failureReason
        try? store.update(record)
    }
}
