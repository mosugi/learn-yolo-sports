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
    /// ユニフォームの色（player/goalkeeper のみ）
    var uniformColor: RGBColor? = nil
    /// チーム判定（0 or 1、player のみ）
    var team: Int? = nil
    /// OCR で読み取れた背番号
    var jerseyNumber: Int? = nil

    /// バウンディングボックスの中心（正規化座標）
    var center: CGPoint {
        CGPoint(x: boundingBox.midX, y: boundingBox.midY)
    }

    /// 信頼度を百分率で取得
    var confidencePercentage: Int {
        Int(confidence * 100)
    }
}

/// 保存用のフレーム
nonisolated struct SavedFrame: Codable, Hashable, Identifiable {
    let frameNumber: Int
    /// 動画先頭からの時刻（秒）
    let timestamp: Double
    /// 解析ディレクトリ内の画像ファイル名
    let imageFileName: String?
    var detections: [SavedDetection]
    
    var id: Int { frameNumber }
    
    func detections(of sportsClass: SportsClass) -> [SavedDetection] {
        detections.filter { $0.label == sportsClass.rawValue }
    }
}

/// Apple Intelligence によるアドバイス
nonisolated struct AnalysisAdvice: Codable, Hashable {
    let summary: String
    let observations: [String]
    let suggestions: [String]
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
    let frames: [SavedFrame]
    /// 生成済みのアドバイス（全体総評）
    var advice: AnalysisAdvice? = nil
    /// 動画の長さ（秒）。動画ファイルが保存されている場合のみ再生に使う
    var videoDuration: Double? = nil
    /// 解析ディレクトリ内に保存した動画ファイル名（履歴からの再生用）
    var videoFileName: String? = nil
    /// ユニフォーム色から判定したチーム
    var teams: [TeamInfo]? = nil
    /// 重要シーンの区切りとAI解説
    var segments: [SceneSegment]? = nil
    /// シーン解説や総評が生成できなかった理由（Apple Intelligence 利用不可など）
    var adviceUnavailableReason: String? = nil

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

extension SavedDetection {
    /// Detection（ピクセル座標）から正規化座標の保存用データを作る
    nonisolated init(detection: Detection, imageSize: CGSize) {
        let box = detection.boundingBox
        let w = imageSize.width
        let h = imageSize.height
        self.init(
            label: detection.label,
            confidence: detection.confidence,
            boundingBox: w > 0 && h > 0
                ? CGRect(x: box.minX / w, y: box.minY / h, width: box.width / w, height: box.height / h)
                : .zero,
            uniformColor: detection.uniformColor,
            team: detection.team,
            jerseyNumber: detection.jerseyNumber
        )
    }
}
