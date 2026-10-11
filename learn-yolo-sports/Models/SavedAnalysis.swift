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
    /// ユニフォームの胴体部分の色（選手・GK・審判のみ。割合の大きい順に最大3色）
    var jerseyPalette: [WeightedColor]? = nil
    /// コートの床の上に立っているか（nil は判定できなかった）
    var inCourt: Bool? = nil
    /// チーム（TeamInfo.id。判定できなかった場合は nil）
    var team: Int? = nil
    /// 追跡 ID
    var trackID: Int? = nil
    /// 識別した選手（PlayerIdentity.id）
    var playerID: Int? = nil
    /// このフレームで読み取れた背番号
    var jerseyNumber: Int? = nil
    /// 追跡の結果、コート外の人（観客・控えなど）とみなした（選手の識別をやり直すと外す）
    var offPitch: Bool? = nil
    /// 追跡の結果ラベルを付け替えた場合の、検出したときのラベル（審判 → 選手など）
    var detectedLabel: String? = nil

    /// 解析対象から外した検出（コート外）か
    var isExcluded: Bool {
        inCourt == false || offPitch == true
    }

    /// 追跡・識別の結果を外し、検出したときの状態に戻す（検出結果を使い回して識別をやり直すため）
    func clearingTracking() -> SavedDetection {
        SavedDetection(
            label: detectedLabel ?? label,
            confidence: confidence,
            boundingBox: boundingBox,
            jerseyPalette: jerseyPalette,
            inCourt: inCourt,
            jerseyNumber: jerseyNumber
        )
    }

    /// バウンディングボックスの中心（正規化座標）
    var center: CGPoint {
        CGPoint(x: boundingBox.midX, y: boundingBox.midY)
    }

    /// 足元（枠の下端の中央、正規化座標）
    var footPoint: CGPoint {
        CGPoint(x: boundingBox.midX, y: boundingBox.maxY)
    }

    /// 信頼度を百分率で取得
    var confidencePercentage: Int {
        Int(confidence * 100)
    }

    private enum CodingKeys: String, CodingKey {
        case label, confidence, boundingBox, jerseyPalette, inCourt, team, trackID, playerID, jerseyNumber, offPitch, detectedLabel
    }
}

extension SavedDetection {
    /// 以前の形式（チームを "own" / "opponent" で保存していたもの）も読めるようにする
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        confidence = try container.decode(Float.self, forKey: .confidence)
        boundingBox = try container.decode(CGRect.self, forKey: .boundingBox)
        jerseyPalette = try? container.decodeIfPresent([WeightedColor].self, forKey: .jerseyPalette)
        inCourt = try? container.decodeIfPresent(Bool.self, forKey: .inCourt)
        team = try? container.decodeIfPresent(Int.self, forKey: .team)
        trackID = try? container.decodeIfPresent(Int.self, forKey: .trackID)
        playerID = try? container.decodeIfPresent(Int.self, forKey: .playerID)
        jerseyNumber = try? container.decodeIfPresent(Int.self, forKey: .jerseyNumber)
        offPitch = try? container.decodeIfPresent(Bool.self, forKey: .offPitch)
        detectedLabel = try? container.decodeIfPresent(String.self, forKey: .detectedLabel)
    }
}

/// 保存用のフレーム
nonisolated struct SavedFrame: Codable, Hashable, Identifiable {
    let frameNumber: Int
    /// 動画先頭からの時刻（秒）
    let timestamp: Double
    /// 解析ディレクトリ内の画像ファイル名（数フレームおきにだけ保存する）
    let imageFileName: String?
    var detections: [SavedDetection]
    /// 最初のフレームから見たカメラの累積の移動量（正規化座標）。画面上の位置に足すと動画全体で共通の位置になる
    var cameraOffset: CGPoint? = nil
    /// 直前のフレームから画面が切り替わった（大きく動いた・リプレイなど）か
    var sceneCut: Bool? = nil

    var id: Int { frameNumber }

    /// 指定したクラスの検出（コート外のものは除く）
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
}

/// 指定した選手の動きへのアドバイス（選手を指定したときにだけ生成する）
nonisolated struct PlayerAdvice: Codable, Hashable {
    /// PlayerIdentity.id
    let playerID: Int
    let summary: String
    let strengths: [String]
    let improvements: [String]
    let generatedAt: Date
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
    var processingDuration: Double
    /// false の場合はモックモードの結果
    let usedRealModel: Bool
    /// 選手の識別をやり直すと、チーム・追跡・選手の割り当てが書き換わる
    var frames: [SavedFrame]
    /// 生成済みのアドバイス（全体総評）
    var advice: AnalysisAdvice? = nil
    /// 動画の長さ（秒）。動画ファイルが保存されている場合のみ再生に使う
    var videoDuration: Double? = nil
    /// 解析ディレクトリ内に保存した動画ファイル名（履歴からの再生用）
    var videoFileName: String? = nil
    /// ユニフォーム色から判定したチーム
    var teams: [TeamInfo]? = nil
    /// 追跡して識別した選手（背番号または A, B, C… の記号で区別する）
    var players: [PlayerIdentity]? = nil
    /// 重要シーンの区切りとAI解説
    var segments: [SceneSegment]? = nil
    /// シーン解説や総評が生成できなかった理由（Apple Intelligence 利用不可など）
    var adviceUnavailableReason: String? = nil
    /// 選手ごとのアドバイス（指定された選手の分だけ）
    var playerAdvice: [PlayerAdvice]? = nil
    /// 選手の識別に使った1チームの人数（古い記録は nil）
    var playersPerTeam: Int? = nil
    /// 同じ動画を選び直したときに見分けるための目印（古い記録は nil）
    var fingerprint: VideoFingerprint? = nil
    /// 検出の条件（モデル・間隔など）。同じなら検出結果を使い回せる
    var detectionVersion: String? = nil
    /// 選手の追跡・識別の方式。変わっていれば識別をやり直す
    var trackingVersion: Int? = nil

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

    /// 画像が保存されているフレーム
    var framesWithImages: [SavedFrame] {
        frames.filter { $0.imageFileName != nil }
    }

    /// 指定した時刻に最も近い、画像のあるフレーム
    func nearestFrameWithImage(to time: Double) -> SavedFrame? {
        framesWithImages.min { abs($0.timestamp - time) < abs($1.timestamp - time) }
    }

    func player(id: Int?) -> PlayerIdentity? {
        guard let id else { return nil }
        return players?.first { $0.id == id }
    }

    func team(id: Int?) -> TeamInfo? {
        guard let id else { return nil }
        return teams?.first { $0.id == id }
    }
}
