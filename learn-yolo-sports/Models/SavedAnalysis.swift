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
    
    var id: Int { frameNumber }
    
    func detections(of sportsClass: SportsClass) -> [SavedDetection] {
        detections.filter { $0.label == sportsClass.rawValue }
    }
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

extension SavedAnalysis {
    /// 解析結果から保存用データを作る
    nonisolated init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        videoName: String,
        framesPerSecond: Int,
        processingDuration: Double,
        usedRealModel: Bool,
        results: [FrameDetectionResult]
    ) {
        let width = results.first?.image?.width ?? 0
        let height = results.first?.image?.height ?? 0
        
        self.init(
            id: id,
            createdAt: createdAt,
            videoName: videoName,
            framesPerSecond: framesPerSecond,
            imageWidth: width,
            imageHeight: height,
            processingDuration: processingDuration,
            usedRealModel: usedRealModel,
            frames: results.map { result in
                let w = CGFloat(result.image?.width ?? width)
                let h = CGFloat(result.image?.height ?? height)
                return SavedFrame(
                    frameNumber: result.frameNumber,
                    timestamp: result.timestamp,
                    imageFileName: result.image == nil ? nil : AnalysisStore.imageFileName(for: result.frameNumber),
                    detections: result.detections.map { detection in
                        let box = detection.boundingBox
                        return SavedDetection(
                            label: detection.label,
                            confidence: detection.confidence,
                            boundingBox: w > 0 && h > 0
                                ? CGRect(x: box.minX / w, y: box.minY / h, width: box.width / w, height: box.height / h)
                                : .zero
                        )
                    }
                )
            }
        )
    }
}
