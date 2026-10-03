//
//  GoalDetector.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation
import CoreGraphics

/// 得点シーンを見つけてチャプターにする
///
/// ボールがゴールに入った瞬間は、ネットやGK に隠れて見えないことが多い。そこで
/// 「ゴールへの侵入」と「その後のセンターサークルからのキックオフ」を組み合わせて判定する。
/// キックオフは試合の再開でしか起きないため、シュートがバーを越えた場合などの誤判定を減らせる。
nonisolated enum GoalDetector {

    /// ゴールへの侵入からキックオフまでの時間の範囲（秒）
    static let restartDelay: ClosedRange<Double> = 8...150
    /// キックオフとみなすために、ボールが中央で止まっている時間（秒）
    static let kickoffStillTime = 1.0

    static func chapters(
        states: [FrameState],
        changes: [PossessionChange],
        setup: AnalysisSetup,
        trackNumbers: [Int: Int]
    ) -> [MatchChapter] {
        guard let firstTime = states.first?.time else { return [] }

        let entries = goalEntries(states: states, setup: setup)
        let kickoffs = kickoffTimes(states: states, setup: setup)

        var chapters: [MatchChapter] = []
        var usedEntries = Set<Int>()

        for kickoff in kickoffs {
            // キックオフの前の、時間の範囲に入るゴールへの侵入のうち最も新しいもの
            // ただし、その後に試合が続いていた場合（バーを越えたシュートの後のゴールキックなど）は除く
            let candidate = entries.indices.last { index in
                let delay = kickoff - entries[index].time
                return !usedEntries.contains(index) && restartDelay.contains(delay)
                    && !playResumed(after: entries[index], before: kickoff, states: states, setup: setup)
            }

            let eventTime: Double
            let atRightGoal: Bool
            let kind: MatchChapter.Kind
            let note: String
            if let candidate {
                usedEntries.insert(candidate)
                eventTime = entries[candidate].time
                atRightGoal = entries[candidate].atRightGoal
                kind = .goal
                note = "ボールがゴールに入り、\(Int(kickoff - eventTime)) 秒後にセンターサークルから再開"
            } else if let last = lastBallNearGoal(before: kickoff, states: states, setup: setup) {
                // ゴールへの侵入は見えていないが、ゴール前のボールの後にキックオフで再開した
                eventTime = last.time
                atRightGoal = last.atRightGoal
                kind = .probableGoal
                note = "ゴール前でボールを見失った後、\(Int(kickoff - eventTime)) 秒後にセンターサークルから再開"
            } else {
                // 試合開始や後半開始のキックオフ
                continue
            }

            // 右のゴールに入れたのは、右へ攻めるチーム
            let scoringTeam: TeamSide = atRightGoal == setup.ownAttacksRight ? .own : .opponent

            // 得点したチームがボールを持った時点から再生する（長すぎる場合は直前 25 秒）
            let gained = changes.last { $0.to == scoringTeam && $0.time <= eventTime && eventTime - $0.time <= 25 }
            let startTime = max(firstTime, (gained.map { $0.time - 3 } ?? eventTime - 12))

            chapters.append(MatchChapter(
                kind: kind,
                startTime: startTime,
                eventTime: eventTime,
                endTime: eventTime + 6,
                scoringTeam: scoringTeam,
                scorerNumber: scorer(of: scoringTeam, before: eventTime, states: states, trackNumbers: trackNumbers),
                note: note
            ))
        }
        return chapters
    }

    // MARK: - Goal entries

    nonisolated struct GoalEntry {
        let time: Double
        let atRightGoal: Bool
    }

    /// ボールがゴールの枠の中（ゴールラインの外側）に見えた時刻（5 秒以内のものは1回とみなす）
    static func goalEntries(states: [FrameState], setup: AnalysisSetup) -> [GoalEntry] {
        let length = setup.pitchLength
        let halfGoal = setup.format.goalWidth / 2 + 1
        var entries: [GoalEntry] = []

        for state in states where state.ballObserved {
            guard let ball = state.ball else { continue }
            let x = Double(ball.x), y = Double(ball.y)
            guard abs(y - setup.pitchWidth / 2) <= halfGoal else { continue }

            let atRightGoal: Bool
            if x <= 0.3 && x >= -2.5 {
                atRightGoal = false
            } else if x >= length - 0.3 && x <= length + 2.5 {
                atRightGoal = true
            } else {
                continue
            }
            if let last = entries.last, state.time - last.time < 5, last.atRightGoal == atRightGoal { continue }
            entries.append(GoalEntry(time: state.time, atRightGoal: atRightGoal))
        }
        return entries
    }

    // MARK: - Kickoff

    /// ボールがセンターマークで止まり、両チームが自陣にいる状態が続き始めた時刻
    static func kickoffTimes(states: [FrameState], setup: AnalysisSetup) -> [Double] {
        let center = CGPoint(x: setup.pitchLength / 2, y: setup.pitchWidth / 2)
        let radius = max(1.0, 1.5 * setup.lengthScale)

        func isKickoffShape(_ state: FrameState) -> Bool {
            guard let ball = state.ball, MatchAnalyzer.distance(ball, center) <= radius else { return false }
            return isInOwnHalf(state.own, team: .own, setup: setup)
                && isInOwnHalf(state.opponent, team: .opponent, setup: setup)
        }

        var kickoffs: [Double] = []
        var runStart: Double?
        var lastTime = -Double.infinity

        for state in states {
            if isKickoffShape(state) {
                if runStart == nil || state.time - lastTime > 0.6 {
                    runStart = state.time
                }
                lastTime = state.time
                if let start = runStart, state.time - start >= kickoffStillTime {
                    // 同じキックオフを重ねて数えない
                    if kickoffs.last.map({ start - $0 > 20 }) ?? true {
                        kickoffs.append(start)
                    }
                }
            } else if state.time - lastTime > 0.6 {
                runStart = nil
            }
        }
        return kickoffs
    }

    /// 見えている選手の8割以上が自陣にいるか（3人未満なら判定しない）
    private static func isInOwnHalf(_ players: [TrackedPlayer], team: TeamSide, setup: AnalysisSetup) -> Bool {
        guard players.count >= 3 else { return true }
        let half = setup.pitchLength / 2
        // 右へ攻めるチームの自陣は左半分
        let attacksRight = (team == .own) == setup.ownAttacksRight
        let inside = players.filter { player in
            let x = Double(player.position.x)
            return attacksRight ? x <= half + 1 : x >= half - 1
        }.count
        return Double(inside) / Double(players.count) >= 0.8
    }

    // MARK: - Helpers

    /// ゴールへの侵入の後、キックオフまでの間にプレーが続いていたか
    ///
    /// 得点の後は、ボールはゴール付近かセンターサークルへ運ばれる途中にしか見えない。
    /// それ以外の場所でボールが合計 6 秒以上見えていれば、プレーが続いていたとみなす。
    private static func playResumed(after entry: GoalEntry, before kickoff: Double, states: [FrameState], setup: AnalysisSetup) -> Bool {
        let scale = setup.lengthScale
        let center = CGPoint(x: setup.pitchLength / 2, y: setup.pitchWidth / 2)
        let goalLineX = entry.atRightGoal ? setup.pitchLength : 0
        let window = states.filter { $0.ballObserved && $0.time > entry.time + 5 && $0.time < kickoff - 1 }
        guard window.count >= 2 else { return false }

        // 解析したフレームの平均間隔
        let interval = (states[states.count - 1].time - states[0].time) / Double(max(1, states.count - 1))
        let inPlay = window.filter { state in
            guard let ball = state.ball else { return false }
            let nearGoal = abs(Double(ball.x) - goalLineX) <= 16.5 * scale
            let nearCenter = MatchAnalyzer.distance(ball, center) <= 9.15 * scale
            return !nearGoal && !nearCenter
        }
        return Double(inPlay.count) * interval >= 6
    }

    /// キックオフ前に最後にボールが見えた位置が、ゴール前（ペナルティエリアの深さ以内）だった場合のその時刻
    private static func lastBallNearGoal(before kickoff: Double, states: [FrameState], setup: AnalysisSetup) -> GoalEntry? {
        guard let last = states.last(where: { $0.ballObserved && $0.ball != nil && $0.time <= kickoff - restartDelay.lowerBound }),
              kickoff - last.time <= restartDelay.upperBound,
              let ball = last.ball else { return nil }

        let depth = 16.5 * setup.lengthScale
        let x = Double(ball.x)
        let nearCenterLine = abs(Double(ball.y) - setup.pitchWidth / 2) <= setup.pitchWidth * 0.3
        guard nearCenterLine else { return nil }
        if x <= depth { return GoalEntry(time: last.time, atRightGoal: false) }
        if x >= setup.pitchLength - depth { return GoalEntry(time: last.time, atRightGoal: true) }
        return nil
    }

    /// 得点直前にボールに最も近かった、得点したチームの選手の背番号
    private static func scorer(of team: TeamSide, before time: Double, states: [FrameState], trackNumbers: [Int: Int]) -> Int? {
        let window = states.filter { $0.time <= time && $0.time >= time - 3 && $0.ball != nil }
        for state in window.reversed() {
            guard let ball = state.ball else { continue }
            let nearest = state.players(of: team)
                .filter { !$0.isGoalkeeper }
                .min { MatchAnalyzer.distance($0.position, ball) < MatchAnalyzer.distance($1.position, ball) }
            if let nearest, MatchAnalyzer.distance(nearest.position, ball) <= 3 {
                return trackNumbers[nearest.trackID]
            }
        }
        return nil
    }
}
