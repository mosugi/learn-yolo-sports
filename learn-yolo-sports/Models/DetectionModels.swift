//
//  DetectionModels.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation
import CoreGraphics
import SwiftUI

/// 検出されたオブジェクト
nonisolated struct Detection: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Float
    let boundingBox: CGRect
    let color: Color
    
    /// 信頼度を百分率で取得
    var confidencePercentage: Int {
        Int(confidence * 100)
    }
}

/// サッカー検出モデルのクラスラベル（モデルの names と一致させる）
nonisolated enum SportsClass: String, CaseIterable {
    case ball = "ball"
    case player = "player"
    case referee = "referee"
    case goalkeeper = "goalkeeper"
    
    /// クラスごとの色
    var color: Color {
        switch self {
        case .ball: return .red
        case .player: return .blue
        case .referee: return .yellow
        case .goalkeeper: return .green
        }
    }
    
    /// 日本語名
    var japaneseName: String {
        switch self {
        case .ball: return "ボール"
        case .player: return "選手"
        case .referee: return "審判"
        case .goalkeeper: return "ゴールキーパー"
        }
    }
}

/// フレームの検出結果
nonisolated struct FrameDetectionResult: Identifiable {
    let id = UUID()
    let frameNumber: Int
    let timestamp: Double
    let detections: [Detection]
    let image: CGImage?
    
    /// 検出されたオブジェクトの総数
    var totalDetections: Int {
        detections.count
    }
    
    /// クラスごとの検出数
    var detectionsByClass: [String: Int] {
        Dictionary(grouping: detections, by: { $0.label })
            .mapValues { $0.count }
    }
}

/// 動画全体の解析結果
nonisolated struct VideoAnalysisResult {
    let totalFrames: Int
    let processedFrames: Int
    let detectionResults: [FrameDetectionResult]
    let duration: TimeInterval
    
    /// 全フレームでの検出総数
    var totalDetections: Int {
        detectionResults.reduce(0) { $0 + $1.totalDetections }
    }
    
    /// 平均検出数
    var averageDetectionsPerFrame: Double {
        guard processedFrames > 0 else { return 0 }
        return Double(totalDetections) / Double(processedFrames)
    }
    
    /// クラスごとの出現頻度
    var classFrequency: [String: Int] {
        var frequency: [String: Int] = [:]
        for result in detectionResults {
            for detection in result.detections {
                frequency[detection.label, default: 0] += 1
            }
        }
        return frequency
    }
}
