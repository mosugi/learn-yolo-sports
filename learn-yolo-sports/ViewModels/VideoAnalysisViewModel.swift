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
        case .segmenting: return "選手の識別とシーンの区切り"
        case .commentating: return "シーン解説"
        }
    }
}

/// 解析中に表示するフレーム（いまどこを処理しているかを見せる）
struct AnalysisLivePreview {
    let image: CGImage
    let detections: [SavedDetection]
    let timestamp: Double
    var teams: [TeamInfo]? = nil
    var players: [PlayerIdentity]? = nil
    /// 処理中のシーン（シーン解説の段階のみ）
    var segment: SceneSegment? = nil
}

/// 動画解析のビューモデル
///
/// App で1つだけ生成して Environment で共有する。解析は View のライフサイクルから切り離した
/// Task で実行するため、タブを移動しても、アプリがバックグラウンドに移っても継続する。
/// 動画選択から検出・選手の追跡と識別・シーン区切り・AI解説の生成までを1つのパイプラインとして流す。
@MainActor
@Observable
final class VideoAnalysisViewModel {

    /// 1秒あたりに抽出するフレーム数（選手の追跡に必要な間隔）
    private static let framesPerSecond = 3
    /// 1度に並行して処理するフレーム数
    private static let batchSize = 4
    /// 解析中に表示するフレームの長辺
    private nonisolated static let previewDimension = 640

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

    /// 解析中に表示するフレーム
    var livePreview: AnalysisLivePreview?

    /// 直近の解析結果の保存 ID（AnalysisStore から参照する）
    var currentRecordID: UUID?

    /// 解析タブで未確認の解析結果があるか
    var hasUnseenResult = false

    /// 実モデルで動作しているか（nil: 未確認, false: モックモード）
    var isUsingRealModel: Bool?

