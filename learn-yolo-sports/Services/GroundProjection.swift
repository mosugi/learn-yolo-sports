//
//  GroundProjection.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/12.
//

import Foundation
import CoreGraphics

/// 画面上の点とピッチの地面上の点を行き来する（地面に貼り付いたように描くため）
///
/// 横向きに置いたカメラ（傾きは下向きのみ、横の傾きはなし）を仮定し、写っている選手の大きさから
/// カメラの見下ろす角度と高さを推定する。地面に立つ選手の枠の高さ h は、足元の画面上の高さ v と
/// 地平線の高さ v₀ を使って h = β (v − v₀) と直線で表せるので、これを当てはめて v₀ と β を求める。
///
/// 地面の座標は選手の身長を 1 とした単位で、X はカメラから見て右、Y はカメラから遠ざかる向き。
/// 画面上の座標は正規化座標（0〜1、左上原点）で受け渡す。
nonisolated struct GroundProjection {
    /// 横の画角（度）。スマートフォンの標準のレンズに近い値を仮定する
    static let horizontalFieldOfView = 60.0

    private let aspect: Double
    /// 焦点距離（画面の高さを 1 とした単位）
    private let focal: Double
    /// 見下ろす角度（ラジアン）
    private let tilt: Double
    /// カメラの高さ（選手の身長を 1 とした単位）
    private let height: Double

    init?(detections: [SavedDetection], aspectRatio: Double) {
        aspect = aspectRatio > 0 ? aspectRatio : 16.0 / 9.0
        focal = 0.5 * aspect / tan(Self.horizontalFieldOfView / 2 * .pi / 180)

        // 画面の下端で切れている枠は高さが小さく出るので使わない
        let people = detections.filter { detection in
            !detection.isExcluded
                && detection.label != SportsClass.ball.rawValue
                && detection.boundingBox.height > 0.01
                && detection.boundingBox.maxY < 0.99
        }
        guard people.count >= 3 else { return nil }
        var samples = people.map { (v: Double($0.footPoint.y), h: Double($0.boundingBox.height)) }

        func fit(_ samples: [(v: Double, h: Double)]) -> (slope: Double, intercept: Double)? {
            let n = Double(samples.count)
            let meanV = samples.map(\.v).reduce(0, +) / n
            let meanH = samples.map(\.h).reduce(0, +) / n
            let variance = samples.reduce(0) { $0 + ($1.v - meanV) * ($1.v - meanV) }
            guard variance > 1e-5 else { return nil }
            let covariance = samples.reduce(0) { $0 + ($1.v - meanV) * ($1.h - meanH) }
            let slope = covariance / variance
            return (slope, meanH - slope * meanV)
        }

        // 当てはめから大きく外れた枠（しゃがんだ選手・重なった枠）を一度だけ除いてやり直す
        if samples.count >= 5, let first = fit(samples) {
            let residuals = samples.map { abs($0.h - (first.intercept + first.slope * $0.v)) }
            let sorted = residuals.sorted()
            let limit = max(0.01, sorted[sorted.count / 2] * 3)
            let kept = zip(samples, residuals).filter { $0.1 <= limit }.map { $0.0 }
            if kept.count >= 3 { samples = kept }
        }

        let minFoot = samples.map(\.v).min() ?? 0
        var horizon: Double
        var slope: Double
        if let line = fit(samples), line.slope > 0.02, -line.intercept / line.slope < minFoot - 0.02 {
            slope = line.slope
            horizon = -line.intercept / line.slope
        } else {
            // 奥行きの差が小さく当てはめられないときは、地平線を画面の上の外に置いて大きさの比だけ合わせる
            horizon = min(-0.2, minFoot - 0.3)
            let ratios = samples.map { $0.h / max(0.05, $0.v - horizon) }.sorted()
            slope = ratios[ratios.count / 2]
        }
        // 地平線が画面の下寄りすぎる・上すぎるときは、ありえる範囲に収める
        horizon = min(max(horizon, -1.5), 0.45)
        let angle = atan((0.5 - horizon) / focal)
        tilt = min(max(angle, 3 * .pi / 180), 70 * .pi / 180)
        height = cos(tilt) * cos(tilt) / max(slope, 1e-3)
        guard height.isFinite, height > 0 else { return nil }
    }

    /// 画面上の点（正規化座標）を地面上の点にする。地平線より上の点は nil
    func ground(_ point: CGPoint) -> CGPoint? {
        let u = Double(point.x) * aspect - aspect / 2
        let v = Double(point.y) - 0.5
        // 画面の点を通る光線の向き（X: 右、Y: 奥、Z: 上）
        let dx = u / focal
        let dy = cos(tilt) - sin(tilt) * v / focal
        let dz = -sin(tilt) - cos(tilt) * v / focal
        guard dz < -1e-4 else { return nil }
        let t = height / -dz
        return CGPoint(x: dx * t, y: dy * t)
    }

    /// 地面上の点を画面上の点（正規化座標）にする。カメラより手前の点は nil
    func screen(_ point: CGPoint) -> CGPoint? {
        let x = Double(point.x), y = Double(point.y)
        let depth = cos(tilt) * y + sin(tilt) * height
        guard depth > 1e-3 else { return nil }
        let down = -sin(tilt) * y + cos(tilt) * height
        let u = aspect / 2 + focal * x / depth
        let v = 0.5 + focal * down / depth
        return CGPoint(x: u / aspect, y: v)
    }

    /// 地面上の点に立つ選手の、画面上の身長（画面の高さを 1 とした単位）
    func personHeight(atGround point: CGPoint) -> Double? {
        let depth = cos(tilt) * Double(point.y) + sin(tilt) * height
        guard depth > 1e-3 else { return nil }
        return focal * cos(tilt) / depth
    }

    /// 地面上の長さ（身長単位）をメートルの目安にする
    static func meters(_ length: Double) -> Double {
        length * PlayerMetrics.assumedHeight
    }

    /// メートルを地面上の長さ（身長単位）にする
    static func units(meters: Double) -> Double {
        meters / PlayerMetrics.assumedHeight
    }

    /// 地面上の 2 点の距離（身長単位）
    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(Double(a.x - b.x), Double(a.y - b.y))
    }
}
