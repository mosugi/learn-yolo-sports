//
//  PlayerAttributeAnalyzer.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Vision
import CoreGraphics

/// 1フレームの検出に、ユニフォームの色・コート内か・背番号を付ける
///
/// カメラが動く動画を前提に、コートの4隅のような固定の設定は使わない。
/// コート外の判定は、フレームごとに床の色を求め、その上に立っているかで行う。
nonisolated enum PlayerAttributeAnalyzer {

    /// 1フレームで背番号を読み取る最大人数（処理時間を抑えるため大きく写る選手から）
    private static let maxNumberReadsPerFrame = 4
    /// 背番号を読み取る最小の選手の高さ（ピクセル）
    private static let minimumHeightForNumber: CGFloat = 60
    /// カメラの動きを求める縮小画像の長辺
    static let thumbnailDimension = 320
    /// 直前のフレームからこれ以上ずれたら、画面が切り替わったとみなす（画面に対する割合）
    private static let sceneCutShift = 0.25

    /// YOLO の検出（ピクセル座標）を、属性付きの保存用データ（正規化座標）にする
    /// - Parameter readsNumbers: 背番号の読み取りを行うか（処理時間を抑えるため数フレームおきにする）
    static func savedDetections(from detections: [Detection], in image: CGImage, readsNumbers: Bool) -> [SavedDetection] {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard width > 0, height > 0 else { return [] }

        let pixels = PixelImage(image: image)
        let field = pixels?.fieldColor()

        var saved = detections.map { detection -> SavedDetection in
            let box = detection.boundingBox
            let normalized = CGRect(x: box.minX / width, y: box.minY / height, width: box.width / width, height: box.height / height)
            var result = SavedDetection(label: detection.label, confidence: detection.confidence, boundingBox: normalized)
            guard detection.label != SportsClass.ball.rawValue else { return result }

            if let pixels, let field {
                result.inCourt = pixels.isOnField(normalized, fieldColor: field)
            }
            if !result.isExcluded {
                result.jerseyPalette = pixels?.jerseyPalette(of: normalized, excluding: field)
            }
            return result
        }

        if readsNumbers {
            readJerseyNumbers(in: image, detections: &saved)
        }
        return saved
    }

    // MARK: - Camera

    /// 直前のフレームからのカメラの動き（正規化座標）。画面が切り替わった・求められない場合は nil
    ///
    /// 戻り値を今のフレームの画面上の位置に足すと、直前のフレームの画面上の位置になる。
    static func cameraShift(from previous: CGImage, to current: CGImage) -> CGPoint? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: current, options: [:])
        let handler = VNImageRequestHandler(cgImage: previous, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first, previous.width > 0, previous.height > 0 else { return nil }
        let transform = observation.alignmentTransform
        // Vision は左下原点なので、上下を反転して左上原点の正規化座標にする
        let shift = CGPoint(x: transform.tx / CGFloat(previous.width), y: -transform.ty / CGFloat(previous.height))
        guard hypot(Double(shift.x), Double(shift.y)) <= sceneCutShift else { return nil }
        return shift
    }

    // MARK: - Jersey numbers

    /// 大きく写っている選手の背中の番号を読み取る
    private static func readJerseyNumbers(in image: CGImage, detections: inout [SavedDetection]) {
        let imageHeight = CGFloat(image.height)
        let candidates = detections.indices
            .filter { index in
                let detection = detections[index]
                guard detection.label == SportsClass.player.rawValue, !detection.isExcluded else { return false }
                return detection.boundingBox.height * imageHeight >= minimumHeightForNumber
            }
            .sorted { detections[$0].boundingBox.height > detections[$1].boundingBox.height }
            .prefix(maxNumberReadsPerFrame)

        for index in candidates {
            guard let crop = numberRegion(of: detections[index].boundingBox, in: image) else { continue }
            detections[index].jerseyNumber = recognizeNumber(in: crop)
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
    private static func recognizeNumber(in image: CGImage) -> Int? {
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
                return number
            }
        }
        return nil
    }
}
