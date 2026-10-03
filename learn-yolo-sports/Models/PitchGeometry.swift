//
//  PitchGeometry.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation
import CoreGraphics

/// 試合形式
nonisolated enum MatchFormat: String, Codable, CaseIterable, Identifiable {
    case elevenASide
    case eightASide
    case futsal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .elevenASide: return "11人制"
        case .eightASide: return "8人制"
        case .futsal: return "フットサル"
        }
    }

    /// 標準的なコートの長さ（m）
    var defaultLength: Double {
        switch self {
        case .elevenASide: return 105
        case .eightASide: return 68
        case .futsal: return 40
        }
    }

    /// 標準的なコートの幅（m）
    var defaultWidth: Double {
        switch self {
        case .elevenASide: return 68
        case .eightASide: return 50
        case .futsal: return 20
        }
    }

    /// チームの形を評価するのに必要な、検出できたフィールドプレーヤーの最小人数
    var minimumFieldPlayers: Int {
        switch self {
        case .elevenASide: return 7
        case .eightASide: return 5
        case .futsal: return 3
        }
    }
}

/// コーナーをタップして指定する基準の長方形
nonisolated enum ReferenceRegion: String, Codable, CaseIterable, Identifiable {
    case fullPitch
    case leftHalf
    case rightHalf

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fullPitch: return "コート全体"
        case .leftHalf: return "左半分"
        case .rightHalf: return "右半分"
        }
    }

    /// タップする4点の名前（画面上の左奥、右奥、右手前、左手前の順）
    var cornerNames: [String] {
        switch self {
        case .fullPitch: return ["左奥の角", "右奥の角", "右手前の角", "左手前の角"]
        case .leftHalf: return ["左奥の角", "中央線の奥の端", "中央線の手前の端", "左手前の角"]
        case .rightHalf: return ["中央線の奥の端", "右奥の角", "右手前の角", "中央線の手前の端"]
        }
    }

    /// 4点に対応するピッチ座標（m）
    ///
    /// ピッチ座標は x がコートの長さ方向（画面左のゴールラインが 0）、y が幅方向（奥のタッチラインが 0）。
    func pitchCorners(length: Double, width: Double) -> [CGPoint] {
        var x0 = 0.0
        var x1 = length
        switch self {
        case .fullPitch: break
        case .leftHalf: x1 = length / 2
        case .rightHalf: x0 = length / 2
        }
        return [
            CGPoint(x: x0, y: 0),
            CGPoint(x: x1, y: 0),
            CGPoint(x: x1, y: width),
            CGPoint(x: x0, y: width),
        ]
    }
}

/// 平面射影変換（3x3 行列、行優先）
nonisolated struct Homography: Codable, Hashable {
    let m: [Double]

    init(m: [Double]) {
        self.m = m
    }

    /// 4点の対応 src[i] → dst[i] から求める。点が一直線に並ぶなど解けない場合は nil
    init?(from src: [CGPoint], to dst: [CGPoint]) {
        guard src.count == 4, dst.count == 4 else { return nil }

        var rows: [[Double]] = []
        for i in 0..<4 {
            let x = Double(src[i].x), y = Double(src[i].y)
            let u = Double(dst[i].x), v = Double(dst[i].y)
            rows.append([x, y, 1, 0, 0, 0, -u * x, -u * y, u])
            rows.append([0, 0, 0, x, y, 1, -v * x, -v * y, v])
        }
        guard let h = Self.solveLinearSystem(rows) else { return nil }

        var m = h + [1]
        // 基準点で w > 0 になるように符号をそろえる（カメラの後ろ側に写る点を判別するため）
        let x = Double(src[0].x), y = Double(src[0].y)
        if m[6] * x + m[7] * y + m[8] < 0 {
            m = m.map { -$0 }
        }
        self.m = m

        // 4点すべてが同じ側に写らない（タップ順が交差している等）場合は無効
        for point in src where apply(point) == nil {
            return nil
        }
    }

    /// 点を変換する。地平線の向こう側など変換できない点は nil
    func apply(_ point: CGPoint) -> CGPoint? {
        let x = Double(point.x), y = Double(point.y)
        let w = m[6] * x + m[7] * y + m[8]
        guard w > 1e-9 else { return nil }
        return CGPoint(
            x: (m[0] * x + m[1] * y + m[2]) / w,
            y: (m[3] * x + m[4] * y + m[5]) / w
        )
    }

    /// 逆変換
    var inverse: Homography? {
        let a = m[0], b = m[1], c = m[2]
        let d = m[3], e = m[4], f = m[5]
        let g = m[6], h = m[7], i = m[8]

        let c00 = e * i - f * h
        let c01 = -(d * i - f * g)
        let c02 = d * h - e * g
        let det = a * c00 + b * c01 + c * c02
        guard abs(det) > 1e-12 else { return nil }

        let adjugate = [
            c00, -(b * i - c * h), b * f - c * e,
            c01, a * i - c * g, -(a * f - c * d),
            c02, -(a * h - b * g), a * e - b * d,
        ]
        // 正のスカラー倍は同じ変換なので、符号だけ合わせる（w > 0 の判定を保つ）
        let sign: Double = det > 0 ? 1 : -1
        return Homography(m: adjugate.map { $0 * sign })
    }

    /// 拡大係数行列（n 行 n+1 列）をガウスの消去法で解く
    private static func solveLinearSystem(_ rows: [[Double]]) -> [Double]? {
        var a = rows
        let n = a.count
        for col in 0..<n {
            var pivot = col
            for row in (col + 1)..<n where abs(a[row][col]) > abs(a[pivot][col]) {
                pivot = row
            }
            guard abs(a[pivot][col]) > 1e-12 else { return nil }
            a.swapAt(col, pivot)

            for row in 0..<n where row != col {
                let factor = a[row][col] / a[col][col]
                guard factor != 0 else { continue }
                for k in col...n {
                    a[row][k] -= factor * a[col][k]
                }
            }
        }
        return (0..<n).map { a[$0][n] / a[$0][$0] }
    }
}

