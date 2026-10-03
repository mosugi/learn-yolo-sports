//
//  SavedAnalysis.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation
import CoreGraphics

/// 保存用の検出結果
nonisolated struct SavedDetection: Codable, Hashable {
    let label: String
    let confidence: Float
    /// 画像に対する正規化座標（0〜1、左上原点）
    let boundingBox: CGRect
    /// 足元のピッチ座標（m）。コート設定がない場合は nil
    var pitchPosition: CGPoint? = nil
    /// 対象コート内か（nil はコート設定なし）
    var inCourt: Bool? = nil
    /// 所属チーム（判定できなかった場合は nil）
    var team: TeamSide? = nil
    /// 追跡 ID
    var trackID: Int? = nil
    /// このフレームで読み取れた背番号
    var jerseyNumber: Int? = nil
    
    /// 解析対象から外した検出（対象コート外）か
    var isExcluded: Bool {
        inCourt == false
    }
    
    /// バウンディングボックスの中心（正規化座標）
    var center: CGPoint {
        CGPoint(x: boundingBox.midX, y: boundingBox.midY)
    }
}

/// 保存用のフレーム
nonisolated struct SavedFrame: Codable, Hashable, Identifiable {
    let frameNumber: Int
    /// 動画先頭からの時刻（秒）
    let timestamp: Double
    /// 解析ディレクトリ内の画像ファイル名
    let imageFileName: String?
    let detections: [SavedDetection]
    /// 自チームから見た局面（コート設定がある場合）
    var phase: GamePhase? = nil
    /// ボール保持チーム
    var possession: TeamSide? = nil
    /// ボールのピッチ座標（短い欠損は補間済み）
    var ball: CGPoint? = nil
    
    var id: Int { frameNumber }
    
    /// 指定したクラスの検出（対象コート外のものは除く）
    func detections(of sportsClass: SportsClass) -> [SavedDetection] {
        detections.filter { $0.label == sportsClass.rawValue && !$0.isExcluded }
    }
}

/// Apple Intelligence によるアドバイス
nonisolated struct AnalysisAdvice: Codable, Hashable {
    let summary: String
    let observations: [String]
    let suggestions: [String]
    let generatedAt: Date
    /// 背番号ごとのアドバイス（例: #10: 〜）
    var playerAdvice: [String]? = nil
}

/// 保存された解析結果
nonisolated struct SavedAnalysis: Codable, Hashable, Identifiable {
    let id: UUID
    let createdAt: Date
    let videoName: String
    let framesPerSecond: Int
    let imageWidth: Int
    let imageHeight: Int
    /// 解析にかかった時間（秒）
    let processingDuration: Double
    /// false の場合はモックモードの結果
    let usedRealModel: Bool
    let frames: [SavedFrame]
    /// 生成済みのアドバイス
    var advice: AnalysisAdvice? = nil
    /// コート・チームの設定（未設定で解析した場合は nil）
    var setup: AnalysisSetup? = nil
    /// ルールベースのコーチ解説（コート設定がある場合のみ）
    var coachReport: CoachReport? = nil
    /// 得点シーンなどのチャプター
    var chapters: [MatchChapter]? = nil
    /// 背番号の読み取りから推定した、追跡 ID ごとの背番号
    var trackNumbers: [Int: Int]? = nil
    /// ユーザーが割り当てた背番号（追跡 ID → 背番号。0 は割り当ての解除）
    var numberOverrides: [Int: Int]? = nil
    
    /// 追跡 ID ごとの背番号（ユーザーの割り当てを優先）
    var effectiveTrackNumbers: [Int: Int] {
        var numbers = trackNumbers ?? [:]
        for (trackID, number) in numberOverrides ?? [:] {
            numbers[trackID] = number > 0 ? number : nil
        }
        return numbers
    }
    
    var chapterList: [MatchChapter] {
        (chapters ?? []).sorted { $0.eventTime < $1.eventTime }
    }
    
    /// 動画ファイル（取り込み時に Documents へコピーしたもの）
    var videoURL: URL {
        URL.documentsDirectory.appending(path: videoName)
    }
    
    /// 画像が保存されているフレーム
    var framesWithImages: [SavedFrame] {
        frames.filter { $0.imageFileName != nil }
    }
    
    /// 指定した時刻に最も近い、画像のあるフレーム
    func nearestFrameWithImage(to time: Double) -> SavedFrame? {
        framesWithImages.min { abs($0.timestamp - time) < abs($1.timestamp - time) }
    }
    
    // MARK: - 集計
    
    var totalDetections: Int {
        frames.reduce(0) { $0 + $1.detections.count }
    }
    
    var averageDetectionsPerFrame: Double {
        guard !frames.isEmpty else { return 0 }
        return Double(totalDetections) / Double(frames.count)
    }
    
    /// クラスごとの検出数
    var classFrequency: [String: Int] {
        var frequency: [String: Int] = [:]
        for frame in frames {
            for detection in frame.detections {
                frequency[detection.label, default: 0] += 1
            }
        }
        return frequency
    }
    
    /// ボールが検出されたフレームの割合
    var ballDetectionRate: Double {
        guard !frames.isEmpty else { return 0 }
        let count = frames.filter { !$0.detections(of: .ball).isEmpty }.count
        return Double(count) / Double(frames.count)
    }
    
    /// 解析対象の時間幅（秒）
    var coveredDuration: Double {
        guard let first = frames.first, let last = frames.last else { return 0 }
        return last.timestamp - first.timestamp
    }
}

extension SavedFrame {
    /// 解析結果から保存用のフレームを作る
    nonisolated init(processed frame: ProcessedFrame, assignments: [Int: DetectionAssignment]?, state: FrameState?) {
        self.init(
            frameNumber: frame.index,
            timestamp: frame.timestamp,
            imageFileName: frame.imageFileName,
            detections: frame.detections.enumerated().map { index, detection in
                let assignment = assignments?[index]
                return SavedDetection(
                    label: detection.label,
                    confidence: detection.confidence,
                    boundingBox: detection.boundingBox,
                    pitchPosition: detection.pitchPosition,
                    inCourt: detection.inCourt,
                    team: assignment?.team,
                    trackID: assignment?.trackID,
                    jerseyNumber: detection.jerseyNumber
                )
            },
            phase: state?.phase,
            possession: state?.possession,
            ball: state?.ball
        )
    }
}
