//
//  YOLODetector.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Vision
import CoreML
import CoreGraphics
import UIKit
import SwiftUI

/// YOLO物体検出を行うクラス
actor YOLODetector {
    
    private var model: VNCoreMLModel?
    private let confidenceThreshold: Float = 0.25
    
    init() {
        Task {
            await loadModel()
        }
    }
    
    /// モデルを読み込む
    private func loadModel() async {
        // 注意: 実際のYOLOモデルが必要です
        // ここでは仮のコードを記載しています
        print("🤖 YOLOモデルを読み込み中...")
        
        // TODO: 実際のCore MLモデルを読み込む
        // 例: let model = try? YOLOv8(configuration: MLModelConfiguration())
        // self.model = try? VNCoreMLModel(for: model.model)
        
        print("⚠️ YOLOモデルが未設定です。モックモードで動作します。")
    }
    
    /// 画像から物体を検出
    /// - Parameter image: 検出対象の画像
    /// - Returns: 検出結果の配列
    func detect(image: CGImage) async throws -> [Detection] {
        
        // モックモードの場合
        if model == nil {
            return generateMockDetections(for: image)
        }
        
        guard let model = model else {
            throw DetectionError.modelNotLoaded
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNCoreMLRequest(model: model) { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let results = request.results as? [VNRecognizedObjectObservation] else {
                    continuation.resume(returning: [])
                    return
                }
                
                let detections = self.processResults(results, imageSize: CGSize(width: image.width, height: image.height))
                continuation.resume(returning: detections)
            }
            
            request.imageCropAndScaleOption = .scaleFill
            
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    /// Vision の結果を Detection に変換
    private func processResults(_ results: [VNRecognizedObjectObservation], imageSize: CGSize) -> [Detection] {
        return results
            .filter { $0.confidence >= confidenceThreshold }
            .map { observation in
                let label = observation.labels.first?.identifier ?? "unknown"
                let confidence = observation.confidence
                
                // Vision の座標系 (左下原点) から UIKit の座標系 (左上原点) に変換
                let boundingBox = VNImageRectForNormalizedRect(
                    observation.boundingBox,
                    Int(imageSize.width),
                    Int(imageSize.height)
                )
                
                // 色を決定
                let color = SportsClass(rawValue: label)?.color ?? .gray
                
                return Detection(
                    label: label,
                    confidence: confidence,
                    boundingBox: boundingBox,
                    color: color
                )
            }
    }
    
    /// モック検出結果を生成（テスト用）
    private func generateMockDetections(for image: CGImage) -> [Detection] {
        let imageSize = CGSize(width: image.width, height: image.height)
        
        // ランダムな検出結果を生成
        let mockCount = Int.random(in: 2...5)
        
        return (0..<mockCount).map { index in
            let randomClass = SportsClass.allCases.randomElement()!
            
            // ランダムな位置とサイズ
            let x = CGFloat.random(in: 0.1...0.7) * imageSize.width
            let y = CGFloat.random(in: 0.1...0.7) * imageSize.height
            let width = CGFloat.random(in: 0.1...0.3) * imageSize.width
            let height = CGFloat.random(in: 0.1...0.3) * imageSize.height
            
            return Detection(
                label: randomClass.rawValue,
                confidence: Float.random(in: 0.5...0.95),
                boundingBox: CGRect(x: x, y: y, width: width, height: height),
                color: randomClass.color
            )
        }
    }
}

/// 検出エラー
enum DetectionError: Error, LocalizedError {
    case modelNotLoaded
    case detectionFailed
    
    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "モデルが読み込まれていません"
        case .detectionFailed:
            return "検出に失敗しました"
        }
    }
}