/// 画像座標とピッチ座標の対応
///
/// 画像座標は正規化座標（0〜1、左上原点）、ピッチ座標はメートル。
nonisolated struct CourtGeometry {
    let length: Double
    let width: Double
    /// コート外とみなすまでの余裕（m）。スローインやライン際のプレーを含めるため
    let margin: Double
    let imageToPitch: Homography
    let pitchToImage: Homography

    init?(setup: AnalysisSetup, margin: Double = 2) {
        let pitchCorners = setup.region.pitchCorners(length: setup.pitchLength, width: setup.pitchWidth)
        guard let forward = Homography(from: setup.imageCorners, to: pitchCorners),
              let backward = forward.inverse else { return nil }
        self.length = setup.pitchLength
        self.width = setup.pitchWidth
        self.margin = margin
        self.imageToPitch = forward
        self.pitchToImage = backward
    }

    func pitchPoint(fromImage point: CGPoint) -> CGPoint? {
        imageToPitch.apply(point)
    }

    func imagePoint(fromPitch point: CGPoint) -> CGPoint? {
        pitchToImage.apply(point)
    }

    /// ピッチ座標がコート内（余裕を含む）か
    func contains(_ point: CGPoint) -> Bool {
        Double(point.x) >= -margin && Double(point.x) <= length + margin
            && Double(point.y) >= -margin && Double(point.y) <= width + margin
    }

    /// 検出の足元（バウンディングボックスの下端中央）
    static func footPoint(of box: CGRect) -> CGPoint {
        CGPoint(x: box.midX, y: box.maxY)
    }

    /// 検出範囲を絞り込む画像上の矩形（正規化座標）。コート全体が収まらない場合などは nil
    ///
    /// 選手の頭は足元より上に写るため、上側に余裕を持たせる。
    func detectionRegion() -> CGRect? {
        let corners = [
            CGPoint(x: -margin, y: -margin),
            CGPoint(x: length + margin, y: -margin),
            CGPoint(x: length + margin, y: width + margin),
            CGPoint(x: -margin, y: width + margin),
        ]
        let projected = corners.compactMap(imagePoint(fromPitch:))
        guard projected.count == corners.count else { return nil }

        let minX = projected.map(\.x).min()!, maxX = projected.map(\.x).max()!
        let minY = projected.map(\.y).min()!, maxY = projected.map(\.y).max()!
        let rect = CGRect(x: minX - 0.03, y: minY - 0.12, width: maxX - minX + 0.06, height: maxY - minY + 0.15)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

        // ほぼ全体なら絞り込む意味がない
        guard !rect.isNull, rect.width * rect.height < 0.85 else { return nil }
        return rect
    }

    /// 足元の位置から見て、人として妥当な大きさに写っているか
    ///
    /// 奥にある別のコートの選手は、足元が隠れて手前に見えても、写る大きさが小さいため除外できる。
    /// - Parameter imageSize: 元画像のピクセルサイズ（縦横比の補正に使う）
    func hasPlausibleHeight(_ box: CGRect, imageSize: CGSize) -> Bool {
        // 足元が画面下端で切れている場合は判定しない
        guard box.maxY < 0.98 else { return true }
        guard let foot = pitchPoint(fromImage: Self.footPoint(of: box)) else { return false }

        // 足元付近で 1m がピクセルでどれだけの長さに写るか（短縮の少ない方向を採用）
        func pixelLength(_ dx: Double, _ dy: Double) -> Double? {
            guard let a = imagePoint(fromPitch: CGPoint(x: Double(foot.x) - dx / 2, y: Double(foot.y) - dy / 2)),
                  let b = imagePoint(fromPitch: CGPoint(x: Double(foot.x) + dx / 2, y: Double(foot.y) + dy / 2)) else { return nil }
            return hypot(Double(b.x - a.x) * Double(imageSize.width), Double(b.y - a.y) * Double(imageSize.height))
        }
        guard let pixelsPerMeter = [pixelLength(1, 0), pixelLength(0, 1)].compactMap({ $0 }).max(),
              pixelsPerMeter > 0 else { return true }

        let heightInMeters = Double(box.height) * Double(imageSize.height) / pixelsPerMeter
        // 子どもやかがんだ姿勢も考慮して下限を低めにとる
        return heightInMeters >= 0.6 && heightInMeters <= 4.0
    }
    
    /// 画像に重ねるコートのライン（外周と中央線、正規化座標の線分）
    func imageLineSegments() -> [(CGPoint, CGPoint)] {
        let segments: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 0, y: 0), CGPoint(x: length, y: 0)),
            (CGPoint(x: length, y: 0), CGPoint(x: length, y: width)),
            (CGPoint(x: length, y: width), CGPoint(x: 0, y: width)),
            (CGPoint(x: 0, y: width), CGPoint(x: 0, y: 0)),
            (CGPoint(x: length / 2, y: 0), CGPoint(x: length / 2, y: width)),
        ]
        return segments.compactMap { start, end in
            guard let a = imagePoint(fromPitch: start), let b = imagePoint(fromPitch: end) else { return nil }
            return (a, b)
        }
    }
}
