//
//  FieldLineDetector.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/12.
//

import Foundation
import CoreGraphics

/// 画面上のコートの白線（線分、正規化座標・左上原点）
nonisolated struct FieldLine: Codable, Hashable {
    let start: CGPoint
    let end: CGPoint
}

/// 保存した画像からコートの白線（直線部分）を見つける
///
/// 芝の上にある白い画素を集め、ハフ変換で直線を求めてから、実際に白い画素が続いている区間を線分にする。
/// 選手（白いユニフォーム）やボールの枠の中は除く。センターサークルなどの曲線は扱わない。
nonisolated enum FieldLineDetector {
    /// 処理する画像の幅（ピクセル）
    static let workingWidth = 320
    /// 白い画素の周り（この距離）に芝があることを求める
    private static let grassNeighborDistance = 3
    /// 角度の刻み（度）
    private static let angleSteps = 180
    /// 1 枚から求める線の最大数
    private static let maxLines = 14
    /// 線分の最小の長さ（画像の幅に対する割合）
    private static let minimumLengthRatio = 0.12
    /// 線分の途切れを許す長さ（ピクセル）
    private static let maxGap = 12

    /// コートの外枠（タッチラインとゴールライン）を求める
    ///
    /// コートは横長の長方形で、カメラが左右に振れて写る範囲が変わるだけ、という前提で、
    /// 見つけた直線のうち外枠になるものだけを選び、画面の端まで延ばして交点で切る。
    /// - Parameters:
    ///   - excluding: 除く範囲（選手・ボールの枠、正規化座標）
    ///   - feet: 選手の足元（正規化座標）。外枠の内側にいるはずなので、どの線が外枠かを決めるのに使う
    static func boundary(in image: CGImage, excluding boxes: [CGRect], feet: [CGPoint]) -> [FieldLine] {
        let aspect = Double(image.width) / Double(max(1, image.height))
        return FieldBoundary.select(from: lines(in: image, excluding: boxes), feet: feet, aspect: aspect)
    }

    /// 白線を求める
    /// - Parameter excluding: 除く範囲（選手・ボールの枠、正規化座標）
    static func lines(in image: CGImage, excluding boxes: [CGRect]) -> [FieldLine] {
        guard image.width > 0, image.height > 0 else { return [] }
        let width = workingWidth
        let height = max(1, Int((Double(image.height) / Double(image.width) * Double(width)).rounded()))
        guard let pixels = rgba(of: image, width: width, height: height) else { return [] }

        func color(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
            let offset = (y * width + x) * 4
            return (Double(pixels[offset]) / 255, Double(pixels[offset + 1]) / 255, Double(pixels[offset + 2]) / 255)
        }
        func isGrass(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            let c = color(x, y)
            return c.g > c.r + 0.03 && c.g > c.b + 0.03
        }

        // 芝の明るさを基準に、それより十分明るく彩度の低い画素を白とみなす
        var grassLuminance = 0.0, grassCount = 0
        for y in stride(from: height / 4, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) where isGrass(x, y) {
                let c = color(x, y)
                grassLuminance += 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
                grassCount += 1
            }
        }
        guard grassCount > width * height / 40 else { return [] }
        grassLuminance /= Double(grassCount)

        let excluded = boxes.map { box in
            // 枠の少し外側も影や輪郭の白さが出るため広げる
            box.insetBy(dx: -box.width * 0.15, dy: -box.height * 0.1)
        }
        var mask = [Bool](repeating: false, count: width * height)
        var points: [(x: Int, y: Int)] = []
        let d = grassNeighborDistance
        for y in 0..<height {
            for x in 0..<width {
                let c = color(x, y)
                let luminance = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
                let saturation = max(c.r, c.g, c.b) - min(c.r, c.g, c.b)
                guard luminance > grassLuminance + 0.18, saturation < 0.2 else { continue }
                guard isGrass(x - d, y) || isGrass(x + d, y) || isGrass(x, y - d) || isGrass(x, y + d) else { continue }
                let normalized = CGPoint(x: (Double(x) + 0.5) / Double(width), y: (Double(y) + 0.5) / Double(height))
                guard !excluded.contains(where: { $0.contains(normalized) }) else { continue }
                mask[y * width + x] = true
                points.append((x, y))
            }
        }
        guard points.count >= 20 else { return [] }

        // ハフ変換（rho = x cosθ + y sinθ）
        let diagonal = Int(Double(width * width + height * height).squareRoot()) + 1
        let rhoCount = diagonal * 2 + 1
        var cosines = [Double](repeating: 0, count: angleSteps)
        var sines = [Double](repeating: 0, count: angleSteps)
        for step in 0..<angleSteps {
            let theta = Double(step) * Double.pi / Double(angleSteps)
            cosines[step] = cos(theta)
            sines[step] = sin(theta)
        }
        var accumulator = [Int32](repeating: 0, count: angleSteps * rhoCount)
        for point in points {
            for step in 0..<angleSteps {
                let rho = Int((Double(point.x) * cosines[step] + Double(point.y) * sines[step]).rounded()) + diagonal
                accumulator[step * rhoCount + rho] += 1
            }
        }

        let minimumLength = Double(width) * minimumLengthRatio
        let threshold = Int32(max(20, minimumLength * 0.8))
        var peaks: [(step: Int, rho: Int, votes: Int32)] = []
        for step in 0..<angleSteps {
            for rho in 0..<rhoCount where accumulator[step * rhoCount + rho] >= threshold {
                peaks.append((step, rho, accumulator[step * rhoCount + rho]))
            }
        }
        peaks.sort { $0.votes > $1.votes }

        var result: [FieldLine] = []
        var chosen: [(step: Int, rho: Int)] = []
        for peak in peaks where result.count < maxLines {
            // 近い角度・位置の線（同じ白線の太さの分）はまとめる
            let duplicate = chosen.contains { other in
                let angle = min(abs(other.step - peak.step), angleSteps - abs(other.step - peak.step))
                return angle <= 4 && abs(other.rho - peak.rho) <= 5
            }
            guard !duplicate else { continue }
            chosen.append((peak.step, peak.rho))

            if let segment = longestSegment(
                rho: Double(peak.rho - diagonal), cosine: cosines[peak.step], sine: sines[peak.step],
                mask: mask, width: width, height: height
            ), segment.length >= minimumLength {
                result.append(FieldLine(
                    start: CGPoint(x: segment.start.x / Double(width), y: segment.start.y / Double(height)),
                    end: CGPoint(x: segment.end.x / Double(width), y: segment.end.y / Double(height))
                ))
            }
        }
        return result
    }

    /// 直線に沿って白い画素が続いている最も長い区間
    private static func longestSegment(
        rho: Double, cosine: Double, sine: Double,
        mask: [Bool], width: Int, height: Int
    ) -> (start: CGPoint, end: CGPoint, length: Double)? {
        // 直線上の点 p0 と方向 (-sinθ, cosθ)
        let p0 = CGPoint(x: rho * cosine, y: rho * sine)
        let direction = CGPoint(x: -sine, y: cosine)
        let limit = Double(width + height)

        func isWhite(near point: CGPoint) -> Bool {
            let cx = Int(point.x.rounded()), cy = Int(point.y.rounded())
            for dy in -1...1 {
                for dx in -1...1 {
                    let x = cx + dx, y = cy + dy
                    if x >= 0, x < width, y >= 0, y < height, mask[y * width + x] { return true }
                }
            }
            return false
        }

        var best: (start: Double, end: Double)?
        var runStart: Double?
        var lastHit = -Double.infinity
        var t = -limit
        while t <= limit {
            let point = CGPoint(x: p0.x + direction.x * t, y: p0.y + direction.y * t)
            let inside = point.x >= 0 && point.x < Double(width) && point.y >= 0 && point.y < Double(height)
            if inside, isWhite(near: point) {
                if runStart == nil || t - lastHit > Double(maxGap) {
                    runStart = t
                }
                lastHit = t
                if let start = runStart, best == nil || (lastHit - start) > (best!.end - best!.start) {
                    best = (start, lastHit)
                }
            }
            t += 1
        }
        guard let best else { return nil }
        let start = CGPoint(x: p0.x + direction.x * best.start, y: p0.y + direction.y * best.start)
        let end = CGPoint(x: p0.x + direction.x * best.end, y: p0.y + direction.y * best.end)
        return (start, end, best.end - best.start)
    }

    /// 指定の大きさに縮小した RGBA の画素
    private static func rgba(of image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: raw.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? buffer : nil
    }
}

