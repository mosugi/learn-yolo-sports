//
//  ColorModels.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation
import CoreGraphics

/// CIE L*a*b* 色空間の色（ユニフォームの色の比較に使う）
nonisolated struct LabColor: Codable, Hashable {
    var l: Double
    var a: Double
    var b: Double

    init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    /// sRGB（各 0〜1）から変換する
    init(red: Double, green: Double, blue: Double) {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = linear(red), g = linear(green), bl = linear(blue)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * bl) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * bl
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * bl) / 1.08883

        func f(_ t: Double) -> Double {
            t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116.0
        }
        let fx = f(x), fy = f(y), fz = f(z)
        self.l = 116 * fy - 16
        self.a = 500 * (fx - fy)
        self.b = 200 * (fy - fz)
    }

    /// 表示用の sRGB（各 0〜1）
    var rgb: (red: Double, green: Double, blue: Double) {
        let fy = (l + 16) / 116
        let fx = fy + a / 500
        let fz = fy - b / 200
        func inverse(_ f: Double) -> Double {
            let cube = f * f * f
            return cube > 0.008856 ? cube : (f - 16.0 / 116.0) / 7.787
        }
        let x = inverse(fx) * 0.95047, y = inverse(fy), z = inverse(fz) * 1.08883

        func gamma(_ c: Double) -> Double {
            let value = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
            return min(1, max(0, value))
        }
        return (
            gamma(3.2406 * x - 1.5372 * y - 0.4986 * z),
            gamma(-0.9689 * x + 1.8758 * y + 0.0415 * z),
            gamma(0.0557 * x - 0.2040 * y + 1.0570 * z)
        )
    }

    /// 色の違い。日なたと日陰の差を小さく見るため、明度の重みを下げている
    func distance(to other: LabColor) -> Double {
        let dl = (l - other.l) * 0.5
        let da = a - other.a
        let db = b - other.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    static func mean(_ colors: [LabColor]) -> LabColor? {
        guard !colors.isEmpty else { return nil }
        let n = Double(colors.count)
        return LabColor(
            l: colors.map(\.l).reduce(0, +) / n,
            a: colors.map(\.a).reduce(0, +) / n,
            b: colors.map(\.b).reduce(0, +) / n
        )
    }

    /// 彩度（a*b* 平面での原点からの距離）。白・灰・黒は小さい
    var chroma: Double {
        (a * a + b * b).squareRoot()
    }

    /// 2色の内分
    func blended(with other: LabColor, ratio: Double) -> LabColor {
        LabColor(
            l: l + (other.l - l) * ratio,
            a: a + (other.a - a) * ratio,
            b: b + (other.b - b) * ratio
        )
    }
}

/// 領域内の代表色と、その色が占める割合
nonisolated struct WeightedColor: Codable, Hashable {
    let color: LabColor
    /// 0〜1
    let weight: Double

    /// 割合で重み付けした平均色
    static func mean(_ palette: [WeightedColor]) -> LabColor? {
        let total = palette.map(\.weight).reduce(0, +)
        guard total > 0 else { return nil }
        return LabColor(
            l: palette.map { $0.color.l * $0.weight }.reduce(0, +) / total,
            a: palette.map { $0.color.a * $0.weight }.reduce(0, +) / total,
            b: palette.map { $0.color.b * $0.weight }.reduce(0, +) / total
        )
    }

    /// 色を最大 k 個にまとめる（k-means）。割合の大きい順に返す
    static func palette(of colors: [LabColor], k: Int = 3) -> [WeightedColor] {
        guard let mean = LabColor.mean(colors) else { return [] }
        // 初期値: 平均と、それまでの中心から最も遠い色
        var centers = [mean]
        while centers.count < k {
            guard let farthest = colors.max(by: { a, b in
                centers.map(a.distance(to:)).min()! < centers.map(b.distance(to:)).min()!
            }), centers.map(farthest.distance(to:)).min()! > 8 else { break }
            centers.append(farthest)
        }

        var members = [[LabColor]](repeating: [], count: centers.count)
        for _ in 0..<8 {
            members = [[LabColor]](repeating: [], count: centers.count)
            for color in colors {
                let nearest = centers.indices.min { color.distance(to: centers[$0]) < color.distance(to: centers[$1]) }!
                members[nearest].append(color)
            }
            for index in centers.indices {
                if let center = LabColor.mean(members[index]) {
                    centers[index] = center
                }
            }
        }

        let total = Double(colors.count)
        return centers.indices
            .filter { !members[$0].isEmpty }
            .map { WeightedColor(color: centers[$0], weight: Double(members[$0].count) / total) }
            .sorted { $0.weight > $1.weight }
    }
}

