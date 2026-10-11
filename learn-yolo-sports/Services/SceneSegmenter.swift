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

    private struct FrameScore {
        let value: Double
        let kind: SceneKind
    }

    private struct Peak {
        let time: Double
        let kind: SceneKind
    }

    /// フレーム列から重要シーンを区切る（1〜12個、動画の長さに応じて増減する）
    static func segments(frames: [SavedFrame], duration: Double) -> [SceneSegment] {
        guard !frames.isEmpty, duration > 0 else { return [] }

        let sorted = frames.sorted { $0.timestamp < $1.timestamp }
        let frameScores = computeScores(sorted)
        let times = sorted.map(\.timestamp)
        let smoothedValues = movingAverage(frameScores.map(\.value), window: smoothingWindowSeconds)
        let kinds = frameScores.map(\.kind)

        let maxSegments = max(3, min(12, Int((duration / minSegmentSeconds).rounded())))
        var peaks = pickPeaks(times: times, scores: smoothedValues, kinds: kinds, maxCount: maxSegments)

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
                kind: peak.kind
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

    /// スコアの高い順に、間隔を空けてピークを選ぶ
    private static func pickPeaks(times: [Double], scores: [Double], kinds: [SceneKind], maxCount: Int) -> [Peak] {
        let candidates = scores.indices.sorted { scores[$0] > scores[$1] }
        var chosenTimes: [Double] = []
        var peaks: [Peak] = []

        for index in candidates {
            guard scores[index] > 0 else { continue }
            let time = times[index]
            if chosenTimes.contains(where: { abs($0 - time) < minPeakSpacing }) { continue }
            chosenTimes.append(time)
            peaks.append(Peak(time: time, kind: kinds[index]))
            if peaks.count >= maxCount { break }
        }

        return peaks.sorted { $0.time < $1.time }
    }
}