/// 見つけた白線から、コートの外枠（奥と手前のタッチライン、左右のゴールライン）を選ぶ
nonisolated enum FieldBoundary {
    /// これより水平に近い線をタッチライン、急な線をゴールラインの候補にする（度）
    private static let horizontalLimit = 25.0
    /// 外枠の外側にいてよい選手の割合（線の誤差や白線上の選手の分）
    private static let outsideTolerance = 0.15
    /// 外枠を決めるのに必要な選手の数
    private static let minimumFeet = 3

    /// 無限に延ばした直線（正規化座標）
    private struct Line {
        let point: CGPoint
        let direction: CGPoint

        init(_ segment: FieldLine) {
            point = segment.start
            direction = CGPoint(x: segment.end.x - segment.start.x, y: segment.end.y - segment.start.y)
        }

        /// 水平からの角度（度）。画面の縦横比を戻して求める
        func angle(aspect: Double) -> Double {
            abs(atan2(Double(direction.y), Double(direction.x) * aspect) * 180 / .pi).truncatingRemainder(dividingBy: 180)
        }

        /// x での y（水平に近い線）
        func y(atX x: Double) -> Double {
            guard abs(direction.x) > 1e-6 else { return Double(point.y) }
            return Double(point.y) + (x - Double(point.x)) * Double(direction.y) / Double(direction.x)
        }

        /// y での x（急な線）
        func x(atY y: Double) -> Double {
            guard abs(direction.y) > 1e-6 else { return Double(point.x) }
            return Double(point.x) + (y - Double(point.y)) * Double(direction.x) / Double(direction.y)
        }

        func intersection(with other: Line) -> CGPoint? {
            let cross = Double(direction.x * other.direction.y - direction.y * other.direction.x)
            guard abs(cross) > 1e-9 else { return nil }
            let dx = Double(other.point.x - point.x), dy = Double(other.point.y - point.y)
            let t = (dx * Double(other.direction.y) - dy * Double(other.direction.x)) / cross
            return CGPoint(x: Double(point.x) + Double(direction.x) * t, y: Double(point.y) + Double(direction.y) * t)
        }
    }

    static func select(from segments: [FieldLine], feet: [CGPoint], aspect: Double) -> [FieldLine] {
        guard feet.count >= minimumFeet else { return [] }
        let lines = segments.map(Line.init)
        let horizontal = lines.filter { isHorizontal($0, aspect: aspect) }
        let steep = lines.filter { !isHorizontal($0, aspect: aspect) }
        let tolerance = Int((Double(feet.count) * outsideTolerance).rounded(.down))
        let ys = feet.map { Double($0.y) }.sorted()

        // 奥のタッチライン: ほとんどの選手より上にある線のうち、選手に最も近いもの
        // （隣のコートの線や、フェンス際の線を拾わないため）
        let topFeet = ys[min(ys.count - 1, ys.count / 10)]
        let far = horizontal
            .filter { line in feet.filter { Double($0.y) < line.y(atX: Double($0.x)) - 0.01 }.count <= tolerance }
            .min { abs(topFeet - $0.y(atX: 0.5)) < abs(topFeet - $1.y(atX: 0.5)) }

        // 手前のタッチライン: ほとんどの選手より下にある線のうち、選手に最も近いもの
        let bottomFeet = ys[max(0, ys.count - 1 - ys.count / 10)]
        let near = horizontal
            .filter { line in feet.filter { Double($0.y) > line.y(atX: Double($0.x)) + 0.01 }.count <= tolerance }
            .filter { line in far.map { abs($0.y(atX: 0.5) - line.y(atX: 0.5)) > 0.05 } ?? true }
            .min { abs(bottomFeet - $0.y(atX: 0.5)) < abs(bottomFeet - $1.y(atX: 0.5)) }

        // ゴールライン: 選手のほとんどが片側にいる急な線のうち、最も外側のもの
        // （ペナルティエリアの線も片側に選手が寄ることがあるため、外側を選ぶ）
        var left: Line?, right: Line?
        for line in steep {
            let leftCount = feet.filter { Double($0.x) < line.x(atY: Double($0.y)) }.count
            let rightCount = feet.count - leftCount
            let center = line.x(atY: 0.5)
            if leftCount <= tolerance, rightCount >= minimumFeet, left.map({ center < $0.x(atY: 0.5) }) ?? true {
                left = line
            }
            if rightCount <= tolerance, leftCount >= minimumFeet, right.map({ center > $0.x(atY: 0.5) }) ?? true {
                right = line
            }
        }

        var result: [FieldLine] = []
        let frame = CGRect(x: 0, y: 0, width: 1, height: 1)

        // タッチラインは、ゴールラインがあればそこまで、なければ画面の端まで
        for touchline in [far, near].compactMap({ $0 }) {
            var start = CGPoint(x: 0, y: touchline.y(atX: 0))
            var end = CGPoint(x: 1, y: touchline.y(atX: 1))
            if let left, let corner = touchline.intersection(with: left), corner.x > 0 { start = corner }
            if let right, let corner = touchline.intersection(with: right), corner.x < 1 { end = corner }
            if let clipped = clip(FieldLine(start: start, end: end), to: frame) { result.append(clipped) }
        }

        // ゴールラインは、タッチラインの間だけ（なければ画面の端まで）
        for goalLine in [left, right].compactMap({ $0 }) {
            var start = CGPoint(x: goalLine.x(atY: 0), y: 0)
            var end = CGPoint(x: goalLine.x(atY: 1), y: 1)
            if let far, let corner = goalLine.intersection(with: far), corner.y > 0 { start = corner }
            if let near, let corner = goalLine.intersection(with: near), corner.y < 1 { end = corner }
            if let clipped = clip(FieldLine(start: start, end: end), to: frame) { result.append(clipped) }
        }
        return result
    }

    private static func isHorizontal(_ line: Line, aspect: Double) -> Bool {
        let angle = line.angle(aspect: aspect)
        return angle < horizontalLimit || angle > 180 - horizontalLimit
    }

    /// 線分を画面の中に収める（Liang–Barsky）
    private static func clip(_ segment: FieldLine, to rect: CGRect) -> FieldLine? {
        let x0 = Double(segment.start.x), y0 = Double(segment.start.y)
        let dx = Double(segment.end.x) - x0, dy = Double(segment.end.y) - y0
        var t0 = 0.0, t1 = 1.0
        let checks: [(Double, Double)] = [
            (-dx, x0 - Double(rect.minX)), (dx, Double(rect.maxX) - x0),
            (-dy, y0 - Double(rect.minY)), (dy, Double(rect.maxY) - y0),
        ]
        for (p, q) in checks {
            if abs(p) < 1e-12 {
                if q < 0 { return nil }
            } else {
                let r = q / p
                if p < 0 { t0 = max(t0, r) } else { t1 = min(t1, r) }
            }
        }
        guard t0 < t1 else { return nil }
        return FieldLine(
            start: CGPoint(x: x0 + dx * t0, y: y0 + dy * t0),
            end: CGPoint(x: x0 + dx * t1, y: y0 + dy * t1)
        )
    }
}
