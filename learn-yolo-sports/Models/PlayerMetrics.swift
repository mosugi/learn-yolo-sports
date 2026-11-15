//
//  PlayerMetrics.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/11.
//

import Foundation
import CoreGraphics

/// 1人の選手の動きの指標（選手を指定したときにだけ計算する）
///
/// 距離は写っている選手の身長（枠の高さ）を単位にし、カメラの動きを打ち消した位置で求める。
/// オンデバイス LLM に渡すため、生データではなく要約した値だけを持つ。
nonisolated struct PlayerMetrics {
    /// メートル換算に使う身長の仮定（m）
    static let assumedHeight = 1.6
    /// ボールに関わっているとみなす距離（身長単位）
    static let nearBallDistance = 3.0
    /// 相手に寄せられているとみなす距離（身長単位）
    static let pressureDistance = 2.0
    /// 走っているとみなす速さ（身長/秒。約 3.2 m/s）
    static let runningSpeed = 2.0
    /// 立ち止まっているとみなす速さ（身長/秒。約 0.5 m/s）
    static let standingSpeed = 0.3

    let player: PlayerIdentity
    let teamName: String?
    /// 写っていたフレーム数と、その時間（秒）
    let frameCount: Int
    let visibleDuration: Double
    /// 移動距離（身長単位）
    let distance: Double
    /// 平均の速さ・1秒間の最高の速さ（身長/秒）
    let averageSpeed: Double?
    let topSpeed: Double?
    /// 走っていた・立ち止まっていた時間の割合
    let runningRatio: Double?
    let standingRatio: Double?
    /// 画面上の位置（左/中央/右、奥/中央/手前の割合）
    let horizontalZones: [Double]
    let verticalZones: [Double]
    /// ボールが写っていたフレームのうち、ボールの近くにいた割合・最もボールに近い選手だった割合
    let nearBallRatio: Double?
    let closestToBallRatio: Double?
    /// 最も近い相手・味方までの平均距離（身長単位）と、相手に寄せられていた割合
    let nearestOpponentDistance: Double?
    let nearestTeammateDistance: Double?
    let pressuredRatio: Double?
    /// 重要シーンでボールを持っていた・パスの受け手の候補だった回数
    let carrierScenes: Int
    let targetScenes: Int
    /// 受け手の候補になったうち、おすすめの選択肢だった回数
    let recommendedTargetScenes: Int

    init(record: SavedAnalysis, player: PlayerIdentity) {
        self.player = player
        teamName = record.team(id: player.team)?.name
        let aspect = record.imageWidth > 0 && record.imageHeight > 0
            ? Double(record.imageWidth) / Double(record.imageHeight)
            : 16.0 / 9.0
        let interval = 1.0 / Double(max(1, record.framesPerSecond))

        /// 動画全体で共通の足元の位置（x は画面の高さを 1 とした単位）
        func position(_ detection: SavedDetection, in frame: SavedFrame) -> CGPoint {
            let offset = frame.cameraOffset ?? .zero
            let foot = detection.footPoint
            return CGPoint(x: (foot.x + offset.x) * aspect, y: foot.y + offset.y)
        }
        func gap(_ a: CGPoint, _ b: CGPoint, height: Double) -> Double {
            hypot(Double(a.x - b.x), Double(a.y - b.y)) / max(0.02, height)
        }

        var samples: [(time: Double, position: CGPoint, height: Double)] = []
        var xs: [CGFloat] = [], ys: [CGFloat] = []
        var ballFrames = 0, nearBall = 0, closestToBall = 0
        var opponentDistances: [Double] = [], teammateDistances: [Double] = []
        var pressured = 0

        for frame in record.frames {
            guard let me = frame.detections.first(where: { $0.playerID == player.id && !$0.isExcluded }) else { continue }
            let height = Double(me.boundingBox.height)
            let myPosition = position(me, in: frame)
            samples.append((frame.timestamp, myPosition, height))
            xs.append(me.footPoint.x)
            ys.append(me.footPoint.y)

            let others = (frame.detections(of: .player) + frame.detections(of: .goalkeeper))
                .filter { $0.playerID != player.id }

            if let ball = frame.detections(of: .ball).max(by: { $0.confidence < $1.confidence }) {
                ballFrames += 1
                let ballPoint = CGPoint(x: ball.center.x * aspect, y: ball.center.y)
                let myFoot = CGPoint(x: me.footPoint.x * aspect, y: me.footPoint.y)
                let myDistance = gap(myFoot, ballPoint, height: height)
                if myDistance <= Self.nearBallDistance { nearBall += 1 }
                let othersCloser = others.contains { other in
                    let foot = CGPoint(x: other.footPoint.x * aspect, y: other.footPoint.y)
                    return gap(foot, ballPoint, height: height) < myDistance
                }
                if !othersCloser { closestToBall += 1 }
            }

            if let team = player.team {
                func nearest(_ list: [SavedDetection]) -> Double? {
                    list.map { other in
                        gap(position(other, in: frame), myPosition, height: (height + Double(other.boundingBox.height)) / 2)
                    }.min()
                }
                if let distance = nearest(others.filter { $0.team != nil && $0.team != team }) {
                    opponentDistances.append(distance)
                    if distance <= Self.pressureDistance { pressured += 1 }
                }
                if let distance = nearest(others.filter { $0.team == team }) {
                    teammateDistances.append(distance)
                }
            }
        }

        frameCount = samples.count
        visibleDuration = Double(samples.count) * interval
        horizontalZones = Self.zoneRatios(xs)
        verticalZones = Self.zoneRatios(ys)

        // 追跡が途切れた区間（1秒以上）はつながない
        var total = 0.0
        var speeds: [Double] = []
        for (a, b) in zip(samples, samples.dropFirst()) {
            let dt = b.time - a.time
            guard dt > 0, dt <= 1.0 else { continue }
            let step = gap(a.position, b.position, height: (a.height + b.height) / 2)
            total += step
            speeds.append(step / dt)
        }
        distance = total
        if speeds.isEmpty {
            averageSpeed = nil
            topSpeed = nil
            runningRatio = nil
            standingRatio = nil
        } else {
            averageSpeed = speeds.reduce(0, +) / Double(speeds.count)
            // 1フレームの揺れで最高速度が跳ねないよう、約1秒の移動平均の最大をとる
            let window = max(1, record.framesPerSecond)
            let smoothed = speeds.count >= window
                ? (0...(speeds.count - window)).map { start in speeds[start..<(start + window)].reduce(0, +) / Double(window) }
                : [speeds.reduce(0, +) / Double(speeds.count)]
            topSpeed = smoothed.max()
            runningRatio = Double(speeds.filter { $0 >= Self.runningSpeed }.count) / Double(speeds.count)
            standingRatio = Double(speeds.filter { $0 < Self.standingSpeed }.count) / Double(speeds.count)
        }

        nearBallRatio = ballFrames > 0 ? Double(nearBall) / Double(ballFrames) : nil
        closestToBallRatio = ballFrames > 0 ? Double(closestToBall) / Double(ballFrames) : nil
        nearestOpponentDistance = opponentDistances.isEmpty ? nil : opponentDistances.reduce(0, +) / Double(opponentDistances.count)
        nearestTeammateDistance = teammateDistances.isEmpty ? nil : teammateDistances.reduce(0, +) / Double(teammateDistances.count)
        pressuredRatio = opponentDistances.isEmpty ? nil : Double(pressured) / Double(opponentDistances.count)

        let label = player.label
        var carrier = 0, target = 0, recommended = 0
        for segment in record.segments ?? [] {
            guard let tactics = segment.tactics else { continue }
            if tactics.carrierLabel == label, tactics.attackingTeam == player.team { carrier += 1 }
            if let option = tactics.options.first(where: { $0.targetLabel == label }), tactics.attackingTeam == player.team {
                target += 1
                if option.id == segment.recommendedOptionID { recommended += 1 }
            }
        }
        carrierScenes = carrier
        targetScenes = target
        recommendedTargetScenes = recommended
    }

    // MARK: - Text

    /// 身長単位の距離をメートルの目安にする
    static func meters(_ heights: Double) -> Double {
        heights * assumedHeight
    }

    /// 身長/秒を km/h の目安にする
    static func kilometersPerHour(_ heightsPerSecond: Double) -> Double {
        heightsPerSecond * assumedHeight * 3.6
    }

    /// 指標を日本語のテキストにまとめる（LLM への入力用）
    var summaryText: String {
        var lines: [String] = []
        let name = teamName.map { "\($0)の\(player.label)" } ?? player.label
        lines.append("- 対象の選手: \(name)\(player.isGoalkeeper ? "（GK）" : "")")
        lines.append("- 写っていた時間: 約\(Int(visibleDuration.rounded()))秒（\(String(format: "%.0f", player.firstSeen))〜\(String(format: "%.0f", player.lastSeen))秒）")
        lines.append("- 移動距離: 約\(Int(Self.meters(distance).rounded())) m（身長の \(String(format: "%.0f", distance)) 倍）")
        if let averageSpeed, let topSpeed {
            lines.append("- 平均の速さ: 約\(String(format: "%.1f", Self.kilometersPerHour(averageSpeed))) km/h、1秒間の最高: 約\(String(format: "%.1f", Self.kilometersPerHour(topSpeed))) km/h")
        }
        if let runningRatio, let standingRatio {
            lines.append("- 走っていた時間の割合: \(Self.percent(runningRatio))、ほぼ止まっていた割合: \(Self.percent(standingRatio))")
        }
        lines.append("- 画面上の位置（左/中央/右）: \(Self.zonesText(horizontalZones))")
        lines.append("- 画面上の位置（奥/中央/手前）: \(Self.zonesText(verticalZones))")
        if let nearBallRatio, let closestToBallRatio {
            lines.append("- ボールの近く（身長の\(Int(Self.nearBallDistance))倍以内）にいた割合: \(Self.percent(nearBallRatio))")
            lines.append("- 写っている選手の中で最もボールに近かった割合: \(Self.percent(closestToBallRatio))")
        } else {
            lines.append("- 写っていた間にボールはほとんど検出されませんでした")
        }
        if let nearestOpponentDistance, let pressuredRatio {
            lines.append("- 最も近い相手までの平均距離: 約\(String(format: "%.1f", Self.meters(nearestOpponentDistance))) m、相手に寄せられていた（約\(Int(Self.meters(Self.pressureDistance)))m以内）割合: \(Self.percent(pressuredRatio))")
        }
        if let nearestTeammateDistance {
            lines.append("- 最も近い味方までの平均距離: 約\(String(format: "%.1f", Self.meters(nearestTeammateDistance))) m")
        }
        if carrierScenes + targetScenes > 0 {
            lines.append("- 重要シーンでボールを持っていた回数: \(carrierScenes)、パスの受け手の候補になった回数: \(targetScenes)（うちおすすめの選択肢: \(recommendedTargetScenes)）")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func zoneRatios(_ values: [CGFloat]) -> [Double] {
        guard !values.isEmpty else { return [0, 0, 0] }
        var counts = [0, 0, 0]
        for value in values {
            counts[min(2, max(0, Int(value * 3)))] += 1
        }
        return counts.map { Double($0) / Double(values.count) }
    }

    private static func zonesText(_ zones: [Double]) -> String {
        zones.map(percent).joined(separator: " / ")
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
