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
struct Detection: Identifiable {
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

/// スポーツ関連のクラスラベル
enum SportsClass: String, CaseIterable {
    case person = "person"
    case ball = "sports ball"
    case baseball = "baseball bat"
    case tennis = "tennis racket"
    case skateboard = "skateboard"
    case surfboard = "surfboard"
    case skis = "skis"
    case snowboard = "snowboard"
    case frisbee = "frisbee"
    case kite = "kite"
    
    /// クラスごとの色
    var color: Color {
        switch self {
        case .person: return .blue
        case .ball: return .red
        case .baseball: return .orange
        case .tennis: return .green
        case .skateboard: return .purple
        case .surfboard: return .cyan
        case .skis: return .yellow
        case .snowboard: return .pink
        case .frisbee: return .mint
        case .kite: return .indigo
        }
    }
    
    /// 日本語名
    var japaneseName: String {
        switch self {
        case .person: return "人"
        case .ball: return "ボール"
        case .baseball: return "バット"
        case .tennis: return "ラケット"
        case .skateboard: return "スケートボード"
        case .surfboard: return "サーフボード"
        case .skis: return "スキー"
        case .snowboard: return "スノーボード"
        case .frisbee: return "フリスビー"
        case .kite: return "凧"
        }
    }
}

/// フレームの検出結果
struct FrameDetectionResult: Identifiable {
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
struct VideoAnalysisResult {
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