    /// 解析の再開・開始以降に検出したフレーム数と、その開始時刻（残り時間の見積もりに使う）
    private var detectionStart: (date: Date, frame: Int)?

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
            let base = "\(phase.label) \(currentFrame)/\(totalFrames)"
            guard let remaining = estimatedRemaining else { return base }
            return base + "・残り" + DurationText.approximate(remaining)
        case .commentating:
            return "\(phase.label) \(currentScene)/\(totalScenes)"
        }
    }

    /// 検出の残り時間（最初の数フレームを処理するまでは見積もらない）
    var estimatedRemaining: TimeInterval? {
        guard phase == .detecting, let detectionStart else { return nil }
        let processed = currentFrame - detectionStart.frame
        guard processed >= 3 else { return nil }
        let rate = Date().timeIntervalSince(detectionStart.date) / Double(processed)
        return rate * Double(max(0, totalFrames - currentFrame))
    }

    // MARK: - Dependencies

    private let store: AnalysisStore
    private let frameExtractor = VideoFrameExtractor()
    private let detector = YOLODetector()

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

    /// スクリーンショット用のデモデータを解析結果として表示する
    func showDemo(record: SavedAnalysis) {
        currentRecordID = record.id
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
        livePreview = nil
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
            let info = try await frameExtractor.videoInfo(for: url, framesPerSecond: Self.framesPerSecond)
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
        livePreview = nil
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
            detectionStart = (Date(), checkpoint.lastProcessedFrame)
            phase = .detecting
            analysisProgress = Double(checkpoint.lastProcessedFrame) / Double(max(1, checkpoint.totalFrames)) * 0.85
            session.update(fraction: analysisProgress, subtitle: "検出 \(currentFrame)/\(totalFrames)")

            if checkpoint.lastProcessedFrame < checkpoint.totalFrames {
                imageSize = try await detectRemainingFrames(
                    id: id,
                    videoURL: videoURL,
                    checkpoint: &checkpoint,
                    frames: &frames,
                    session: session
                )
            }

            try Task.checkCancellation()

            // --- 選手の追跡と識別・シーン区切り ---
            var teams = checkpoint.teams
            var players = checkpoint.players
            var segments = checkpoint.segments
            let aspectRatio = Self.aspectRatio(width: checkpoint.imageWidth ?? 0, height: checkpoint.imageHeight ?? 0)

            if livePreview == nil {
                await showStoredFrame(of: checkpoint, at: checkpoint.videoDuration, frames: frames)
            }

            if segments == nil {
                phase = .segmenting
                session.update(fraction: 0.85, subtitle: phase.label)
                checkpoint.stage = .segmenting
                checkpoint.updatedAt = Date()
                try store.updateCheckpoint(checkpoint)

                let detectedFrames = frames
                let (tracked, result) = await Task.detached(priority: .userInitiated) {
                    var tracked = detectedFrames
                    let result = PlayerTracker.analyze(frames: tracked, aspectRatio: aspectRatio)
                    result.apply(to: &tracked)
                    return (tracked, result)
                }.value
                frames = tracked
                teams = result.teams
                players = result.players
                segments = SceneSegmenter.segments(frames: frames, duration: checkpoint.videoDuration)

                try await store.rewriteFrames(id: id, frames: frames)

                checkpoint.teams = teams
                checkpoint.players = players
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
                framesPerSecond: checkpoint.framesPerSecond,
                imageWidth: Int(imageSize?.width ?? 0),
                imageHeight: Int(imageSize?.height ?? 0),
                processingDuration: Date().timeIntervalSince(startTime),
                usedRealModel: checkpoint.usedRealModel,
                frames: frames,
                videoDuration: checkpoint.videoDuration,
                videoFileName: checkpoint.videoFileName,
                teams: teams,
                players: players,
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
                await showStoredFrame(
                    of: checkpoint,
                    at: resolvedSegments[index].keyTime,
                    frames: frames,
                    teams: teams,
                    players: players,
                    segment: resolvedSegments[index]
                )
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
                        aspectRatio: Self.aspectRatio(width: record.imageWidth, height: record.imageHeight),
                        players: players
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
                    teams: teams,
                    players: players
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
        livePreview = nil
        detectionStart = nil
        analysisTask = nil
        backgroundSession = nil
        processingCheckpointID = nil
    }

    /// 未処理のフレームを検出する（画像生成・検出・OCR は TaskGroup で同時に数枚処理する）
    ///
    /// カメラの動きは、直前のフレームとの位置合わせを順番に積み上げて求める（選手の追跡に使う）。
    private func detectRemainingFrames(
        id: UUID,
        videoURL: URL,
        checkpoint: inout AnalysisCheckpoint,
        frames: inout [SavedFrame],
        session: ContinuedProcessingSession
    ) async throws -> CGSize? {
        var imageSize: CGSize?
        var index = checkpoint.lastProcessedFrame
        let totalFrames = checkpoint.totalFrames
        let framesPerSecond = max(1, checkpoint.framesPerSecond)
        let duration = checkpoint.videoDuration
        var previousOffset = frames.last?.cameraOffset ?? .zero
        var previousShift = CGPoint.zero
        var failedRegistrations = 0
        // 再開した場合は、カメラの動きを続けて求められるよう直前のフレームを取り出し直す
        var previousThumbnail: CGImage?
        if index > 0 {
            let time = Double(index - 1) / Double(framesPerSecond)
            if let image = try? await frameExtractor.extractFrame(from: videoURL, at: duration > 0.05 ? min(time, duration - 0.05) : 0) {
                previousThumbnail = FrameImageIO.downscaled(image, maxDimension: PlayerAttributeAnalyzer.thumbnailDimension) ?? image
            }
        }

        while index < totalFrames {
            try Task.checkCancellation()

            let batchEnd = min(index + Self.batchSize, totalFrames)
            let batchIndices = Array(index..<batchEnd)

            let frameExtractor = self.frameExtractor
            let detector = self.detector

            let batchResults = try await withThrowingTaskGroup(of: ProcessedFrame.self) { group in
                for frameIndex in batchIndices {
                    group.addTask {
                        try await Self.processFrame(
                            frameExtractor: frameExtractor,
                            detector: detector,
                            videoURL: videoURL,
                            frameIndex: frameIndex,
                            framesPerSecond: framesPerSecond,
                            duration: duration
                        )
                    }
                }

                var collected: [ProcessedFrame] = []
                for try await result in group {
                    collected.append(result)
                }
                return collected.sorted { $0.frame.frameNumber < $1.frame.frameNumber }
            }

            for result in batchResults {
                var frame = result.frame
                if frame.frameNumber > 0 {
                    // 手前を人が横切るなどで位置合わせに失敗したときは、直前と同じだけ動いたとみなす。
                    // 1秒以上続けて失敗した場合だけ、画面が切り替わったとして追跡を区切る
                    if let shift = previousThumbnail.flatMap({ PlayerAttributeAnalyzer.cameraShift(from: $0, to: result.thumbnail) }) {
                        previousShift = shift
                        failedRegistrations = 0
                    } else {
                        failedRegistrations += 1
                        if failedRegistrations == framesPerSecond {
                            frame.sceneCut = true
                            previousShift = .zero
                        }
                    }
                    previousOffset = CGPoint(x: previousOffset.x + previousShift.x, y: previousOffset.y + previousShift.y)
                }
                frame.cameraOffset = previousOffset
                previousThumbnail = result.thumbnail

                try await store.appendFrame(id: id, frame: frame, image: result.image)
                frames.append(frame)
                if imageSize == nil {
                    imageSize = result.imageSize
                    checkpoint.imageWidth = Int(result.imageSize.width)
                    checkpoint.imageHeight = Int(result.imageSize.height)
                }
            }

            if let last = batchResults.last {
                livePreview = AnalysisLivePreview(
                    image: last.preview,
                    detections: last.frame.detections,
                    timestamp: last.frame.timestamp
                )
            }

            index = batchEnd
            currentFrame = index
            analysisProgress = Double(index) / Double(totalFrames) * 0.85
            session.update(fraction: analysisProgress, subtitle: progressDescription)

            checkpoint.lastProcessedFrame = index
            checkpoint.updatedAt = Date()
            try store.updateCheckpoint(checkpoint)
        }

        return imageSize ?? checkpoint.imageWidth.flatMap { width in
            checkpoint.imageHeight.map { CGSize(width: width, height: $0) }
        }
    }

    /// 1フレームの処理結果
    private nonisolated struct ProcessedFrame: @unchecked Sendable {
        let frame: SavedFrame
        /// 保存する画像（数フレームおきのみ）
        let image: CGImage?
        /// カメラの動きを求めるための縮小画像
        let thumbnail: CGImage
        /// 解析中の画面に表示する縮小画像
        let preview: CGImage
        let imageSize: CGSize
    }

    /// 1フレームを抽出・検出・属性付与する（TaskGroup から並行に呼ばれる。self を捉えないよう static にしている）
    private nonisolated static func processFrame(
        frameExtractor: VideoFrameExtractor,
        detector: YOLODetector,
        videoURL: URL,
        frameIndex: Int,
        framesPerSecond: Int,
        duration: Double
    ) async throws -> ProcessedFrame {
        let time = Double(frameIndex) / Double(framesPerSecond)
        let image = try await frameExtractor.extractFrame(from: videoURL, at: duration > 0.05 ? min(time, duration - 0.05) : 0)

        // 背番号の読み取りと画像の保存は 1 秒に 1 回にする
        let isKeyFrame = frameIndex % framesPerSecond == 0
        let detections = try await detector.detect(image: image)
        let savedDetections = PlayerAttributeAnalyzer.savedDetections(from: detections, in: image, readsNumbers: isKeyFrame)

        let frame = SavedFrame(
            frameNumber: frameIndex,
            timestamp: time,
            imageFileName: isKeyFrame ? AnalysisStore.imageFileName(for: frameIndex) : nil,
            detections: savedDetections
        )
        return ProcessedFrame(
            frame: frame,
            image: isKeyFrame ? image : nil,
            thumbnail: FrameImageIO.downscaled(image, maxDimension: PlayerAttributeAnalyzer.thumbnailDimension) ?? image,
            preview: FrameImageIO.downscaled(image, maxDimension: previewDimension) ?? image,
            imageSize: CGSize(width: image.width, height: image.height)
        )
    }

    /// 保存済みのキーフレーム（1秒ごと）のうち、指定時刻に最も近いものを解析中の画面に表示する
    private func showStoredFrame(
        of checkpoint: AnalysisCheckpoint,
        at time: Double,
        frames: [SavedFrame],
        teams: [TeamInfo]? = nil,
        players: [PlayerIdentity]? = nil,
        segment: SceneSegment? = nil
    ) async {
        let keyFrames = frames.filter { $0.imageFileName != nil }
        guard let frame = keyFrames.min(by: { abs($0.timestamp - time) < abs($1.timestamp - time) }),
              let image = await store.loadFrameImage(for: checkpoint, frameNumber: frame.frameNumber) else { return }
        livePreview = AnalysisLivePreview(
            image: image,
            detections: frame.detections,
            timestamp: frame.timestamp,
            teams: teams,
            players: players,
            segment: segment
        )
    }

    private nonisolated static func aspectRatio(width: Int, height: Int) -> Double {
        width > 0 && height > 0 ? Double(width) / Double(height) : 16.0 / 9.0
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
                    aspectRatio: Self.aspectRatio(width: record.imageWidth, height: record.imageHeight),
                    players: record.players
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
                    teams: record.teams,
                    players: record.players
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
