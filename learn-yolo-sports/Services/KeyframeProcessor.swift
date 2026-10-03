//
//  KeyframeProcessor.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation
import CoreGraphics
import Vision

/// 1フレーム分の処理結果
nonisolated struct ProcessedFrame {
    let index: Int
    let timestamp: Double
    let detections: [ProcessedDetection]
    /// 設定時からカメラが動いた（座標変換が使えない）フレームか
    let cameraMoved: Bool
    let imageFileName: String?
}

nonisolated struct ProcessedDetection {
    let label: String
    let confidence: Float
    /// 元画像に対する正規化座標（0〜1、左上原点）
    let boundingBox: CGRect
    /// 足元のピッチ座標（m）
    let pitchPosition: CGPoint?
    /// 対象コート内か（コート設定がない場合は nil）
    let inCourt: Bool?
    /// ユニフォームの色（選手・GK のみ）
    let jerseyColor: LabColor?

    var sportsClass: SportsClass? {
        SportsClass(rawValue: label)
    }
}

/// フレームごとの検出、コート判定、色の取得、画像の保存を行う
///
/// フレームは処理したらすぐ手放し、結果（検出と色）だけを保持する。
actor KeyframeProcessor {

    private let detector: YOLODetector
    private let setup: AnalysisSetup?
    private let geometry: CourtGeometry?
    /// カメラの動きを判定するための基準画像（縮小済み）
    private let referenceImage: CGImage?
    private let outputDirectory: URL
    /// 何フレームごとに画像を保存するか
    private let imageInterval: Int

    private(set) var results: [ProcessedFrame] = []
    /// 元画像のピクセルサイズ
    private(set) var imageSize: CGSize?

    /// 基準画像との位置ずれがこれを超えたらカメラが動いたとみなす（画像幅に対する割合）
    private static let cameraMovementThreshold = 0.02
    private static let thumbnailDimension = 320

    init(detector: YOLODetector, setup: AnalysisSetup?, referenceImage: CGImage?, outputDirectory: URL, imageInterval: Int) {
        self.detector = detector
        self.setup = setup
        self.geometry = setup.flatMap { CourtGeometry(setup: $0) }
        self.referenceImage = referenceImage.flatMap {
            FrameImageIO.downscaled($0, maxDimension: KeyframeProcessor.thumbnailDimension) ?? $0
        }
        self.outputDirectory = outputDirectory
        self.imageInterval = max(1, imageInterval)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    func process(_ frame: ExtractedFrame, index: Int) async throws -> ProcessedFrame {
        let image = frame.image
        let imageSize = CGSize(width: image.width, height: image.height)
        if self.imageSize == nil {
            self.imageSize = imageSize
        }

        // コートの周辺だけを切り出して検出する（背景が減り、選手が大きく写る）
        var region = CGRect(x: 0, y: 0, width: 1, height: 1)
        var target = image
        if let rect = geometry?.detectionRegion() {
            let pixelRect = CGRect(
                x: rect.minX * imageSize.width,
                y: rect.minY * imageSize.height,
                width: rect.width * imageSize.width,
                height: rect.height * imageSize.height
            ).integral
            if let cropped = image.cropping(to: pixelRect) {
                target = cropped
                region = CGRect(
                    x: pixelRect.minX / imageSize.width,
                    y: pixelRect.minY / imageSize.height,
                    width: pixelRect.width / imageSize.width,
                    height: pixelRect.height / imageSize.height
                )
            }
        }

        let rawDetections = try await detector.detect(image: target)
        let targetWidth = CGFloat(target.width), targetHeight = CGFloat(target.height)

        let cameraMoved = hasCameraMoved(image)
        let pixels = setup == nil ? nil : PixelImage(image: image)

        let detections = rawDetections.map { detection -> ProcessedDetection in
            // 切り出し画像のピクセル座標 → 元画像の正規化座標
            let box = detection.boundingBox
            let normalized = CGRect(
                x: region.minX + box.minX / targetWidth * region.width,
                y: region.minY + box.minY / targetHeight * region.height,
                width: box.width / targetWidth * region.width,
                height: box.height / targetHeight * region.height
            )

            guard let geometry, !cameraMoved else {
                return ProcessedDetection(
                    label: detection.label,
                    confidence: detection.confidence,
                    boundingBox: normalized,
                    pitchPosition: nil,
                    inCourt: nil,
                    jerseyColor: nil
                )
            }

            let isPerson = detection.label == SportsClass.player.rawValue
                || detection.label == SportsClass.goalkeeper.rawValue
                || detection.label == SportsClass.referee.rawValue
            let position = geometry.pitchPoint(fromImage: CourtGeometry.footPoint(of: normalized))
            var inCourt = position.map(geometry.contains) ?? false
            if inCourt && isPerson {
                inCourt = geometry.hasPlausibleHeight(normalized, imageSize: imageSize)
            }

            let needsColor = inCourt && detection.label != SportsClass.ball.rawValue
                && detection.label != SportsClass.referee.rawValue
            return ProcessedDetection(
                label: detection.label,
                confidence: detection.confidence,
                boundingBox: normalized,
                pitchPosition: position,
                inCourt: inCourt,
                jerseyColor: needsColor ? pixels?.jerseyColor(of: normalized) : nil
            )
        }

        var imageFileName: String?
        if index % imageInterval == 0 {
            let fileName = AnalysisStore.imageFileName(for: index)
            do {
                try FrameImageIO.writeJPEG(image, to: outputDirectory.appending(path: fileName), maxDimension: 960)
                imageFileName = fileName
            } catch {
                print("⚠️ フレーム画像の保存に失敗: \(error)")
            }
        }

        let result = ProcessedFrame(
            index: index,
            timestamp: frame.timestamp,
            detections: detections,
            cameraMoved: cameraMoved,
            imageFileName: imageFileName
        )
        results.append(result)
        return result
    }

    /// 設定時の画像からカメラが動いたか
    private func hasCameraMoved(_ image: CGImage) -> Bool {
        guard geometry != nil, let referenceImage,
              let current = FrameImageIO.downscaled(image, maxDimension: Self.thumbnailDimension) else { return false }

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: current, options: [:])
        let handler = VNImageRequestHandler(cgImage: referenceImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return false
        }
        guard let observation = request.results?.first else { return false }
        let transform = observation.alignmentTransform
        let shift = hypot(Double(transform.tx), Double(transform.ty)) / Double(referenceImage.width)
        return shift > Self.cameraMovementThreshold
    }
}
