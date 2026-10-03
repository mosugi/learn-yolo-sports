//
//  YOLODetector.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Vision
import CoreML
import CoreGraphics
import SwiftUI

/// YOLO物体検出を行うクラス
actor YOLODetector {

    /// バンドルに含めるCore MLモデル名（scripts/setup_model.sh で生成）
    static let modelName = "FootballPlayerDetector"

    private var model: VNCoreMLModel?
    private var didAttemptLoad = false
    private let confidenceThreshold: Float = 0.25

    /// 実モデルで動作しているか（false の場合はモックモード）
    var isModelLoaded: Bool {
        loadModelIfNeeded()
        return model != nil
    }

    /// モデルを読み込む（初回のみ）
    private func loadModelIfNeeded() {
        guard !didAttemptLoad else { return }
        didAttemptLoad = true

        // Xcode が .mlpackage を .mlmodelc にコンパイルしてバンドルに含める
        guard let url = Bundle.main.url(forResource: Self.modelName, withExtension: "mlmodelc") else {
            print("⚠️ \(Self.modelName).mlmodelc が見つかりません。モックモードで動作します。")
            return
        }

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let mlModel = try MLModel(contentsOf: url, configuration: config)
            self.model = try VNCoreMLModel(for: mlModel)
            print("✅ YOLOモデル読み込み完了: \(Self.modelName)")
        } catch {
            print("❌ モデル読み込みエラー: \(error)")
        }
    }

    /// 画像から物体を検出
    /// - Parameter image: 検出対象の画像
    /// - Returns: 検出結果の配列
    func detect(image: CGImage) throws -> [Detection] {
        loadModelIfNeeded()

        // モックモードの場合
        guard let model else {
            return generateMockDetections(for: image)
        }

        let request = VNCoreMLRequest(model: model)
        // YOLO の学習時と同じくアスペクト比を保ってリサイズ（座標は Vision が元画像基準に戻す）
        request.imageCropAndScaleOption = .scaleFit

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let results = request.results as? [VNRecognizedObjectObservation] else {
            return []
        }

        return processResults(results, imageSize: CGSize(width: image.width, height: image.height))
    }

    /// Vision の結果を Detection に変換
    private func processResults(_ results: [VNRecognizedObjectObservation], imageSize: CGSize) -> [Detection] {
        return results
            .filter { $0.confidence >= confidenceThreshold }
            .map { observation in
                let label = observation.labels.first?.identifier ?? "unknown"
                let box = observation.boundingBox

                // Vision の正規化座標 (左下原点) を画像のピクセル座標 (左上原点) に変換
                let boundingBox = CGRect(
                    x: box.minX * imageSize.width,
                    y: (1 - box.maxY) * imageSize.height,
                    width: box.width * imageSize.width,
                    height: box.height * imageSize.height
                )

                return Detection(
                    label: label,
                    confidence: observation.confidence,
                    boundingBox: boundingBox,
                    color: SportsClass(rawValue: label)?.color ?? .gray
                )
            }
    }

    /// モック検出結果を生成（モデル未配置時用）
    private func generateMockDetections(for image: CGImage) -> [Detection] {
        let imageSize = CGSize(width: image.width, height: image.height)

        // ランダムな検出結果を生成
        let mockCount = Int.random(in: 2...5)

        return (0..<mockCount).map { _ in
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
nonisolated enum DetectionError: Error, LocalizedError {
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
