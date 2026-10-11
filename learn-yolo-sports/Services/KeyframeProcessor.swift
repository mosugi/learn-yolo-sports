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
    /// ユニフォームの胴体部分の色（選手・GK・審判のみ。割合の大きい順に最大3色）
    var jerseyPalette: [WeightedColor]? = nil
    /// 読み取れた背番号（自チームらしい選手のみ）
    var jerseyNumber: Int? = nil

    var sportsClass: SportsClass? {
        SportsClass(rawValue: label)
    }

    /// ユニフォームの平均色（背番号を読む選手の絞り込みに使う）
    var jerseyColor: LabColor? {
        jerseyPalette.flatMap(WeightedColor.mean)
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
    /// 1フレームで背番号を読み取る最大人数（処理時間を抑えるため大きく写る選手から）
    private static let maxNumberReadsPerFrame = 4
    /// 背番号を読み取る最小の選手の高さ（ピクセル）
    private static let minimumHeightForNumber: CGFloat = 60

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

        var detections = rawDetections.map { detection -> ProcessedDetection in
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
                    inCourt: nil
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

            // 審判と判定された人も、ユニフォームの色がチームと一致すれば選手に戻すため色を取る
            let needsColor = inCourt && detection.label != SportsClass.ball.rawValue
            return ProcessedDetection(
                label: detection.label,
                confidence: detection.confidence,
                boundingBox: normalized,
                pitchPosition: position,
                inCourt: inCourt,
                jerseyPalette: needsColor ? pixels?.jerseyPalette(of: normalized) : nil
            )
        }

        // 背番号の読み取りは 1 秒に 2 回程度に抑える
        if let setup, !cameraMoved, index % imageInterval == 0 {
            readJerseyNumbers(in: image, detections: &detections, setup: setup)
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

    // MARK: - Jersey numbers

    /// 自チームらしい選手の背中の番号を読み取る
    private func readJerseyNumbers(in image: CGImage, detections: inout [ProcessedDetection], setup: AnalysisSetup) {
        let imageHeight = CGFloat(image.height)
        let allowed = Set(setup.rosterEntries.map(\.number))
        let candidates = detections.indices
            .filter { index in
                let detection = detections[index]
                guard detection.sportsClass == .player, detection.inCourt == true,
                      let color = detection.jerseyColor, color.distance(to: setup.ownColor) < 35 else { return false }
                return detection.boundingBox.height * imageHeight >= Self.minimumHeightForNumber
            }
            .sorted { detections[$0].boundingBox.height > detections[$1].boundingBox.height }
            .prefix(Self.maxNumberReadsPerFrame)

        for index in candidates {
            guard let crop = Self.numberRegion(of: detections[index].boundingBox, in: image) else { continue }
            detections[index].jerseyNumber = Self.recognizeNumber(in: crop, allowed: allowed)
        }
    }

    /// 背番号が写る胴体部分を切り出し、文字認識しやすい大きさに拡大する
    private static func numberRegion(of box: CGRect, in image: CGImage) -> CGImage? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let rect = CGRect(
            x: (box.minX + box.width * 0.1) * width,
            y: (box.minY + box.height * 0.12) * height,
            width: box.width * 0.8 * width,
            height: box.height * 0.45 * height
        ).integral
        guard rect.width >= 8, rect.height >= 8, let crop = image.cropping(to: rect) else { return nil }

        let targetHeight = 160
        guard crop.height < targetHeight else { return crop }
        let scale = Double(targetHeight) / Double(crop.height)
        let targetWidth = max(1, Int(Double(crop.width) * scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return crop }
        context.interpolationQuality = .high
        context.draw(crop, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? crop
    }

    /// 1〜2桁の数字だけを背番号として受け付ける
    private static func recognizeNumber(in image: CGImage, allowed: Set<Int>) -> Int? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        for observation in request.results ?? [] {
            for candidate in observation.topCandidates(3) where candidate.confidence >= 0.4 {
                let text = candidate.string.trimmingCharacters(in: .whitespaces)
                guard (1...2).contains(text.count),
                      text.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let number = Int(text) else { continue }
                if !allowed.isEmpty && !allowed.contains(number) { continue }
                return number
            }
        }
        return nil
    }
}
