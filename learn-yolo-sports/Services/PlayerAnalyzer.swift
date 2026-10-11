//
//  PlayerAnalyzer.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation
import CoreGraphics

/// 背番号の分かった自チームの選手ごとに、動きを集計してアドバイスを作る
///
/// 保存済みの解析結果だけから計算するため、背番号を手で割り当て直すとすぐに反映される。
nonisolated enum PlayerAnalyzer {

    /// スプリントとみなす速度（m/s）
    static let sprintSpeed = 5.5

    private nonisolated struct Sample {
        let frame: Int
        let time: Double
        let position: CGPoint
    }

    static func reports(for record: SavedAnalysis) -> [PlayerReport] {
        guard let setup = record.setup else { return [] }
        let numbers = record.effectiveTrackNumbers
        guard !numbers.isEmpty else { return [] }

        let frames = record.frames
            .filter { $0.phase != nil }
            .sorted { $0.timestamp < $1.timestamp }
        guard !frames.isEmpty else { return [] }
        let frameInterval = 1 / Double(max(1, record.framesPerSecond))
        let scale = setup.lengthScale

        // 背番号ごとの位置（同じフレームで同じ背番号が重なった場合は先のものだけ）
        var samples: [Int: [Sample]] = [:]
        // フレームごとの自チームの位置と、背番号つきの選手
        var ownPositions: [[CGPoint]] = []
        var numberedPlayers: [[(number: Int, position: CGPoint)]] = []

        for (index, frame) in frames.enumerated() {
            var positions: [CGPoint] = []
            var numbered: [(number: Int, position: CGPoint)] = []
            for detection in frame.detections where detection.team == .own && !detection.isExcluded {
                guard let position = detection.pitchPosition else { continue }
                if detection.label != SportsClass.goalkeeper.rawValue {
                    positions.append(position)
                }
                guard let trackID = detection.trackID, let number = numbers[trackID],
                      !numbered.contains(where: { $0.number == number }) else { continue }
                numbered.append((number, position))
                samples[number, default: []].append(Sample(frame: index, time: frame.timestamp, position: position))
            }
            ownPositions.append(positions)
            numberedPlayers.append(numbered)
        }

        // ボール保持の切り替わり
        var changes: [PossessionChange] = []
        var previous: TeamSide?
        for frame in frames {
            if let possession = frame.possession {
                if let previous, previous != possession {
                    changes.append(PossessionChange(time: frame.timestamp, to: possession))
                }
                previous = possession
            }
        }

        func frameIndex(near time: Double, tolerance: Double) -> Int? {
            guard let index = frames.indices.min(by: { abs(frames[$0].timestamp - time) < abs(frames[$1].timestamp - time) }),
                  abs(frames[index].timestamp - time) <= tolerance else { return nil }
            return index
        }
        func position(of number: Int, at index: Int) -> CGPoint? {
            numberedPlayers[index].first { $0.number == number }?.position
        }

        var drafts: [(number: Int, metrics: Metrics)] = []
        for (number, list) in samples where list.count >= 3 {
            var metrics = Metrics()
            metrics.observedTime = Double(list.count) * frameInterval

            // 移動距離（短い間隔でつながっている区間だけ）
            var distance = 0.0, coveredTime = 0.0
            for (a, b) in zip(list, list.dropFirst()) {
                let dt = b.time - a.time
                guard dt > 0, dt <= 0.6 else { continue }
                distance += MatchAnalyzer.distance(a.position, b.position)
                coveredTime += dt
            }
            if coveredTime >= 20 {
                metrics.distancePerMinute = distance / coveredTime * 60
            }

            // スプリント（約1秒間の平均速度で判定し、2秒以上空いたら別の回とする）
            var lastSprint = -Double.infinity
            for (i, sample) in list.enumerated() {
                guard let later = list[(i + 1)...].first(where: { $0.time - sample.time >= 0.9 }),
                      later.time - sample.time <= 1.3 else { continue }
                let speed = MatchAnalyzer.distance(sample.position, later.position) / (later.time - sample.time)
                if speed >= sprintSpeed {
                    if sample.time - lastSprint > 2 { metrics.sprints += 1 }
                    lastSprint = sample.time
                }
            }

            // チームの中での前後の位置（0: 最後方, 1: 最前線）
            var relative: [Double] = []
            for sample in list {
                let values = ownPositions[sample.frame].map { setup.attackingCoordinate(of: $0) }
                guard values.count >= setup.format.minimumFieldPlayers,
                      let minimum = values.min(), let maximum = values.max(), maximum - minimum > 5 else { continue }
                relative.append((setup.attackingCoordinate(of: sample.position) - minimum) / (maximum - minimum))
            }
            if !relative.isEmpty {
                metrics.relativeDepth = relative.reduce(0, +) / Double(relative.count)
            }

            // ボールに最も近い自チームの選手だった時間
            for sample in list {
                let frame = frames[sample.frame]
                guard frame.possession == .own, let ball = frame.ball else { continue }
                let nearest = numberedPlayers[sample.frame].min {
                    MatchAnalyzer.distance($0.position, ball) < MatchAnalyzer.distance($1.position, ball)
                }
                if nearest?.number == number, MatchAnalyzer.distance(sample.position, ball) <= 2 {
                    metrics.ballTime += frameInterval
                }
            }

            // ボールを失った直後の寄せ
            for change in changes where change.to == .opponent {
                guard let start = frameIndex(near: change.time, tolerance: 0.5),
                      let p0 = position(of: number, at: start), let b0 = frames[start].ball,
                      MatchAnalyzer.distance(p0, b0) <= 20 * scale else { continue }
                metrics.counterPressChances += 1
                let d0 = MatchAnalyzer.distance(p0, b0)
                let reacted = frames.indices.contains { index in
                    let time = frames[index].timestamp
                    guard time > change.time, time <= change.time + MatchAnalyzer.transitionDuration,
                          let p = position(of: number, at: index), let b = frames[index].ball else { return false }
                    let d = MatchAnalyzer.distance(p, b)
                    return d <= 6 * scale || d0 - d >= 4 * scale
                }
                if reacted { metrics.counterPressCount += 1 }
            }

            // ボールを奪った直後の前進
            for change in changes where change.to == .own {
                guard let start = frameIndex(near: change.time, tolerance: 0.5),
                      let end = frameIndex(near: change.time + MatchAnalyzer.transitionDuration, tolerance: 0.7),
                      let p0 = position(of: number, at: start), let p1 = position(of: number, at: end) else { continue }
                metrics.forwardRunChances += 1
                if setup.attackingCoordinate(of: p1) - setup.attackingCoordinate(of: p0) >= 6 * scale {
                    metrics.forwardRunCount += 1
                }
            }

            metrics.positions = list.map(\.position)
            drafts.append((number, metrics))
        }

        // 移動距離はチーム内の中央値と比べる（カメラの距離や座標の誤差の影響を抑えるため）
        let distances = drafts.compactMap { $0.metrics.distancePerMinute }.sorted()
        let median = distances.isEmpty ? nil : distances[distances.count / 2]

        return drafts
            .sorted { $0.number < $1.number }
            .map { number, metrics in
                makeReport(number: number, metrics: metrics, medianDistance: median, setup: setup)
            }
    }

    // MARK: - Report

    private nonisolated struct Metrics {
        var observedTime = 0.0
        var distancePerMinute: Double?
        var sprints = 0
        var relativeDepth: Double?
        var ballTime = 0.0
        var counterPressCount = 0
        var counterPressChances = 0
        var forwardRunCount = 0
        var forwardRunChances = 0
        var positions: [CGPoint] = []
    }

    private static func makeReport(number: Int, metrics: Metrics, medianDistance: Double?, setup: AnalysisSetup) -> PlayerReport {
        let role: String
        switch metrics.relativeDepth {
        case let depth? where depth < 0.33: role = "後方"
        case let depth? where depth > 0.66: role = "前方"
        case .some: role = "中盤"
        case nil: role = "不明"
        }

        let relativeDistance: Double? = {
            guard let value = metrics.distancePerMinute, let medianDistance, medianDistance > 0 else { return nil }
            return value / medianDistance
        }()

        var advice: [PlayerAdvice] = []

        if let relativeDistance {
            let perMinute = Int(metrics.distancePerMinute ?? 0)
            if relativeDistance < 0.85 {
                advice.append(PlayerAdvice(
                    isPositive: false,
                    title: "運動量を増やしたい",
                    detail: "1分あたり約 \(perMinute) m で、チームの中央値より \(Int(((1 - relativeDistance) * 100).rounded()))% 少なめです。ボールが動くたびに立ち位置を取り直す意識を持ちましょう。"
                ))
            } else if relativeDistance > 1.15 {
                advice.append(PlayerAdvice(
                    isPositive: true,
                    title: "運動量が多い",
                    detail: "1分あたり約 \(perMinute) m で、チームの中央値より \(Int(((relativeDistance - 1) * 100).rounded()))% 多く動けています。"
                ))
            }
        }

        if metrics.counterPressChances >= 2 {
            let rate = Double(metrics.counterPressCount) / Double(metrics.counterPressChances)
            if rate <= 0.34 {
                advice.append(PlayerAdvice(
                    isPositive: false,
                    title: "失った直後の切り替え",
                    detail: "近くでボールを失った \(metrics.counterPressChances) 回のうち、3 秒以内に寄せられたのは \(metrics.counterPressCount) 回でした。失った瞬間に一歩目を前へ出す習慣をつけましょう。"
                ))
            } else if rate >= 0.67 {
                advice.append(PlayerAdvice(
                    isPositive: true,
                    title: "失った直後の素早い寄せ",
                    detail: "近くでボールを失った \(metrics.counterPressChances) 回のうち \(metrics.counterPressCount) 回、すぐにボールへ寄せられています。"
                ))
            }
        }

        if metrics.forwardRunChances >= 2 && role != "後方" {
            let rate = Double(metrics.forwardRunCount) / Double(metrics.forwardRunChances)
            if rate <= 0.34 {
                advice.append(PlayerAdvice(
                    isPositive: false,
                    title: "奪った後の前進",
                    detail: "ボールを奪った \(metrics.forwardRunChances) 回のうち、3 秒で前へ出られたのは \(metrics.forwardRunCount) 回でした。奪った瞬間を合図に相手の背後を狙いましょう。"
                ))
            } else if rate >= 0.67 {
                advice.append(PlayerAdvice(
                    isPositive: true,
                    title: "奪った後の素早い前進",
                    detail: "ボールを奪った \(metrics.forwardRunChances) 回のうち \(metrics.forwardRunCount) 回、すぐに前へ出られています。"
                ))
            }
        }

        if metrics.observedTime >= 60 && metrics.ballTime == 0 && role != "後方" {
            advice.append(PlayerAdvice(
                isPositive: false,
                title: "ボールに関わる回数",
                detail: "自チームの保持中に、ボールに最も近い選手になった場面がありませんでした。相手の間で顔を出し、パスを受ける位置を探しましょう。"
            ))
        }

        if advice.isEmpty {
            advice.append(PlayerAdvice(
                isPositive: true,
                title: "目立った課題なし",
                detail: "追跡できた範囲では、判定の目安から外れる動きはありませんでした。"
            ))
        }

        // 表示用に間引く
        let stride = max(1, metrics.positions.count / 150)
        let positions = Swift.stride(from: 0, to: metrics.positions.count, by: stride).map { metrics.positions[$0] }
        let average = CGPoint(
            x: metrics.positions.map(\.x).reduce(0, +) / CGFloat(max(1, metrics.positions.count)),
            y: metrics.positions.map(\.y).reduce(0, +) / CGFloat(max(1, metrics.positions.count))
        )
        let name = setup.rosterEntries.first { $0.number == number }?.name ?? ""

        return PlayerReport(
            number: number,
            name: name,
            role: role,
            observedTime: metrics.observedTime,
            distancePerMinute: metrics.distancePerMinute,
            relativeDistance: relativeDistance,
            sprints: metrics.sprints,
            ballTime: metrics.ballTime,
            counterPress: (metrics.counterPressCount, metrics.counterPressChances),
            forwardRuns: (metrics.forwardRunCount, metrics.forwardRunChances),
            averagePosition: average,
            positions: positions,
            advice: advice
        )
    }
}

extension PlayerReport {
    /// LLM・共有テキスト用の1行
    nonisolated var summaryLine: String {
        var parts = ["#\(number)\(name.isEmpty ? "" : " \(name)")（\(role)、追跡 \(Int(observedTime)) 秒）"]
        if let distancePerMinute {
            parts.append("移動 \(Int(distancePerMinute)) m/分")
        }
        parts.append("スプリント \(sprints) 回")
        if counterPress.chances > 0 {
            parts.append("失った直後の寄せ \(counterPress.count)/\(counterPress.chances)")
        }
        if forwardRuns.chances > 0 {
            parts.append("奪った直後の前進 \(forwardRuns.count)/\(forwardRuns.chances)")
        }
        let notes = advice.map { "\($0.isPositive ? "良い点" : "課題"): \($0.title)" }
        return parts.joined(separator: "、") + " → " + notes.joined(separator: " / ")
    }
}
