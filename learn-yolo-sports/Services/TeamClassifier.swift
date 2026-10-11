//
//  TeamClassifier.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation

/// 選手のユニフォーム色から2チームの代表色を求める
///
/// - L*a*b* 空間で、明るさ（L*）の重みを下げて k-means（k=2）を行う。日なたと日陰で同じチームが割れにくくなる。
/// - 初期値は k-means++ で複数回試し、まとまりが最もよい結果を使う（乱数は固定シードで毎回同じ結果になる）。
/// - 審判や誤検出のような外れ値をいったん除いてから分け直す。
///
/// 個々の選手がどちらのチームかは、ここで求めた代表色をもとに追跡ごとの多数決で決める（PlayerTracker）。
nonisolated enum TeamClassifier {

    private static let restarts = 6
    private static let iterations = 20

    /// - Parameter colors: 選手（GK・審判を除く）の胴体色
    /// - Returns: チームの代表色（チーム 0 が人数の多い方）と、表示用のチーム情報。2チームに分けられない場合は nil
    static func classify(colors: [LabColor]) -> (centroids: [LabColor], teams: [TeamInfo])? {
        guard colors.count >= 4 else { return nil }

        // 1回目: 全件で分けて、各クラスタの中心から遠すぎる点を外れ値とみなす
        let first = bestKMeans(colors)
        let inlierMask = inliers(points: colors, result: first)
        let inlierPoints = colors.indices.filter { inlierMask[$0] }.map { colors[$0] }

        // 2回目: 外れ値を除いて分け直す（外れ値が多すぎる場合は1回目を使う）
        let result = inlierPoints.count >= max(4, colors.count / 2) ? bestKMeans(inlierPoints) : first
        var centroids = result.centroids
        // 色がほとんど同じなら2チームに分けられない
        guard centroids[0].distance(to: centroids[1]) > 15 else { return nil }

        // 人数の多い方をチーム0にそろえる
        let count0 = result.labels.filter { $0 == 0 }.count
        if count0 * 2 < result.labels.count {
            centroids.swapAt(0, 1)
        }

        let teamColors = centroids.map(\.rgbColor)
        let (nameA, nameB) = teamNames(for: teamColors)
        let teams = [
            TeamInfo(id: 0, name: nameA, color: teamColors[0]),
            TeamInfo(id: 1, name: nameB, color: teamColors[1]),
        ]
        return (centroids, teams)
    }

    // MARK: - k-means

    private struct KMeansResult {
        var labels: [Int]
        var centroids: [LabColor]
        var inertia: Double
    }

    /// k-means++ 初期化で複数回試し、クラスタ内の二乗距離の合計が最小の結果を返す
    private static func bestKMeans(_ points: [LabColor]) -> KMeansResult {
        var generator = SeededGenerator(seed: 0x5EED)
        var best: KMeansResult?
        for _ in 0..<restarts {
            let result = kMeans(points, initial: kMeansPlusPlusSeeds(points, using: &generator))
            if best == nil || result.inertia < best!.inertia {
                best = result
            }
        }
        return best!
    }

    private static func kMeansPlusPlusSeeds(_ points: [LabColor], using generator: inout SeededGenerator) -> [LabColor] {
        let first = points[Int.random(in: 0..<points.count, using: &generator)]
        let weights = points.map { pow($0.distance(to: first), 2) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return [first, first] }

        var target = Double.random(in: 0..<total, using: &generator)
        for (index, weight) in weights.enumerated() {
            target -= weight
            if target <= 0 { return [first, points[index]] }
        }
        return [first, points[points.count - 1]]
    }

    private static func kMeans(_ points: [LabColor], initial: [LabColor]) -> KMeansResult {
        var centroids = initial
        var labels = Array(repeating: 0, count: points.count)

        for _ in 0..<iterations {
            var changed = false
            for (index, point) in points.enumerated() {
                let label = point.distance(to: centroids[0]) <= point.distance(to: centroids[1]) ? 0 : 1
                if label != labels[index] {
                    labels[index] = label
                    changed = true
                }
            }

            for team in 0..<2 {
                let members = points.indices.filter { labels[$0] == team }.map { points[$0] }
                if let mean = LabColor.mean(members) { centroids[team] = mean }
            }
            if !changed { break }
        }

        let inertia = points.indices.reduce(0.0) { $0 + pow(points[$1].distance(to: centroids[labels[$1]]), 2) }
        return KMeansResult(labels: labels, centroids: centroids, inertia: inertia)
    }

    /// 各クラスタで「中心からの距離の中央値 + 3×MAD」を超える点を外れ値とする
    private static func inliers(points: [LabColor], result: KMeansResult) -> [Bool] {
        var mask = Array(repeating: true, count: points.count)
        for team in 0..<2 {
            let members = points.indices.filter { result.labels[$0] == team }
            guard members.count >= 5 else { continue }
            let distances = members.map { points[$0].distance(to: result.centroids[team]) }
            let med = median(distances)
            let mad = median(distances.map { abs($0 - med) })
            let limit = med + 3 * max(mad, 1)
            for (member, d) in zip(members, distances) where d > limit {
                mask[member] = false
            }
        }
        return mask
    }

    // MARK: - Helpers

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func teamNames(for colors: [RGBColor]) -> (String, String) {
        let nameA = ColorNaming.japaneseName(for: colors[0])
        let nameB = ColorNaming.japaneseName(for: colors[1])
        if nameA == nameB {
            return ("チームA", "チームB")
        }
        return ("\(nameA)チーム", "\(nameB)チーム")
    }
}

/// 毎回同じ結果になるよう固定シードで使う乱数（SplitMix64）
nonisolated private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
