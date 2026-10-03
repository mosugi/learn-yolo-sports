//
//  CoachRules.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation
import CoreGraphics

/// 局面ごとのチームの形やボール周辺の人数を目安と比べ、解説する場面を選ぶ
///
/// 目安は 11人制（105m x 68m）での一般的な指導基準を、コートの大きさに合わせて換算している。
nonisolated enum CoachRules {

    /// 1つの規則で採用する場面の最大数
    static let maxScenesPerRule = 2
    static let maxIssues = 3
    static let maxPositives = 2
    /// 継続する状態を場面とみなす最短の時間（秒）
    static let minimumEpisodeDuration = 1.5

    static func report(analysis: MatchAnalysisResult, setup: AnalysisSetup, framesPerSecond: Int) -> CoachReport {
        let context = Context(setup: setup, states: analysis.states, frameInterval: 1 / Double(max(1, framesPerSecond)))

        var candidates: [Candidate] = []
        candidates += compactness(context)
        candidates += slide(context)
        candidates += width(context)
        candidates += support(context)
        candidates += counterPress(context, changes: analysis.possessionChanges)
        candidates += forwardRuns(context, changes: analysis.possessionChanges)

        let selected = select(candidates)
        let scenes = selected
            .sorted { $0.startTime < $1.startTime }
            .enumerated()
            .map { index, candidate in candidate.scene(id: index) }

        return CoachReport(
            summary: summary(context, changes: analysis.possessionChanges),
            scenes: scenes,
            notes: notes(context, analysis: analysis),
            opponentColor: analysis.opponentColor
        )
    }

    // MARK: - Context

    nonisolated struct Context {
        let setup: AnalysisSetup
        let states: [FrameState]
        let frameInterval: Double

        var length: Double { setup.pitchLength }
        var width: Double { setup.pitchWidth }
        /// 11人制の距離をこのコートに換算する
        func scaled(_ meters: Double) -> Double { meters * setup.lengthScale }

        /// 形を評価できるだけの自チームの選手が見えているか
        func hasShape(_ state: FrameState) -> Bool {
            state.ownFieldPlayers.count >= setup.format.minimumFieldPlayers
        }

        /// 自チームのフィールドプレーヤーの縦幅（攻める方向）
        func depth(_ state: FrameState) -> Double {
            let values = state.ownFieldPlayers.map { setup.attackingCoordinate(of: $0.position) }
            return (values.max() ?? 0) - (values.min() ?? 0)
        }

        /// 自チームのフィールドプレーヤーの横幅
        func lateralWidth(_ state: FrameState) -> Double {
            let values = state.ownFieldPlayers.map { Double($0.position.y) }
            return (values.max() ?? 0) - (values.min() ?? 0)
        }

        func centroidY(_ state: FrameState) -> Double {
            let values = state.ownFieldPlayers.map { Double($0.position.y) }
            return values.reduce(0, +) / Double(max(1, values.count))
        }

        func snapshot(_ state: FrameState, highlight: SceneHighlight) -> PitchSnapshot {
            PitchSnapshot(
                time: state.time,
                own: state.own.filter { !$0.isGoalkeeper }.map(\.position),
                opponent: state.opponent.filter { !$0.isGoalkeeper }.map(\.position),
                ownGoalkeepers: state.own.filter(\.isGoalkeeper).map(\.position),
                opponentGoalkeepers: state.opponent.filter(\.isGoalkeeper).map(\.position),
                ball: state.ball,
                highlight: highlight
            )
        }

        /// 指定した時刻に最も近い状態
        func state(near time: Double) -> FrameState? {
            states.min { abs($0.time - time) < abs($1.time - time) }
        }
    }

    // MARK: - Candidate

    nonisolated struct Candidate {
        let rule: CoachRule
        let isPositive: Bool
        let startTime: Double
        let endTime: Double
        let phase: GamePhase
        let title: String
        let evidence: String
        let comment: String
        let suggestion: String
        let snapshot: PitchSnapshot
        /// 重要度（大きいほど優先）
        let score: Double

        func scene(id: Int) -> CoachScene {
            CoachScene(
                id: id,
                rule: rule,
                isPositive: isPositive,
                startTime: startTime,
                endTime: endTime,
                peakTime: snapshot.time,
                phase: phase,
                title: title,
                evidence: evidence,
                comment: comment,
                suggestion: suggestion,
                snapshot: snapshot
            )
        }
    }

    /// 条件を満たす状態が続いた区間
    nonisolated struct Episode {
        var states: [(state: FrameState, value: Double)]

        var startTime: Double { states.first!.state.time }
        var endTime: Double { states.last!.state.time }
        var meanValue: Double { states.map(\.value).reduce(0, +) / Double(states.count) }
        /// 最も多かった局面
        var dominantPhase: GamePhase {
            let counts = Dictionary(grouping: states, by: { $0.state.phase }).mapValues(\.count)
            return counts.max { $0.value < $1.value }?.key ?? .unknown
        }

        func duration(frameInterval: Double) -> Double {
            endTime - startTime + frameInterval
        }
    }

    /// 条件を満たす状態が続く区間を集める
    /// - Parameter value: 条件を満たす場合に評価値を返す
    static func episodes(_ context: Context, value: (FrameState) -> Double?) -> [Episode] {
        var result: [Episode] = []
        var current: Episode?
        // 1フレーム程度の欠けは同じ区間として扱う
        let maxGap = context.frameInterval * 2.5

        for state in context.states {
            guard let v = value(state) else { continue }
            if var episode = current, state.time - episode.endTime <= maxGap {
                episode.states.append((state, v))
                current = episode
            } else {
                if let current { result.append(current) }
                current = Episode(states: [(state, v)])
            }
        }
        if let current { result.append(current) }
        return result.filter { $0.duration(frameInterval: context.frameInterval) >= minimumEpisodeDuration }
    }

    // MARK: - Rules

    /// 縦の間延び（守備時・局面不明時）と、コンパクトな守備
    static func compactness(_ context: Context) -> [Candidate] {
        let limit = context.scaled(42)
        let good = context.scaled(32)
        let target = context.scaled(35)
        var candidates: [Candidate] = []

        let stretched = episodes(context) { state in
            guard state.phase == .defense || state.phase == .unknown, context.hasShape(state) else { return nil }
            let depth = context.depth(state)
            return depth > limit ? depth : nil
        }
        for episode in stretched {
            let peak = episode.states.max { $0.value < $1.value }!
            let duration = episode.duration(frameInterval: context.frameInterval)
            let phaseNote = episode.dominantPhase == .defense ? "守備時に" : ""
            candidates.append(Candidate(
                rule: .compactness,
                isPositive: false,
                startTime: episode.startTime,
                endTime: episode.endTime,
                phase: episode.dominantPhase,
                title: "\(phaseNote)チームが縦に間延び",
                evidence: "縦幅 平均 \(meters(episode.meanValue))、最大 \(meters(peak.value))（目安 \(meters(limit)) 以下）が \(seconds(duration)) 続いた",
                comment: "最前線と最終ラインの距離が開き、ライン間のスペースで相手に前を向かれやすい状態です。",
                suggestion: "前線がボールに寄せたら最終ラインも連動して押し上げ、縦幅を \(meters(target)) 前後に保ちましょう。",
                snapshot: context.snapshot(peak.state, highlight: .teamBox),
                score: duration * (1 + (episode.meanValue / limit - 1) * 3)
            ))
        }

        let compact = episodes(context) { state in
            guard state.phase == .defense, context.hasShape(state) else { return nil }
            let depth = context.depth(state)
            return depth <= good ? depth : nil
        }
        for episode in compact {
            let peak = episode.states.min { $0.value < $1.value }!
            let duration = episode.duration(frameInterval: context.frameInterval)
            candidates.append(Candidate(
                rule: .compactness,
                isPositive: true,
                startTime: episode.startTime,
                endTime: episode.endTime,
                phase: .defense,
                title: "コンパクトな守備ブロック",
                evidence: "守備時の縦幅 平均 \(meters(episode.meanValue))（目安 \(meters(good)) 以下）を \(seconds(duration)) 維持",
                comment: "ライン間が詰まっており、相手が中央で前を向くスペースを消せています。",
                suggestion: "この距離感を保ったまま、ボールを奪いに行く合図（横パスやトラップの乱れ）をチームで共有しましょう。",
                snapshot: context.snapshot(peak.state, highlight: .teamBox),
                score: duration
            ))
        }
        return candidates
    }

    /// ボールサイドへのスライド（守備時）
    static func slide(_ context: Context) -> [Candidate] {
        let limit = context.width * 0.25
        let found = episodes(context) { state in
            guard state.phase == .defense, context.hasShape(state), let ball = state.ball else { return nil }
            let gap = abs(context.centroidY(state) - Double(ball.y))
            return gap > limit ? gap : nil
        }
        return found.map { episode in
            let peak = episode.states.max { $0.value < $1.value }!
            let duration = episode.duration(frameInterval: context.frameInterval)
            return Candidate(
                rule: .slide,
                isPositive: false,
                startTime: episode.startTime,
                endTime: episode.endTime,
                phase: .defense,
                title: "ボールサイドへのスライド不足",
                evidence: "チームの重心とボールの横方向の距離 平均 \(meters(episode.meanValue))（目安 \(meters(limit)) 以内）",
                comment: "ボールのあるサイドで人数が足りず、相手にサイドから前進されやすい配置です。",
                suggestion: "ボールが横に動いたら全員で同じ方向にスライドし、逆サイドの選手は中央まで絞りましょう。",
                snapshot: context.snapshot(peak.state, highlight: .teamBox),
                score: duration * (1 + (episode.meanValue / limit - 1) * 2)
            )
        }
    }

    /// 攻撃時の幅
    static func width(_ context: Context) -> [Candidate] {
        let narrow = context.width * 0.45
        let wide = context.width * 0.70
        var candidates: [Candidate] = []

        let narrowEpisodes = episodes(context) { state in
            guard state.phase == .attack, context.hasShape(state) else { return nil }
            let width = context.lateralWidth(state)
            return width < narrow ? width : nil
        }
        for episode in narrowEpisodes {
            let peak = episode.states.min { $0.value < $1.value }!
            let duration = episode.duration(frameInterval: context.frameInterval)
            candidates.append(Candidate(
                rule: .width,
                isPositive: false,
                startTime: episode.startTime,
                endTime: episode.endTime,
                phase: .attack,
                title: "攻撃時に幅が取れていない",
                evidence: "横幅 平均 \(meters(episode.meanValue))（コート幅 \(meters(context.width)) の \(percent(episode.meanValue / context.width))、目安 \(percent(0.45)) 以上）",
                comment: "選手が中央に集まり、相手の守備を横に広げられていません。",
                suggestion: "両サイドの選手はタッチライン際まで開き、中央の選手が使うスペースを作りましょう。",
                snapshot: context.snapshot(peak.state, highlight: .teamBox),
                score: duration * (1 + (1 - episode.meanValue / narrow) * 3)
            ))
        }

        let wideEpisodes = episodes(context) { state in
            guard state.phase == .attack, context.hasShape(state) else { return nil }
            let width = context.lateralWidth(state)
            return width >= wide ? width : nil
        }
        for episode in wideEpisodes {
            let peak = episode.states.max { $0.value < $1.value }!
            let duration = episode.duration(frameInterval: context.frameInterval)
            candidates.append(Candidate(
                rule: .width,
                isPositive: true,
                startTime: episode.startTime,
                endTime: episode.endTime,
                phase: .attack,
                title: "幅を使った攻撃",
                evidence: "攻撃時の横幅 平均 \(meters(episode.meanValue))（コート幅の \(percent(episode.meanValue / context.width))）",
                comment: "コートを広く使えており、相手の守備の間にスペースが生まれています。",
                suggestion: "広げた後は、空いた中央やサイドの裏へ素早くボールを動かす意識を持ちましょう。",
                snapshot: context.snapshot(peak.state, highlight: .teamBox),
                score: duration
            ))
        }
        return candidates
    }

    /// ボール保持者へのサポート（攻撃時）
    static func support(_ context: Context) -> [Candidate] {
        let radius = context.scaled(15)
        let found = episodes(context) { state in
            guard state.phase == .attack, let ball = state.ball else { return nil }
            let distances = state.ownFieldPlayers.map { MatchAnalyzer.distance($0.position, ball) }.sorted()
            guard !distances.isEmpty else { return nil }
            // 最も近い選手を保持者とみなし、それ以外で近くにいる人数
            let supporters = distances.dropFirst().filter { $0 <= radius }.count
            return supporters < 2 ? Double(supporters) : nil
        }
        return found.map { episode in
            let peak = episode.states.min { $0.value < $1.value }!
            let duration = episode.duration(frameInterval: context.frameInterval)
            return Candidate(
                rule: .support,
                isPositive: false,
                startTime: episode.startTime,
                endTime: episode.endTime,
                phase: .attack,
                title: "ボール保持者へのサポート不足",
                evidence: "保持者から \(meters(radius)) 以内の味方 平均 \(String(format: "%.1f", episode.meanValue)) 人（目安 2 人以上）",
                comment: "パスの受け手が近くにおらず、保持者が孤立して奪われやすい状態です。",
                suggestion: "保持者の斜め前と斜め後ろに、角度をつけて2人以上がパスコースを作りましょう。",
                snapshot: context.snapshot(peak.state, highlight: .ballRadius(radius)),
                score: duration * (1 + (2 - episode.meanValue))
            )
        }
    }

    /// ボールを失った直後の寄せ（即時奪回）
    static func counterPress(_ context: Context, changes: [PossessionChange]) -> [Candidate] {
        let radius = context.scaled(6)
        var candidates: [Candidate] = []

        for change in changes where change.to == .opponent {
            let window = context.states.filter {
                $0.time >= change.time && $0.time <= change.time + MatchAnalyzer.transitionDuration && $0.ball != nil
            }
            guard window.count >= 2 else { continue }

            let counts = window.map { state -> (FrameState, Int) in
                let ball = state.ball!
                return (state, state.ownFieldPlayers.filter { MatchAnalyzer.distance($0.position, ball) <= radius }.count)
            }
            guard let best = counts.max(by: { $0.1 < $1.1 }) else { continue }
            let isPositive: Bool
            if best.1 <= 1 {
                isPositive = false
            } else if best.1 >= 3 {
                isPositive = true
            } else {
                continue
            }

            candidates.append(Candidate(
                rule: .counterPress,
                isPositive: isPositive,
                startTime: change.time,
                endTime: window.last!.time,
                phase: .transitionToDefense,
                title: isPositive ? "ボールを失った直後の素早い寄せ" : "ボールを失った直後の寄せが少ない",
                evidence: "失ってから 3 秒以内にボールから \(meters(radius)) 以内へ寄せた味方 最大 \(best.1) 人（目安 3 人以上）",
                comment: isPositive
                    ? "失った瞬間に複数人で囲みに行けており、相手に前を向かせていません。"
                    : "失った後に寄せる選手が少なく、相手に落ち着いて前進されています。",
                suggestion: isPositive
                    ? "囲んだ後に奪い切れたかも映像で確認し、奪った後の最初のパスまでつなげましょう。"
                    : "失った瞬間に最も近い選手がすぐ寄せ、周りの2人がパスコースを消す約束事を作りましょう。",
                snapshot: context.snapshot(best.0, highlight: .ballRadius(radius)),
                score: 3 + abs(Double(best.1) - 2)
            ))
        }
        return candidates
    }

    /// ボールを奪った直後の前進
    static func forwardRuns(_ context: Context, changes: [PossessionChange]) -> [Candidate] {
        let threshold = context.scaled(6)
        var candidates: [Candidate] = []

        for change in changes where change.to == .own {
            guard let start = context.state(near: change.time),
                  let end = context.state(near: change.time + MatchAnalyzer.transitionDuration),
                  end.time - start.time >= 2 else { continue }

            // 両方の時刻で追跡できている選手の前進距離
            let startPositions = Dictionary(start.ownFieldPlayers.map { ($0.trackID, $0.position) }, uniquingKeysWith: { a, _ in a })
            var movements: [PitchMovement] = []
            var runners = 0
            for player in end.ownFieldPlayers {
                guard let from = startPositions[player.trackID] else { continue }
                movements.append(PitchMovement(from: from, to: player.position))
                let advance = context.setup.attackingCoordinate(of: player.position) - context.setup.attackingCoordinate(of: from)
                if advance >= threshold {
                    runners += 1
                }
            }
            guard movements.count >= max(2, context.setup.format.minimumFieldPlayers / 2) else { continue }

            let isPositive: Bool
            if runners <= 1 {
                isPositive = false
            } else if runners >= 3 {
                isPositive = true
            } else {
                continue
            }

            candidates.append(Candidate(
                rule: .forwardRuns,
                isPositive: isPositive,
                startTime: change.time,
                endTime: end.time,
                phase: .transitionToAttack,
                title: isPositive ? "奪った後に複数人が前へ" : "奪った後に前へ出る選手が少ない",
                evidence: "奪ってから約 \(seconds(end.time - start.time)) で \(meters(threshold)) 以上前進した味方 \(runners) 人（追跡できた \(movements.count) 人中、目安 3 人以上）",
                comment: isPositive
                    ? "奪った瞬間に前へ出る選手が多く、相手の守備が整う前に攻められています。"
                    : "奪った後も選手の位置が変わらず、相手に守備を整える時間を与えています。",
                suggestion: isPositive
                    ? "前へ出た選手へのパスの質とタイミングを合わせ、シュートまで持ち込む形を増やしましょう。"
                    : "奪った瞬間を合図に、ボールより後ろの選手も含めて2〜3人が前へ走り出しましょう。",
                snapshot: context.snapshot(end, highlight: .movements(movements)),
                score: 3 + abs(Double(runners) - 2)
            ))
        }
        return candidates
    }

    // MARK: - Selection

    /// 課題と良い点を、規則が偏らないように選ぶ
    static func select(_ candidates: [Candidate]) -> [Candidate] {
        func pick(_ list: [Candidate], limit: Int) -> [Candidate] {
            var perRule: [CoachRule: Int] = [:]
            var picked: [Candidate] = []
            // まず規則ごとに最上位を1つずつ、残りを重要度順に
            let sorted = list.sorted { $0.score > $1.score }
            for pass in 1...maxScenesPerRule {
                for candidate in sorted where picked.count < limit {
                    guard perRule[candidate.rule, default: 0] < pass,
                          !picked.contains(where: { $0.rule == candidate.rule && $0.startTime == candidate.startTime }) else { continue }
                    perRule[candidate.rule, default: 0] += 1
                    picked.append(candidate)
                }
            }
            return picked
        }
        return pick(candidates.filter { !$0.isPositive }, limit: maxIssues)
            + pick(candidates.filter(\.isPositive), limit: maxPositives)
    }

    // MARK: - Summary

    static func summary(_ context: Context, changes: [PossessionChange]) -> CoachSummary {
        let states = context.states
        let count = Double(max(1, states.count))
        let known = states.filter { $0.possession != nil }
        let ownPossession = known.filter { $0.possession == .own }.count

        func average(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        let shaped = states.filter(context.hasShape)

        return CoachSummary(
            analyzedDuration: Double(states.count) * context.frameInterval,
            ballVisibleRatio: Double(states.filter(\.ballObserved).count) / count,
            ownPossessionRatio: known.isEmpty ? nil : Double(ownPossession) / Double(known.count),
            possessionKnownRatio: Double(known.count) / count,
            averageDepth: average(shaped.map(context.depth)),
            averageWidth: average(shaped.map(context.lateralWidth)),
            averageDepthInDefense: average(shaped.filter { $0.phase == .defense }.map(context.depth)),
            averageWidthInAttack: average(shaped.filter { $0.phase == .attack }.map(context.lateralWidth)),
            ballsLost: changes.filter { $0.to == .opponent }.count,
            ballsWon: changes.filter { $0.to == .own }.count
        )
    }

    static func notes(_ context: Context, analysis: MatchAnalysisResult) -> [String] {
        var notes: [String] = []
        let states = context.states
        if analysis.cameraMovedFrameCount > 0 {
            notes.append("カメラが動いた \(analysis.cameraMovedFrameCount) フレームは座標を求められないため除外しました。")
        }
        if states.isEmpty {
            notes.append("分析できるフレームがありませんでした。コートの4点の指定とカメラの固定を確認してください。")
            return notes
        }
        let ballRatio = Double(states.filter(\.ballObserved).count) / Double(states.count)
        if ballRatio < 0.3 {
            notes.append("ボールが見えていた時間が \(percent(ballRatio)) と少ないため、攻守の局面の判定は限られています。")
        }
        let shapeRatio = Double(states.filter(context.hasShape).count) / Double(states.count)
        if shapeRatio < 0.5 {
            notes.append("自チームの選手が \(context.setup.format.minimumFieldPlayers) 人以上見えていた時間が \(percent(shapeRatio)) のため、チームの形の評価は限られています。")
        }
        if analysis.opponentColor == nil {
            notes.append("相手チームのユニフォームの色を推定できなかったため、チーム分けの精度が低い可能性があります。")
        }
        notes.append("目安は 11人制の一般的な指導基準をコートの大きさで換算したものです。年代やチームの方針に合わせて読み替えてください。")
        return notes
    }

    // MARK: - Formatting

    static func meters(_ value: Double) -> String {
        String(format: "%.0f m", value)
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.1f 秒", value)
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
