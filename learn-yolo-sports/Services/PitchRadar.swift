//
//  PitchRadar.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/12.
//

import Foundation
import CoreGraphics

/// 動画全体の選手・ボールの位置を、ピッチを真上から見た位置に直したもの（レーダー表示用）と、ゴールの位置
///
/// 地面の遠近（`GroundProjection`）は動画全体の選手の大きさからまとめて推定し、カメラの左右の振り（`cameraOffset`）を
/// 向きの変化とみなして、カメラを中心にした地面上の位置（ワールド座標）にする。ピッチの長さ方向は、ゴールが 2 つ
/// 見つかればその向き、なければ選手の散らばりの主な向きとする。
///
/// ゴールは GK の位置から求める（GK はゴールの前にいることが多いため、各側の GK の最も外側の位置をゴールとみなす）。
nonisolated struct PitchRadar {
    nonisolated struct Sample {
        let time: Double
        /// レーダー上の位置（x: ピッチの長さ方向 0〜1、y: 奥 0〜手前 1）
        let point: CGPoint
    }

    nonisolated struct Track: Identifiable {
        /// PlayerIdentity.id
        let id: Int
        let team: Int?
        let label: String
        let isGoalkeeper: Bool
        let samples: [Sample]
    }

    /// 選手として識別されていない検出（追跡が短いなど）。補間はせず、そのフレームの位置だけを出す
    nonisolated struct LooseFrame {
        let time: Double
        let players: [(point: CGPoint, team: Int?)]
    }

    nonisolated struct Goal: Identifiable {
        enum Side { case left, right }
        let side: Side
        /// ワールド座標（カメラを中心にした地面上の位置、身長単位）
        let world: CGPoint
        /// レーダー上の位置
        let radar: CGPoint
        var id: Int { side == .left ? 0 : 1 }
    }

    /// 前後の位置を補間する間隔の上限（秒）と、片側にしかないときにそのまま出す時間（秒）
    private static let interpolationGap = 1.0
    private static let holdDuration = 0.5
    /// ゴールとみなすのに必要な GK の観測数
    private static let minimumGoalkeeperSamples = 4

    let tracks: [Track]
    let looseFrames: [LooseFrame]
    let ball: [Sample]
    let goals: [Goal]
    /// ゴールの幅と高さ（m）
    let goalSize: (width: Double, height: Double)

    private let projection: GroundProjection
    private let aspect: Double
    /// ピッチの長さ方向（ワールド座標の単位ベクトル）
    private let axis: CGPoint
    /// レーダーに収める範囲（長さ方向・幅方向の座標）
    private let lengthRange: ClosedRange<Double>
    private let widthRange: ClosedRange<Double>

    init?(record: SavedAnalysis) {
        let aspect = record.imageWidth > 0 && record.imageHeight > 0
            ? Double(record.imageWidth) / Double(record.imageHeight)
            : 16.0 / 9.0
        self.aspect = aspect
        let frames = record.frames.sorted { $0.timestamp < $1.timestamp }
        func people(_ frame: SavedFrame) -> [SavedDetection] {
            frame.detections(of: .player) + frame.detections(of: .goalkeeper)
        }

        // 遠近は動画全体の選手からまとめて求める（フレームごとに求めるより揺れが少ない）
        var pooled: [SavedDetection] = []
        let step = max(1, frames.count / 300)
        for index in Swift.stride(from: 0, to: frames.count, by: step) {
            pooled += people(frames[index])
        }
        guard let projection = GroundProjection(detections: pooled, aspectRatio: aspect) else { return nil }
        self.projection = projection

        // 各フレームの選手・ボールのワールド座標
        struct Observation {
            let time: Double
            let playerID: Int?
            let team: Int?
            let isGoalkeeper: Bool
            let world: CGPoint
        }
        var observations: [Observation] = []
        var balls: [(time: Double, world: CGPoint)] = []
        for frame in frames {
            for detection in people(frame) {
                guard let world = Self.world(detection.footPoint, offsetX: frame.cameraOffset?.x ?? 0, projection: projection, aspect: aspect) else { continue }
                observations.append(Observation(
                    time: frame.timestamp,
                    playerID: detection.playerID,
                    team: detection.team,
                    isGoalkeeper: detection.label == SportsClass.goalkeeper.rawValue,
                    world: world
                ))
            }
            if let ball = frame.detections(of: .ball).max(by: { $0.confidence < $1.confidence }),
               let world = Self.world(ball.footPoint, offsetX: frame.cameraOffset?.x ?? 0, projection: projection, aspect: aspect) {
                balls.append((frame.timestamp, world))
            }
        }
        let field = observations.filter { !$0.isGoalkeeper }.map(\.world)
        guard field.count >= 10 else { return nil }

        // ピッチの長さ方向: まず選手の散らばりの主な向き、ゴールが 2 つ見つかればその向き
        var axis = Self.principalAxis(of: field) ?? CGPoint(x: 1, y: 0)
        func along(_ point: CGPoint, _ axis: CGPoint) -> Double { Double(point.x * axis.x + point.y * axis.y) }
        func across(_ point: CGPoint, _ axis: CGPoint) -> Double { Double(-point.x * axis.y + point.y * axis.x) }

        let keepers = observations.filter(\.isGoalkeeper).map(\.world)
        var goalPoints = Self.goalPoints(keepers: keepers, field: field, axis: axis)
        if let left = goalPoints.left, let right = goalPoints.right {
            let dx = Double(right.x - left.x), dy = Double(right.y - left.y)
            let length = hypot(dx, dy)
            if length > 1 {
                axis = CGPoint(x: dx / length, y: dy / length)
                goalPoints = Self.goalPoints(keepers: keepers, field: field, axis: axis)
            }
        }
        self.axis = axis

        // レーダーに収める範囲（外れ値を除いた選手の範囲。ゴールがあればゴールまで）
        let lengths = field.map { along($0, axis) }.sorted()
        let widths = field.map { across($0, axis) }.sorted()
        func percentile(_ values: [Double], _ p: Double) -> Double {
            values[min(values.count - 1, max(0, Int(Double(values.count - 1) * p)))]
        }
        var minLength = percentile(lengths, 0.03), maxLength = percentile(lengths, 0.97)
        let lengthMargin = (maxLength - minLength) * 0.05
        minLength -= lengthMargin
        maxLength += lengthMargin
        if let left = goalPoints.left { minLength = along(left, axis) }
        if let right = goalPoints.right { maxLength = along(right, axis) }
        var minWidth = percentile(widths, 0.03), maxWidth = percentile(widths, 0.97)
        let widthMargin = (maxWidth - minWidth) * 0.08
        minWidth -= widthMargin
        maxWidth += widthMargin
        guard maxLength - minLength > 1, maxWidth - minWidth > 1 else { return nil }
        lengthRange = minLength...maxLength
        widthRange = minWidth...maxWidth

        func radar(_ world: CGPoint) -> CGPoint {
            CGPoint(
                x: (along(world, axis) - minLength) / (maxLength - minLength),
                // カメラから遠い側（幅方向の座標が大きい側）を上にする
                y: (maxWidth - across(world, axis)) / (maxWidth - minWidth)
            )
        }

        var goals: [Goal] = []
        if let left = goalPoints.left { goals.append(Goal(side: .left, world: left, radar: radar(left))) }
        if let right = goalPoints.right { goals.append(Goal(side: .right, world: right, radar: radar(right))) }
        self.goals = goals

        let identities = Dictionary((record.players ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let grouped = Dictionary(grouping: observations.filter { $0.playerID != nil }, by: { $0.playerID! })
        tracks = grouped.compactMap { playerID, items in
            guard let identity = identities[playerID] else { return nil }
            return Track(
                id: playerID,
                team: identity.team,
                label: identity.label,
                isGoalkeeper: identity.isGoalkeeper,
                samples: items.sorted { $0.time < $1.time }.map { Sample(time: $0.time, point: radar($0.world)) }
            )
        }
        .sorted { $0.id < $1.id }
        // 識別されていない検出も、チームの色で出す（選手として識別されていなくても写っていたことは分かるように）
        // 識別済みの選手がいないフレームでも描けるよう、フレームごとにまとめる
        let identified = Set(tracks.map(\.id))
        let loose = observations.filter { $0.playerID.map { !identified.contains($0) } ?? true }
        looseFrames = Dictionary(grouping: loose, by: \.time)
            .map { time, items in LooseFrame(time: time, players: items.map { (point: radar($0.world), team: $0.team) }) }
            .sorted { $0.time < $1.time }
        ball = balls.map { Sample(time: $0.time, point: radar($0.world)) }

        switch record.playersPerTeam ?? 11 {
        case ...5: goalSize = (3, 2)
        case 6...8: goalSize = (5, 2.15)
        default: goalSize = (7.32, 2.44)
        }
    }

    // MARK: - Query

    /// 指定時刻の位置（前後の観測を補間する。写っていなければ nil）
    static func position(in samples: [Sample], at time: Double, gap: Double = interpolationGap, hold: Double = holdDuration) -> CGPoint? {
        guard !samples.isEmpty else { return nil }
        var lower = 0, upper = samples.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if samples[mid].time < time { lower = mid + 1 } else { upper = mid }
        }
        let after = lower < samples.count ? samples[lower] : nil
        let before = lower > 0 ? samples[lower - 1] : nil
        if let before, let after, after.time - before.time <= gap, after.time > before.time {
            let t = (time - before.time) / (after.time - before.time)
            return CGPoint(
                x: Double(before.point.x) + Double(after.point.x - before.point.x) * t,
                y: Double(before.point.y) + Double(after.point.y - before.point.y) * t
            )
        }
        let nearest = [before, after].compactMap { $0 }.min { abs($0.time - time) < abs($1.time - time) }
        guard let nearest, abs(nearest.time - time) <= hold else { return nil }
        return nearest.point
    }

    /// 指定時刻に最も近い、識別されていない検出のフレーム（within 秒以内）
    func looseFrame(at time: Double, within: Double = 0.5) -> LooseFrame? {
        var lower = 0, upper = looseFrames.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if looseFrames[mid].time < time { lower = mid + 1 } else { upper = mid }
        }
        let candidates = [lower - 1, lower].filter { looseFrames.indices.contains($0) }.map { looseFrames[$0] }
        guard let nearest = candidates.min(by: { abs($0.time - time) < abs($1.time - time) }),
              abs(nearest.time - time) <= within else { return nil }
        return nearest
    }

    /// ワールド座標を、指定したフレームの画面上の位置（正規化座標）にする
    func screen(_ world: CGPoint, in frame: SavedFrame) -> CGPoint? {
        let heading = Self.heading(offsetX: frame.cameraOffset?.x ?? 0, projection: projection, aspect: aspect)
        let distance = hypot(Double(world.x), Double(world.y))
        let angle = atan2(Double(world.x), Double(world.y)) - heading
        return projection.screen(CGPoint(x: distance * sin(angle), y: distance * cos(angle)))
    }

    /// ワールド座標の地面上の点に立つ人の、画面上の身長（正規化座標の高さ）
    func personHeight(at world: CGPoint, in frame: SavedFrame) -> Double? {
        let heading = Self.heading(offsetX: frame.cameraOffset?.x ?? 0, projection: projection, aspect: aspect)
        let distance = hypot(Double(world.x), Double(world.y))
        let angle = atan2(Double(world.x), Double(world.y)) - heading
        return projection.personHeight(atGround: CGPoint(x: distance * sin(angle), y: distance * cos(angle)))
    }

    /// ゴールの幅方向（ワールド座標の単位ベクトル。ピッチの長さ方向と直交する）
    var widthDirection: CGPoint { CGPoint(x: -axis.y, y: axis.x) }

    // MARK: - Geometry

    /// カメラの向き（ラジアン）。画面の左右の移動量を、カメラを左右に振った角度とみなす
    private static func heading(offsetX: CGFloat, projection: GroundProjection, aspect: Double) -> Double {
        Double(offsetX) * aspect / projection.focal
    }

    /// 画面上の点を、カメラを中心にした地面上の位置にする（身長単位）
    private static func world(_ point: CGPoint, offsetX: CGFloat, projection: GroundProjection, aspect: Double) -> CGPoint? {
        guard let ground = projection.ground(point) else { return nil }
        let distance = hypot(Double(ground.x), Double(ground.y))
        let angle = heading(offsetX: offsetX, projection: projection, aspect: aspect) + atan2(Double(ground.x), Double(ground.y))
        return CGPoint(x: distance * sin(angle), y: distance * cos(angle))
    }

    /// 点の散らばりの主な向き（はっきりしなければ nil）。カメラから見て右向きにそろえる
    private static func principalAxis(of points: [CGPoint]) -> CGPoint? {
        let n = Double(points.count)
        let meanX = points.map { Double($0.x) }.reduce(0, +) / n
        let meanY = points.map { Double($0.y) }.reduce(0, +) / n
        var xx = 0.0, yy = 0.0, xy = 0.0
        for point in points {
            let dx = Double(point.x) - meanX, dy = Double(point.y) - meanY
            xx += dx * dx
            yy += dy * dy
            xy += dx * dy
        }
        let trace = xx + yy, determinant = xx * yy - xy * xy
        let gap = (trace * trace / 4 - determinant).squareRoot()
        let major = trace / 2 + gap, minor = trace / 2 - gap
        guard minor > 0, major / minor > 1.3 else { return nil }
        let angle = 0.5 * atan2(2 * xy, xx - yy)
        var axis = CGPoint(x: cos(angle), y: sin(angle))
        if axis.x < 0 { axis = CGPoint(x: -axis.x, y: -axis.y) }
        return axis
    }

    /// GK の位置から、左右のゴールの位置（ワールド座標）を求める
    private static func goalPoints(keepers: [CGPoint], field: [CGPoint], axis: CGPoint) -> (left: CGPoint?, right: CGPoint?) {
        guard keepers.count >= minimumGoalkeeperSamples else { return (nil, nil) }
        func along(_ point: CGPoint) -> Double { Double(point.x * axis.x + point.y * axis.y) }
        let sorted = keepers.sorted { along($0) < along($1) }
        let fieldCenter = field.map(along).sorted()[field.count / 2]

        // 長さ方向で大きく離れた 2 つのまとまりがあれば、左右の GK とみなす
        var clusters: [[CGPoint]] = [sorted]
        if let last = sorted.last, let first = sorted.first, along(last) - along(first) > GroundProjection.units(meters: 16) {
            let gaps = zip(sorted, sorted.dropFirst()).enumerated().map { ($0.offset, along($0.element.1) - along($0.element.0)) }
            if let split = gaps.max(by: { $0.1 < $1.1 }),
               split.0 + 1 >= minimumGoalkeeperSamples, sorted.count - split.0 - 1 >= minimumGoalkeeperSamples {
                clusters = [Array(sorted[...split.0]), Array(sorted[(split.0 + 1)...])]
            }
        }

        var left: CGPoint?, right: CGPoint?
        for cluster in clusters where cluster.count >= minimumGoalkeeperSamples {
            let median = along(cluster[cluster.count / 2])
            // GK はゴールより少し前に出るので、最も外側に近い位置（1 割の位置）をゴールとする
            let isLeft = median < fieldCenter
            let edge = isLeft ? cluster[cluster.count / 10] : cluster[cluster.count - 1 - cluster.count / 10]
            let widths = cluster.map { Double(-$0.x * axis.y + $0.y * axis.x) }.sorted()
            let width = widths[widths.count / 2]
            // 幅方向は GK の中央、長さ方向は外側の位置
            let point = CGPoint(
                x: along(edge) * Double(axis.x) - width * Double(axis.y),
                y: along(edge) * Double(axis.y) + width * Double(axis.x)
            )
            if isLeft { left = point } else { right = point }
        }
        return (left, right)
    }
}
