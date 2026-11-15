//
//  TacticalPlanner.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/10.
//

import Foundation
import CoreGraphics

/// シーンの注目時点で、ボール保持者が取れる選択肢（パス・ドリブル）を幾何的に挙げる
///
/// 画面上の位置だけを使う簡易的な評価で、ピッチ上の絶対位置や攻撃方向は分からない。
/// 距離は画面の高さを 1 とした単位で測る（横長の画面で縦横の縮尺をそろえるため）。
nonisolated enum TacticalPlanner {

    /// ボール保持者とみなす、足元からボールまでの最大距離
    private static let maxCarrierDistance = 0.15
    /// これより近い味方へのパスは候補にしない
    private static let minPassLength = 0.06
    /// ドリブルで運ぶ距離
    private static let dribbleLength = 0.18
    /// フリー度・コースの空きの上限（これ以上離れていれば十分空いているとみなす）
    private static let clearanceCap = 0.4
    private static let maxOptions = 3

    private struct Player {
        let foot: CGPoint
        let team: Int
        /// 識別した選手の呼び名（#10、A など）
        let label: String?
    }

    /// - Parameters:
    ///   - frames: シーン内のフレーム
    ///   - aspectRatio: 画像の幅 / 高さ
    ///   - players: 識別した選手（矢印の説明に呼び名を使う）
    static func snapshot(for segment: SceneSegment, frames: [SavedFrame], aspectRatio: Double, players: [PlayerIdentity]?) -> TacticalSnapshot? {
        let aspect = aspectRatio > 0 ? aspectRatio : 16.0 / 9.0
        let labels = Dictionary((players ?? []).map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
        // 注目時点に近い、画像を保存したフレームから順に、局面が読み取れるものを探す
        let candidates = frames
            .filter { $0.imageFileName != nil }
            .sorted { abs($0.timestamp - segment.keyTime) < abs($1.timestamp - segment.keyTime) }
        for frame in candidates.prefix(5) {
            if let snapshot = snapshot(in: frame, aspect: aspect, labels: labels) {
                return snapshot
            }
        }
        return nil
    }

    private static func snapshot(in frame: SavedFrame, aspect: Double, labels: [Int: String]) -> TacticalSnapshot? {
        guard let ballDetection = frame.detections(of: .ball).max(by: { $0.confidence < $1.confidence }) else { return nil }
        let ball = scaled(ballDetection.center, aspect: aspect)

        let players: [Player] = frame.detections(of: .player).compactMap { detection in
            guard let team = detection.team else { return nil }
            let foot = CGPoint(x: detection.boundingBox.midX, y: detection.boundingBox.maxY)
            return Player(foot: scaled(foot, aspect: aspect), team: team, label: detection.playerID.flatMap { labels[$0] })
        }

        guard let carrier = players.min(by: { distance($0.foot, ball) < distance($1.foot, ball) }),
              distance(carrier.foot, ball) <= maxCarrierDistance else { return nil }

        let teammates = players.filter { $0.team == carrier.team && $0.foot != carrier.foot }
        let opponents = players.filter { $0.team != carrier.team }.map(\.foot)
        let maxX = aspect

        var options: [(kind: TacticalOptionKind, to: CGPoint, label: String?, openness: Double, lane: Double, length: Double, score: Double)] = []

        for mate in teammates {
            let length = distance(carrier.foot, mate.foot)
            guard length >= minPassLength else { continue }
            let openness = nearestDistance(from: mate.foot, to: opponents)
            let lane = laneClearance(from: carrier.foot, to: mate.foot, opponents: opponents)
            // フリーな受け手・空いたコースを重視し、遠すぎる（約画面高さ 0.35 から離れた）パスは少し減点する
            let score = openness * 1.0 + lane * 1.2 - abs(length - 0.35) * 0.5
            options.append((.pass, mate.foot, mate.label, openness, lane, length, score))
        }

        // ドリブル: 8方向のうち、運んだ先で相手から最も離れられる方向
        let dribble = (0..<8).compactMap { step -> (CGPoint, Double, Double)? in
            let angle = Double(step) * .pi / 4
            let to = CGPoint(x: carrier.foot.x + dribbleLength * cos(angle), y: carrier.foot.y + dribbleLength * sin(angle))
            guard to.x > 0.03 * maxX, to.x < 0.97 * maxX, to.y > 0.03, to.y < 0.97 else { return nil }
            let openness = nearestDistance(from: to, to: opponents)
            let lane = laneClearance(from: carrier.foot, to: to, opponents: opponents)
            return (to, openness, lane)
        }.max { min($0.1, $0.2) < min($1.1, $1.2) }

        if let (to, openness, lane) = dribble {
            // ドリブルは奪われるリスクがあるので、パスより少し低めに評価する
            let score = openness * 0.9 + lane * 1.0 - 0.05
            options.append((.dribble, to, nil, openness, lane, dribbleLength, score))
        }

        let chosen = options.sorted { $0.score > $1.score }.prefix(maxOptions)
        guard !chosen.isEmpty else { return nil }

        let carrierPoint = unscaled(carrier.foot, aspect: aspect)
        let tacticalOptions = chosen.enumerated().map { index, option in
            let to = unscaled(option.to, aspect: aspect)
            return TacticalOption(
                id: index + 1,
                kind: option.kind,
                from: carrierPoint,
                to: to,
                targetLabel: option.label,
                openness: option.openness,
                laneClearance: option.lane,
                length: option.length,
                score: option.score,
                summary: summary(
                    kind: option.kind,
                    from: carrierPoint,
                    to: to,
                    label: option.label,
                    openness: option.openness,
                    lane: option.lane
                )
            )
        }

        return TacticalSnapshot(
            frameNumber: frame.frameNumber,
            timestamp: frame.timestamp,
            attackingTeam: carrier.team,
            carrierLabel: carrier.label,
            carrier: carrierPoint,
            ball: ballDetection.center,
            options: tacticalOptions
        )
    }

    // MARK: - Geometry

    /// 正規化座標を、画面の高さ=1 の座標に変換する
    private static func scaled(_ point: CGPoint, aspect: Double) -> CGPoint {
        CGPoint(x: point.x * aspect, y: point.y)
    }

    private static func unscaled(_ point: CGPoint, aspect: Double) -> CGPoint {
        CGPoint(x: point.x / aspect, y: point.y)
    }

    private static func distance(_ p: CGPoint, _ q: CGPoint) -> Double {
        Double(hypot(p.x - q.x, p.y - q.y))
    }

    private static func nearestDistance(from point: CGPoint, to others: [CGPoint]) -> Double {
        min(clearanceCap, others.map { distance(point, $0) }.min() ?? clearanceCap)
    }

    /// 始点から終点への線分に、相手が最も近づく距離（始点のすぐ近くの相手は除く）
    private static func laneClearance(from start: CGPoint, to end: CGPoint, opponents: [CGPoint]) -> Double {
        let dx = end.x - start.x, dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return clearanceCap }

        var nearest = clearanceCap
        for opponent in opponents {
            let t = ((opponent.x - start.x) * dx + (opponent.y - start.y) * dy) / lengthSquared
            guard t > 0.1, t < 1.05 else { continue }
            let projection = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
            nearest = min(nearest, distance(opponent, projection))
        }
        return nearest
    }

    // MARK: - Text

    private static func summary(kind: TacticalOptionKind, from: CGPoint, to: CGPoint, label: String?, openness: Double, lane: Double) -> String {
        let direction = directionName(dx: Double(to.x - from.x), dy: Double(to.y - from.y))
        let opennessText = openness >= 0.2 ? "フリー" : (openness >= 0.1 ? "やや余裕あり" : "マークあり")
        let laneText = lane >= 0.12 ? "コース空き" : (lane >= 0.05 ? "コースやや狭い" : "コースに相手")

        switch kind {
        case .pass:
            let target = label.map { "\(direction)の\($0)" } ?? "\(direction)の味方"
            return "\(target)へパス（\(opennessText)・\(laneText)）"
        case .dribble:
            return "\(direction)へ運ぶドリブル（\(opennessText)のスペース）"
        }
    }

    /// 画面上の向きを「右奥」「左手前」のような言葉にする（奥=画面上方向）
    private static func directionName(dx: Double, dy: Double) -> String {
        let horizontal = abs(dx) < 0.03 ? "" : (dx > 0 ? "右" : "左")
        let vertical = abs(dy) < 0.03 ? "" : (dy < 0 ? "奥" : "手前")
        // 横方向が明らかに大きい場合は縦を省く（逆も同様）
        if abs(dx) > abs(dy) * 2.5 { return horizontal.isEmpty ? "正面" : horizontal }
        if abs(dy) > abs(dx) * 2.5 { return vertical.isEmpty ? "正面" : vertical }
        let combined = horizontal + vertical
        return combined.isEmpty ? "正面" : combined
    }
}