/// 色を読み取るための RGBA 画素データ
nonisolated struct PixelImage {
    let width: Int
    let height: Int
    private let pixels: [UInt8]

    /// 長辺を maxDimension 以下に縮小して読み込む
    init?(image: CGImage, maxDimension: Int = 960) {
        let scale = min(1, Double(maxDimension) / Double(max(image.width, image.height, 1)))
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))

        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: raw.baseAddress,
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: w * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        self.width = w
        self.height = h
        self.pixels = buffer
    }

    /// 正規化座標の矩形内にある、芝以外の画素の平均色
    func meanColor(in rect: CGRect, samplesPerSide: Int = 10) -> LabColor? {
        colors(in: rect, samplesPerSide: samplesPerSide).flatMap(LabColor.mean)
    }

    /// 正規化座標の矩形内にある、芝以外の画素の色（芝が多すぎる場合は nil）
    /// - Parameter fieldColor: コートの床の色。近い画素も芝とみなして除く（灰色がかった人工芝など）
    private func colors(in rect: CGRect, samplesPerSide: Int, excluding fieldColor: LabColor? = nil) -> [LabColor]? {
        var colors: [LabColor] = []
        for i in 0..<samplesPerSide {
            for j in 0..<samplesPerSide {
                let x = Double(rect.minX) + Double(rect.width) * (Double(i) + 0.5) / Double(samplesPerSide)
                let y = Double(rect.minY) + Double(rect.height) * (Double(j) + 0.5) / Double(samplesPerSide)
                let (r, g, b) = rgb(atX: x, y: y)

                // 緑が目立って強い画素は芝とみなして除く
                if g > r + 12.0 / 255 && g > b + 12.0 / 255 { continue }
                let color = LabColor(red: r, green: g, blue: b)
                if let fieldColor, color.distance(to: fieldColor) < 15 { continue }
                colors.append(color)
            }
        }
        guard colors.count >= max(3, samplesPerSide * samplesPerSide / 5) else { return nil }
        return colors
    }

    /// 正規化座標の1画素の sRGB（各 0〜1）
    private func rgb(atX x: Double, y: Double) -> (red: Double, green: Double, blue: Double) {
        let px = min(width - 1, max(0, Int(x * Double(width))))
        let py = min(height - 1, max(0, Int(y * Double(height))))
        let offset = (py * width + px) * 4
        return (Double(pixels[offset]) / 255, Double(pixels[offset + 1]) / 255, Double(pixels[offset + 2]) / 255)
    }

    /// 選手のバウンディングボックス（正規化座標）から、ユニフォームの胴体部分の色を最大3色にまとめて求める
    ///
    /// 平均色にすると、遠くの小さな選手では背景（フェンス・ネット・ライン）や肌の色が混ざって
    /// 別のチームの色に寄ってしまうため、色ごとの割合で残す。
    func jerseyPalette(of box: CGRect, excluding fieldColor: LabColor? = nil) -> [WeightedColor]? {
        let torso = CGRect(
            x: box.minX + box.width * 0.25,
            y: box.minY + box.height * 0.15,
            width: box.width * 0.5,
            height: box.height * 0.35
        )
        guard let colors = colors(in: torso, samplesPerSide: 10, excluding: fieldColor) else { return nil }
        let palette = WeightedColor.palette(of: colors)
        return palette.isEmpty ? nil : palette
    }
}

// MARK: - コートの判定

extension PixelImage {
    /// コートの床（芝や体育館の床）の色。画面の下 3/4 で最も広い色とみなす（はっきりしない場合は nil）
    nonisolated func fieldColor() -> LabColor? {
        var colors: [LabColor] = []
        let columns = 24, rows = 18
        for i in 0..<columns {
            for j in 0..<rows {
                let x = (Double(i) + 0.5) / Double(columns)
                let y = 0.25 + 0.75 * (Double(j) + 0.5) / Double(rows)
                colors.append(color(atX: x, y: y))
            }
        }
        guard let dominant = WeightedColor.palette(of: colors).first, dominant.weight >= 0.35 else { return nil }
        return dominant.color
    }

    /// 足元（枠の下端のすぐ下）がコートの床の色か。足元が画面外で判定できない場合は nil
    ///
    /// カメラが動くとコートの4隅は固定できないため、観客席・ベンチ・フェンスの外など、
    /// 床の色の上に立っていない人をコート外とみなす。白線の上に立つこともあるため、割合は緩めに見る。
    nonisolated func isOnField(_ box: CGRect, fieldColor: LabColor) -> Bool? {
        let top = Double(box.maxY) - Double(box.height) * 0.05
        let bottom = Double(box.maxY) + Double(box.height) * 0.12
        guard bottom <= 1 else { return nil }
        let left = Double(box.minX) - Double(box.width) * 0.25
        let right = Double(box.maxX) + Double(box.width) * 0.25

        var matches = 0, total = 0
        let columns = 8, rows = 4
        for i in 0..<columns {
            for j in 0..<rows {
                let x = left + (right - left) * (Double(i) + 0.5) / Double(columns)
                let y = top + (bottom - top) * (Double(j) + 0.5) / Double(rows)
                guard x >= 0, x <= 1 else { continue }
                total += 1
                if color(atX: x, y: y).distance(to: fieldColor) < 22 {
                    matches += 1
                }
            }
        }
        guard total >= 8 else { return nil }
        return Double(matches) / Double(total) >= 0.25
    }

    /// 正規化座標の1画素の色
    nonisolated private func color(atX x: Double, y: Double) -> LabColor {
        let value = rgb(atX: x, y: y)
        return LabColor(red: value.red, green: value.green, blue: value.blue)
    }
}

extension LabColor {
    /// 保存・表示用の RGB
    nonisolated var rgbColor: RGBColor {
        let value = rgb
        return RGBColor(red: value.red, green: value.green, blue: value.blue)
    }
}
