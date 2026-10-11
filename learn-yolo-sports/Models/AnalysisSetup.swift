//
//  AnalysisSetup.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation
import CoreGraphics

/// 解析前にユーザーが1回だけ指定する条件
nonisolated struct AnalysisSetup: Codable, Hashable {
    var format: MatchFormat
    /// コートの長さ（m）
    var pitchLength: Double
    /// コートの幅（m）
    var pitchWidth: Double
    /// タップで指定する基準の長方形
    var region: ReferenceRegion
    /// 画像上でタップした4点（正規化座標、左上原点。region.cornerNames の順）
    var imageCorners: [CGPoint]
    /// 自チームのユニフォームの色
    var ownColor: LabColor
    /// 自チームの色を取得した位置（正規化座標、表示用）
    var ownSamplePoint: CGPoint
    /// 自チームが画面右のゴールへ攻めるか
    var ownAttacksRight: Bool
    /// 自チームの背番号と名前（任意。背番号の読み取り結果の絞り込みと表示に使う）
    var roster: [RosterEntry]? = nil
    
    var rosterEntries: [RosterEntry] {
        roster ?? []
    }
    
    /// 背番号に対応する表示名（例: #10 田中）
    func playerName(number: Int) -> String {
        if let entry = rosterEntries.first(where: { $0.number == number }), !entry.name.isEmpty {
            return "#\(number) \(entry.name)"
        }
        return "#\(number)"
    }

    /// 対象チーム（自チーム）
    static let ownTeamName = "自チーム"
    static let opponentTeamName = "相手"

    /// 距離の目安を 11人制のコートからこのコートへ換算する係数
    var lengthScale: Double {
        pitchLength / MatchFormat.elevenASide.defaultLength
    }

    /// 自チームが攻める方向に沿った座標（自陣ゴールラインが 0）
    func attackingCoordinate(of point: CGPoint) -> Double {
        ownAttacksRight ? Double(point.x) : pitchLength - Double(point.x)
    }

    /// 指定したピッチ座標のゴールを守っているチーム
    func defendingTeam(atX x: Double) -> TeamSide {
        let isLeftHalf = x < pitchLength / 2
        // 右へ攻めるチームは左のゴールを守る
        return isLeftHalf == ownAttacksRight ? .own : .opponent
    }
}

/// 背番号と名前
nonisolated struct RosterEntry: Codable, Hashable, Identifiable {
    let number: Int
    let name: String
    
    var id: Int { number }
    
    /// 「10 田中」のような行を並べたテキストから読み込む
    static func parse(_ text: String) -> [RosterEntry] {
        var entries: [RosterEntry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "　" || $0 == "," || $0 == "、" })
            guard let first = parts.first, let number = Int(first), (0...99).contains(number),
                  !entries.contains(where: { $0.number == number }) else { continue }
            let name = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            entries.append(RosterEntry(number: number, name: name))
        }
        return entries.sorted { $0.number < $1.number }
    }
    
    /// parse(_:) で読み込めるテキストに戻す
    static func text(for entries: [RosterEntry]) -> String {
        entries.map { $0.name.isEmpty ? "\($0.number)" : "\($0.number) \($0.name)" }.joined(separator: "\n")
    }
}

/// チーム
nonisolated enum TeamSide: String, Codable, Hashable {
    case own
    case opponent

    var displayName: String {
        switch self {
        case .own: return AnalysisSetup.ownTeamName
        case .opponent: return AnalysisSetup.opponentTeamName
        }
    }

    var other: TeamSide {
        self == .own ? .opponent : .own
    }
}

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
nonisolated struct WeightedColor {
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
    private func colors(in rect: CGRect, samplesPerSide: Int) -> [LabColor]? {
        var colors: [LabColor] = []
        for i in 0..<samplesPerSide {
            for j in 0..<samplesPerSide {
                let x = Double(rect.minX) + Double(rect.width) * (Double(i) + 0.5) / Double(samplesPerSide)
                let y = Double(rect.minY) + Double(rect.height) * (Double(j) + 0.5) / Double(samplesPerSide)
                let px = min(width - 1, max(0, Int(x * Double(width))))
                let py = min(height - 1, max(0, Int(y * Double(height))))
                let offset = (py * width + px) * 4
                let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])

                // 緑が目立って強い画素は芝とみなして除く
                if g > r + 12 && g > b + 12 { continue }
                colors.append(LabColor(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255))
            }
        }
        guard colors.count >= max(3, samplesPerSide * samplesPerSide / 5) else { return nil }
        return colors
    }

    /// 選手のバウンディングボックス（正規化座標）から、ユニフォームの胴体部分の色を最大3色にまとめて求める
    ///
    /// 平均色にすると、遠くの小さな選手では背景（フェンス・ネット・ライン）や肌の色が混ざって
    /// 別のチームの色に寄ってしまうため、色ごとの割合で残す。
    func jerseyPalette(of box: CGRect) -> [WeightedColor]? {
        let torso = CGRect(
            x: box.minX + box.width * 0.25,
            y: box.minY + box.height * 0.15,
            width: box.width * 0.5,
            height: box.height * 0.35
        )
        guard let colors = colors(in: torso, samplesPerSide: 10) else { return nil }
        let palette = WeightedColor.palette(of: colors)
        return palette.isEmpty ? nil : palette
    }
}
