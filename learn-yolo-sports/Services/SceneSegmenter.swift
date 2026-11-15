//
//  SceneSegmenter.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation
import CoreGraphics

/// 検出結果から重要シーンを区切る
nonisolated enum SceneSegmenter {

    /// ボール周辺とみなす距離（正規化座標）。AnalysisMetrics と合わせる。
    private static let nearBallDistance: CGFloat = 0.15
    private static let edgeZone: CGFloat = 1.0 / 3.0
    private static let smoothingWindowSeconds = 5
    private static let minPeakSpacing: Double = 45
    private static let minSegmentSeconds: Double = 75
    /// 攻守の切り替えとして取り上げる、奪ったあとにボールを持ち続けた時間の下限（秒）
    private static let minTransitionKeep: Double = 2
    /// 攻守の切り替えどうし・他のシーンとの間隔（秒）
    private static let minTransitionSpacing: Double = 20
    /// 攻守の切り替えから、注目時点（奪った選手が次の判断をする時点）までの時間（秒）
    private static let transitionLead: Double = 1

    private struct FrameScore {
        let value: Double
        let kind: SceneKind
    }

    private struct Peak {
        let time: Double
        let kind: SceneKind
        var team: Int? = nil
    }

    /// フレーム列から重要シーンを区切る
    ///
    /// 攻守が切り替わった場面（ボールを奪って持ち続けた場面）を優先して取り上げ、残りをボール周辺の
    /// 密集度・端寄り・速さのスコアが高い場面で埋める（スコアの場面は 1〜12 個、動画の長さに応じて増減する）。
    static func segments(frames: [SavedFrame], duration: Double, aspectRatio: Double = 16.0 / 9.0) -> [SceneSegment] {
        guard !frames.isEmpty, duration > 0 else { return [] }

        let sorted = frames.sorted { $0.timestamp < $1.timestamp }
        let frameScores = computeScores(sorted)
        let times = sorted.map(\.timestamp)
        // 移動平均の幅は秒で決め、フレームの間隔からフレーム数に直す
        let interval = sorted.count > 1 ? (times[times.count - 1] - times[0]) / Double(sorted.count - 1) : 1
        let window = max(1, Int((Double(smoothingWindowSeconds) / max(0.01, interval)).rounded()))
        let smoothedValues = movingAverage(frameScores.map(\.value), window: window)
        let kinds = frameScores.map(\.kind)

        let maxSegments = max(3, min(12, Int((duration / minSegmentSeconds).rounded())))
        let transitions = transitionPeaks(frames: sorted, duration: duration, aspectRatio: aspectRatio)
        var peaks = transitions + pickPeaks(
            times: times,
            scores: smoothedValues,
            kinds: kinds,
            maxCount: maxSegments,
            avoiding: transitions.map(\.time)
        )
        peaks.sort { $0.time < $1.time }

        if peaks.isEmpty {
            peaks = [Peak(time: duration / 2, kind: .buildUp)]
        }

        var boundaries: [Double] = [0]
        for (a, b) in zip(peaks, peaks.dropFirst()) {
            boundaries.append((a.time + b.time) / 2)
        }
        boundaries.append(duration)

        return peaks.enumerated().map { index, peak in
            SceneSegment(
                startTime: boundaries[index],
                endTime: boundaries[index + 1],
                keyTime: peak.time,
                kind: peak.kind,
                team: peak.team
            )
        }
    }

    // MARK: - Scoring

    /// ボール周辺の密集度・端寄り・移動速度からフレームごとのスコアを計算する
    private static func computeScores(_ frames: [SavedFrame]) -> [FrameScore] {
        var results: [FrameScore] = []
        var previousBall: (time: Double, point: CGPoint)?

        for frame in frames {
            let players = frame.detections(of: .player) + frame.detections(of: .goalkeeper)
            guard let ball = frame.detections(of: .ball).max(by: { $0.confidence < $1.confidence }) else {
                results.append(FrameScore(value: 0, kind: .buildUp))
                previousBall = nil
                continue
            }

            let nearCount = players.filter {
                hypot($0.center.x - ball.center.x, $0.center.y - ball.center.y) <= nearBallDistance
            }.count
            let isEdge = ball.center.x <= edgeZone || ball.center.x >= (1 - edgeZone)

            var speed = 0.0
            if let previousBall, frame.timestamp > previousBall.time {
                let interval = frame.timestamp - previousBall.time
                speed = Double(hypot(ball.center.x - previousBall.point.x, ball.center.y - previousBall.point.y)) / interval
            }
            previousBall = (frame.timestamp, ball.center)

            var value = Double(nearCount) + speed * 4
            if isEdge { value += 1.5 }

            let kind: SceneKind
            if speed > 0.35 {
                kind = .fastBreak
            } else if isEdge {
                kind = .goalThreat
            } else if nearCount >= 3 {
                kind = .congestion
            } else {
                kind = .buildUp
            }

            results.append(FrameScore(value: value, kind: kind))
        }
        return results
    }

    private static func movingAverage(_ values: [Double], window: Int) -> [Double] {
        guard window > 1, !values.isEmpty else { return values }
        let half = window / 2
        return values.indices.map { i in
            let lo = max(0, i - half)
            let hi = min(values.count - 1, i + half)
            let slice = values[lo...hi]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }

    /// 攻守の切り替え（奪ったあとにボールを持ち続けた場面）を、持ち続けた時間の長い順に間隔を空けて選ぶ
    private static func transitionPeaks(frames: [SavedFrame], duration: Double, aspectRatio: Double) -> [Peak] {
        let holdings = BallPossession.holdings(frames: frames, aspect: aspectRatio)
        let candidates = BallPossession.turnovers(in: holdings)
            .filter { $0.kept >= minTransitionKeep }
            .sorted { $0.kept > $1.kept }
        let maxCount = max(1, min(6, Int((duration / 120).rounded())))
        var peaks: [Peak] = []
        for candidate in candidates where peaks.count < maxCount {
            let time = min(duration, candidate.time + transitionLead)
            guard !peaks.contains(where: { abs($0.time - time) < minTransitionSpacing }) else { continue }
            peaks.append(Peak(time: time, kind: .transition, team: candidate.team))
        }
        return peaks
    }

    /// スコアの高い順に、間隔を空けてピークを選ぶ（avoiding の時刻の近くは選ばない）
    private static func pickPeaks(times: [Double], scores: [Double], kinds: [SceneKind], maxCount: Int, avoiding: [Double] = []) -> [Peak] {
        let candidates = scores.indices.sorted { scores[$0] > scores[$1] }
        var chosenTimes: [Double] = []
        var peaks: [Peak] = []

        for index in candidates {
            guard scores[index] > 0 else { continue }
            let time = times[index]
            if chosenTimes.contains(where: { abs($0 - time) < minPeakSpacing }) { continue }
            if avoiding.contains(where: { abs($0 - time) < minTransitionSpacing }) { continue }
            chosenTimes.append(time)
            peaks.append(Peak(time: time, kind: kinds[index]))
            if peaks.count >= maxCount { break }
        }

        return peaks.sorted { $0.time < $1.time }
    }
}
