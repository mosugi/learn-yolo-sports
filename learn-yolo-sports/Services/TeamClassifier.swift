//
//  TeamClassifier.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation

/// 選手のユニフォーム色から2チームに分ける
///
/// - L*a*b* 空間で、明るさ（L*）の重みを下げて k-means（k=2）を行う。日なたと日陰で同じチームが割れにくくなる。
/// - 初期値は k-means++ で複数回試し、まとまりが最もよい結果を使う（乱数は固定シードで毎回同じ結果になる）。
/// - 審判や誤検出のような外れ値をいったん除いてから分け直し、外れ値は近いチームに十分近い場合だけ割り当てる。
nonisolated enum TeamClassifier {

    /// 明るさの重み。1 未満にすると色味（a*, b*）を重視する
    private static let lightnessWeight = 0.5
    private static let restarts = 6
    private static let iterations = 20

    /// - Parameter colors: 選手（player のみ、GK・審判は含めない）の胴体色。呼び出し側がインデックスを覚えておき、
    ///   `assignments` と同じ順で引き戻してチームを割り当てる。
    /// - Returns: 各色のチーム番号（0 or 1。どちらとも言えない外れ値は nil）と、チームの代表色・名前。
    ///   チーム 0 が人数の多い方になる。
    static func classify(colors: [RGBColor]) -> (assignments: [Int?], teams: [TeamInfo]) {
        guard colors.count >= 2 else {
            let color = colors.first ?? RGBColor(red: 0.5, green: 0.5, blue: 0.5)
            return (Array(repeating: 0, count: colors.count), [TeamInfo(id: 0, name: "チームA", color: color)])
        }

        let points = colors.map(feature)

        // 1回目: 全件で分けて、各クラスタの中心から遠すぎる点を外れ値とみなす
        let first = bestKMeans(points)
        let inlierMask = inliers(points: points, result: first)
        let inlierPoints = points.indices.filter { inlierMask[$0] }.map { points[$0] }

        // 2回目: 外れ値を除いて分け直す（外れ値が少なすぎる・多すぎる場合は1回目を使う）
        let result = inlierPoints.count >= max(2, points.count / 2) ? bestKMeans(inlierPoints) : first
        var centroids = result.centroids

        // 外れ値も含めて割り当てる。外れ値は2チームの中心間距離の半分より近い場合のみ採用する
        let separation = distance(centroids[0], centroids[1])
        var assignments: [Int?] = points.indices.map { index in
            let d0 = distance(points[index], centroids[0])
            let d1 = distance(points[index], centroids[1])
            let team = d0 <= d1 ? 0 : 1
            if inlierMask[index] { return team }
            return min(d0, d1) < separation / 2 ? team : nil
        }

        // 人数の多い方をチーム0にそろえる
        let count0 = assignments.filter { $0 == 0 }.count
        let count1 = assignments.filter { $0 == 1 }.count
        if count1 > count0 {
            assignments = assignments.map { $0.map { 1 - $0 } }
            centroids.swapAt(0, 1)
        }

        let teamColors = [0, 1].map { team -> RGBColor in
            let members = colors.indices.filter { assignments[$0] == team }.map { colors[$0] }
            return averageRGB(members) ?? RGBColor(red: 0.5, green: 0.5, blue: 0.5)
        }

        let (nameA, nameB) = teamNames(for: teamColors)
        let teams = [
            TeamInfo(id: 0, name: nameA, color: teamColors[0]),
            TeamInfo(id: 1, name: nameB, color: teamColors[1]),
        ]
        return (assignments, teams)
    }

    // MARK: - k-means

    private typealias Point = (Double, Double, Double)

    private struct KMeansResult {
        var labels: [Int]
        var centroids: [Point]
        var inertia: Double
    }

    private static func feature(_ color: RGBColor) -> Point {
        let lab = color.lab
        return (lab.l * lightnessWeight, lab.a, lab.b)
    }

    private static func distance(_ p: Point, _ q: Point) -> Double {
        let d0 = p.0 - q.0, d1 = p.1 - q.1, d2 = p.2 - q.2
        return (d0 * d0 + d1 * d1 + d2 * d2).squareRoot()
    }

    /// k-means++ 初期化で複数回試し、クラスタ内の二乗距離の合計が最小の結果を返す
    private static func bestKMeans(_ points: [Point]) -> KMeansResult {
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

    private static func kMeansPlusPlusSeeds(_ points: [Point], using generator: inout SeededGenerator) -> [Point] {
        let first = points[Int.random(in: 0..<points.count, using: &generator)]
        let weights = points.map { pow(distance($0, first), 2) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return [first, first] }

        var target = Double.random(in: 0..<total, using: &generator)
        for (index, weight) in weights.enumerated() {
            target -= weight
            if target <= 0 { return [first, points[index]] }
        }
        return [first, points[points.count - 1]]
    }

    private static func kMeans(_ points: [Point], initial: [Point]) -> KMeansResult {
        var centroids = initial
        var labels = Array(repeating: 0, count: points.count)

        for _ in 0..<iterations {
            var changed = false
            for (index, point) in points.enumerated() {
                let label = distance(point, centroids[0]) <= distance(point, centroids[1]) ? 0 : 1
                if label != labels[index] {
                    labels[index] = label
                    changed = true
                }
            }

            for team in 0..<2 {
                let members = points.indices.filter { labels[$0] == team }.map { points[$0] }
                if let mean = mean(members) { centroids[team] = mean }
            }
            if !changed { break }
        }

        let inertia = points.indices.reduce(0.0) { $0 + pow(distance(points[$1], centroids[labels[$1]]), 2) }
        return KMeansResult(labels: labels, centroids: centroids, inertia: inertia)
    }

    /// 各クラスタで「中心からの距離の中央値 + 3×MAD」を超える点を外れ値とする
    private static func inliers(points: [Point], result: KMeansResult) -> [Bool] {
        var mask = Array(repeating: true, count: points.count)
        for team in 0..<2 {
            let members = points.indices.filter { result.labels[$0] == team }
            guard members.count >= 5 else { continue }
            let distances = members.map { distance(points[$0], result.centroids[team]) }
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

    private static func mean(_ points: [Point]) -> Point? {
        guard !points.isEmpty else { return nil }
        let n = Double(points.count)
        let sum = points.reduce((0.0, 0.0, 0.0)) { ($0.0 + $1.0, $0.1 + $1.1, $0.2 + $1.2) }
        return (sum.0 / n, sum.1 / n, sum.2 / n)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func averageRGB(_ colors: [RGBColor]) -> RGBColor? {
        guard !colors.isEmpty else { return nil }
        let n = Double(colors.count)
        let sum = colors.reduce((0.0, 0.0, 0.0)) { ($0.0 + $1.red, $0.1 + $1.green, $0.2 + $1.blue) }
        return RGBColor(red: sum.0 / n, green: sum.1 / n, blue: sum.2 / n)
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
