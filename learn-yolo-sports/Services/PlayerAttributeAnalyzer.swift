//
//  PlayerAttributeAnalyzer.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Vision
import CoreGraphics

/// 選手のユニフォーム色・背番号を検出する
///
/// 呼び出し側（ViewModel）が、処理時間を抑えるため背番号OCRは数秒おきにしか呼ばない想定。
nonisolated struct PlayerAttributeAnalyzer {

    /// 胸部分（上から15%〜45%、幅中央40%）の代表色を取る。
    /// パンツ・肌・背景が混ざらないよう範囲を絞り、芝の緑を除いた画素のチャンネルごとの中央値を使う。
    func uniformColor(in image: CGImage, boundingBox: CGRect) -> RGBColor? {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let torsoRect = CGRect(
            x: boundingBox.minX + boundingBox.width * 0.30,
            y: boundingBox.minY + boundingBox.height * 0.15,
            width: boundingBox.width * 0.40,
            height: boundingBox.height * 0.30
        ).intersection(imageBounds)

        guard torsoRect.width >= 2, torsoRect.height >= 2,
              let cropped = image.cropping(to: torsoRect) else { return nil }

        return Self.medianColor(of: cropped, excludingPitchGreen: true)
    }

    /// 背番号を Vision の文字認識(OCR)で読み取る（高さが一定以上の枠だけ対象。読めなければ nil）
    func jerseyNumber(in image: CGImage, boundingBox: CGRect, minimumHeight: CGFloat = 60) -> Int? {
        guard boundingBox.height >= minimumHeight else { return nil }

        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let cropRect = boundingBox.intersection(imageBounds)
        guard cropRect.width >= 10, cropRect.height >= 10,
              let cropped = image.cropping(to: cropRect) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cropped, options: [:])
        guard (try? handler.perform([request])) != nil, let results = request.results else { return nil }

        for observation in results {
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= 0.5,
                  let number = Int(candidate.string),
                  (1...99).contains(number) else { continue }
            return number
        }
        return nil
    }

    // MARK: - Helpers

    private static func medianColor(of image: CGImage, excludingPitchGreen: Bool) -> RGBColor? {
        let width = 24
        let height = 24
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        var reds: [Double] = [], greens: [Double] = [], blues: [Double] = []

        for i in 0..<(width * height) {
            let r = Double(buffer[i * 4]) / 255.0
            let g = Double(buffer[i * 4 + 1]) / 255.0
            let b = Double(buffer[i * 4 + 2]) / 255.0

            if excludingPitchGreen, isPitchGreen(r: r, g: g, b: b) {
                continue
            }

            reds.append(r); greens.append(g); blues.append(b)
        }

        // 芝がほとんどを占める（選手が小さすぎる）切り抜きは色が当てにならない
        guard reds.count >= 8 else { return nil }
        return RGBColor(red: median(reds), green: median(greens), blue: median(blues))
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// 芝の緑かどうかを HSV の色相・彩度から判定する
    private static func isPitchGreen(r: Double, g: Double, b: Double) -> Bool {
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let delta = maxV - minV
        guard delta > 0.0001 else { return false }

        var hue: Double
        switch maxV {
        case r: hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        case g: hue = (b - r) / delta + 2
        default: hue = (r - g) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }

        let saturation = maxV == 0 ? 0 : delta / maxV
        return hue >= 70 && hue <= 170 && saturation >= 0.25
    }
}
