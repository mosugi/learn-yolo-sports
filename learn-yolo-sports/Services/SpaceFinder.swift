//
//  SpaceFinder.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/12.
//

import Foundation
import CoreGraphics

/// ボール周辺の、相手がいない空いた場所
nonisolated struct OpenSpace: Hashable {
    /// 中心（正規化座標、左上原点）
    let center: CGPoint
    /// 半径（画面の高さを 1 とした単位）
    let radius: Double
}

/// ボール保持チームから見て、ボール周辺で相手がいない場所を探す
///
/// 画面上の位置だけを使う簡易的な目安で、攻撃方向やピッチの外は考慮しない
/// （選手の足元が写っている範囲の外は候補にしない）。
nonisolated enum SpaceFinder {
    /// ボールからこの距離までを探す（画面の高さを 1 とした単位）
    private static let searchRadius = 0.45
    /// 候補の間隔
    private static let gridStep = 0.03
    /// ボール保持者とみなす、足元からボールまでの最大距離
    private static let maxCarrierDistance = 0.2
    /// スペースとみなす、最も近い相手までの最小距離
    private static let minimumOpenness = 0.1
    /// 表示する円の半径の上限
    private static let maxRadius = 0.12
    private static let maxSpaces = 3

    static func spaces(in frame: SavedFrame, aspectRatio: Double) -> [OpenSpace] {
        let aspect = aspectRatio > 0 ? aspectRatio : 16.0 / 9.0
        func scaled(_ point: CGPoint) -> CGPoint { CGPoint(x: Double(point.x) * aspect, y: Double(point.y)) }
        func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(Double(a.x - b.x), Double(a.y - b.y)) }

        guard let ballDetection = frame.detections(of: .ball).max(by: { $0.confidence < $1.confidence }) else { return [] }
        let ball = scaled(ballDetection.center)

        let players: [(foot: CGPoint, team: Int)] = frame.detections(of: .player).compactMap { detection in
            detection.team.map { (scaled(detection.footPoint), $0) }
        }
        guard let carrier = players.min(by: { distance($0.foot, ball) < distance($1.foot, ball) }),
              distance(carrier.foot, ball) <= maxCarrierDistance else { return [] }
        let opponents = players.filter { $0.team != carrier.team }.map(\.foot)
        guard !opponents.isEmpty else { return [] }

        // 選手の足元が写っている奥行きの範囲（ピッチの外を候補にしないため）
        let ys = players.map { Double($0.foot.y) }
        let minY = max(0, (ys.min() ?? 0) - 0.05)
        let maxY = min(1, (ys.max() ?? 1) + 0.05)

        var candidates: [(point: CGPoint, openness: Double, score: Double)] = []
        var y = Double(ball.y) - searchRadius
        while y <= Double(ball.y) + searchRadius {
            var x = Double(ball.x) - searchRadius
            while x <= Double(ball.x) + searchRadius {
                defer { x += gridStep }
                let point = CGPoint(x: x, y: y)
                let fromBall = distance(point, ball)
                guard y >= minY, y <= maxY, x >= 0, x <= aspect,
                      fromBall <= searchRadius, fromBall >= 0.06 else { continue }
                let openness = opponents.map { distance($0, point) }.min() ?? 0
                guard openness >= minimumOpenness else { continue }
                // 広さを重視しつつ、ボールから遠すぎる場所は下げる
                let score = min(openness, 0.25) - 0.25 * fromBall
                candidates.append((point, openness, score))
            }
            y += gridStep
        }
        candidates.sort { $0.score > $1.score }

        var chosen: [OpenSpace] = []
        var chosenScaled: [(center: CGPoint, radius: Double)] = []
        for candidate in candidates where chosen.count < maxSpaces {
            let radius = min(candidate.openness * 0.6, maxRadius)
            // 円が重なる候補は除く
            guard !chosenScaled.contains(where: { distance($0.center, candidate.point) < $0.radius + radius }) else { continue }
            chosenScaled.append((candidate.point, radius))
            chosen.append(OpenSpace(center: CGPoint(x: Double(candidate.point.x) / aspect, y: Double(candidate.point.y)), radius: radius))
        }
        return chosen
    }
}
