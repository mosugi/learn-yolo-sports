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
