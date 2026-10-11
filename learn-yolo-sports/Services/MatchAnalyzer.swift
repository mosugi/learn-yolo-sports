//
//  MatchAnalyzer.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation
import CoreGraphics

/// ピッチ上の選手（追跡済み）
nonisolated struct TrackedPlayer {
    let trackID: Int
    let position: CGPoint
    let isGoalkeeper: Bool
}

/// あるフレームでの試合の状態（ピッチ座標、m）
nonisolated struct FrameState {
    let time: Double
    let own: [TrackedPlayer]
    let opponent: [TrackedPlayer]
    let ball: CGPoint?
    /// ボールが実際に検出されたか（false は補間）
    let ballObserved: Bool
    let possession: TeamSide?
    let phase: GamePhase

    func players(of team: TeamSide) -> [TrackedPlayer] {
        team == .own ? own : opponent
    }

    /// 自チームのフィールドプレーヤー
    var ownFieldPlayers: [TrackedPlayer] {
        own.filter { !$0.isGoalkeeper }
    }
}

/// 検出ごとのチーム・追跡 ID の割り当て
nonisolated struct DetectionAssignment {
    let team: TeamSide?
    let trackID: Int
}

/// ボール保持の切り替わり
nonisolated struct PossessionChange {
    let time: Double
    let to: TeamSide
}

nonisolated struct MatchAnalysisResult {
    /// [ProcessedFrame.index: [検出の番号: 割り当て]]
    let assignments: [Int: [Int: DetectionAssignment]]
    let states: [FrameState]
    let possessionChanges: [PossessionChange]
    let opponentColor: LabColor?
    /// カメラが動いたため除外したフレーム数
    let cameraMovedFrameCount: Int
    /// states と同じ順の ProcessedFrame.index
    let stateFrameIndices: [Int]
    /// 追跡 ID ごとの背番号（読み取りの多数決で決まったもの）
    let trackNumbers: [Int: Int]

    /// ProcessedFrame.index に対応する状態
    var statesByFrameIndex: [Int: FrameState] {
        Dictionary(zip(stateFrameIndices, states), uniquingKeysWith: { a, _ in a })
    }
}

/// 検出結果からチーム分類・追跡・ボール保持・局面を求める
nonisolated enum MatchAnalyzer {

    /// 追跡が途切れても同一とみなす最大の間隔（秒）
    static let maxTrackGap = 1.0
    /// ボールの欠損を補間する最大の間隔（秒）
    static let maxBallGap = 1.0
    /// 保持チームが切り替わったと確定するまでの時間（秒）
    static let possessionConfirmTime = 0.6
    /// 誰も触れていないボールを、直前の保持チームのものとみなす時間（秒）
    static let looseBallTime = 2.0
    /// 切り替え局面とみなす時間（秒）
    static let transitionDuration = 3.0
    /// 途切れた追跡をつなぎ直す最大の間隔（秒）
    static let maxStitchGap = 3.0
    /// 追跡の色と食い違うとみなす観測の票の強さ
    static let colorConflictStrength = 0.3
    /// 色が食い違う観測を対応付けるときに足す距離（m）
    static let colorConflictPenalty = 3.0

    static func analyze(frames: [ProcessedFrame], setup: AnalysisSetup) -> MatchAnalysisResult {
        let valid = frames.filter { !$0.cameraMoved }.sorted { $0.timestamp < $1.timestamp }

        // 1. 選手の観測を集める
        var observations: [[Observation]] = []
        for frame in valid {
            var list: [Observation] = []
            for (index, detection) in frame.detections.enumerated() {
                guard detection.inCourt == true, let position = detection.pitchPosition else { continue }
                switch detection.sportsClass {
                case .player?, .goalkeeper?, .referee?:
                    list.append(Observation(
                        detectionIndex: index,
                        position: position,
                        palette: detection.jerseyPalette ?? [],
                        boxHeight: Double(detection.boundingBox.height),
                        isGoalkeeper: detection.sportsClass == .goalkeeper,
                        isReferee: detection.sportsClass == .referee,
                        jerseyNumber: detection.jerseyNumber
                    ))
                default:
                    continue
                }
            }
            observations.append(list)
        }

        // 2. ユニフォームの色でチームを分ける（GK と審判は色が違うため代表色の計算から除く）
        let colors = observations.flatMap { $0.filter { !$0.isGoalkeeper && !$0.isReferee }.compactMap(\.color) }
        let centroids = teamCentroids(colors: colors, ownAnchor: setup.ownColor)
        let votes = observations.map { list in
            list.map { teamVote(palette: $0.palette, own: centroids.own, opponent: centroids.opponent) }
        }

        // 3. 追跡し、追跡ごとに重み付きの多数決でチームを決める
        var tracks = track(observations: observations, votes: votes, frames: valid)

        // 途切れた追跡を、位置・チーム・背番号が矛盾しない範囲でつなぎ直す
        tracks = stitch(tracks)
        for index in tracks.indices {
            tracks[index].team = resolvedTeam(of: tracks[index], setup: setup)
        }
        var trackNumbers: [Int: Int] = [:]
        for track in tracks where track.team == .own {
            if let number = track.jerseyNumber {
                trackNumbers[track.id] = number
            }
        }

        // 4. フレームごとの配置（短い欠損は補間する）
        var ownPlayers = Array(repeating: [TrackedPlayer](), count: valid.count)
        var opponentPlayers = Array(repeating: [TrackedPlayer](), count: valid.count)
        var assignments: [Int: [Int: DetectionAssignment]] = [:]

        for track in tracks {
            let isGoalkeeper = track.isGoalkeeper
            func add(_ position: CGPoint, at state: Int) {
                guard let team = track.team else { return }
                let player = TrackedPlayer(trackID: track.id, position: position, isGoalkeeper: isGoalkeeper)
                if team == .own {
                    ownPlayers[state].append(player)
                } else {
                    opponentPlayers[state].append(player)
                }
            }

            for (offset, point) in track.points.enumerated() {
                let observation = observations[point.state][point.observation]
                add(observation.position, at: point.state)
                assignments[valid[point.state].index, default: [:]][observation.detectionIndex] =
                    DetectionAssignment(team: track.team, trackID: track.id)

                guard offset + 1 < track.points.count else { continue }
                let next = track.points[offset + 1]
                guard next.state - point.state > 1, next.time - point.time <= maxTrackGap else { continue }
                let nextPosition = observations[next.state][next.observation].position
                for state in (point.state + 1)..<next.state {
                    let ratio = (valid[state].timestamp - point.time) / (next.time - point.time)
                    add(interpolate(observation.position, nextPosition, ratio), at: state)
                }
            }
        }

        // 5. ボールの位置
        let (balls, observed) = ballPositions(frames: valid)

        // 6. ボール保持と局面
        let controlRadius = setup.format == .futsal ? 1.5 : 2.0
        var states: [FrameState] = []
        var changes: [PossessionChange] = []

        var confirmed: TeamSide?
        var pending: TeamSide?
        var pendingSince = 0.0
        var lastBallTime = -Double.infinity
        var lastControlTime = -Double.infinity
        var lastChange: PossessionChange?

        for (state, frame) in valid.enumerated() {
            let time = frame.timestamp

            if let ball = balls[state] {
                lastBallTime = time
                // ボールに最も近い選手のチーム
                var nearestTeam: TeamSide?
                var nearestDistance = Double.infinity
                for (team, players) in [(TeamSide.own, ownPlayers[state]), (TeamSide.opponent, opponentPlayers[state])] {
                    for player in players {
                        let d = distance(player.position, ball)
                        if d < nearestDistance {
                            nearestDistance = d
                            nearestTeam = team
                        }
                    }
                }

                if let candidate = nearestTeam, nearestDistance <= controlRadius {
                    lastControlTime = time
                    if candidate == confirmed {
                        pending = nil
                    } else if pending == candidate {
                        if time - pendingSince >= possessionConfirmTime - 1e-6 {
                            if let previous = confirmed, previous != candidate {
                                let change = PossessionChange(time: pendingSince, to: candidate)
                                changes.append(change)
                                lastChange = change
                            }
                            confirmed = candidate
                            pending = nil
                        }
                    } else {
                        pending = candidate
                        pendingSince = time
                    }
                } else if time - lastControlTime > looseBallTime {
                    confirmed = nil
                    pending = nil
                }
            } else if time - lastBallTime > maxBallGap {
                confirmed = nil
                pending = nil
            }

            let phase: GamePhase
            switch confirmed {
            case nil:
                phase = .unknown
            case .own?:
                if let lastChange, lastChange.to == .own, time - lastChange.time <= transitionDuration {
                    phase = .transitionToAttack
                } else {
                    phase = .attack
                }
            case .opponent?:
                if let lastChange, lastChange.to == .opponent, time - lastChange.time <= transitionDuration {
                    phase = .transitionToDefense
                } else {
                    phase = .defense
                }
            }

            states.append(FrameState(
                time: time,
                own: ownPlayers[state],
                opponent: opponentPlayers[state],
                ball: balls[state],
                ballObserved: observed[state],
                possession: confirmed,
                phase: phase
            ))
        }

        return MatchAnalysisResult(
            assignments: assignments,
            states: states,
            possessionChanges: changes,
            opponentColor: centroids.opponent,
            cameraMovedFrameCount: frames.count - valid.count,
            stateFrameIndices: valid.map(\.index),
            trackNumbers: trackNumbers
        )
    }

    // MARK: - Team colors

    /// 自チームの色を起点に、2つのチームの代表色を求める（2クラスの k-means）
    static func teamCentroids(colors: [LabColor], ownAnchor: LabColor) -> (own: LabColor, opponent: LabColor?) {
        guard colors.count >= 4 else { return (ownAnchor, nil) }

        // 自チームの色から遠い側の平均を相手の初期値にする
        let sortedDistances = colors.map { $0.distance(to: ownAnchor) }.sorted()
        let threshold = sortedDistances[Int(Double(sortedDistances.count - 1) * 0.6)]
        guard var opponent = LabColor.mean(colors.filter { $0.distance(to: ownAnchor) > threshold }),
              opponent.distance(to: ownAnchor) > 15 else { return (ownAnchor, nil) }

        var own = ownAnchor
        for _ in 0..<10 {
            var ownMembers: [LabColor] = []
            var opponentMembers: [LabColor] = []
            for color in colors {
                if color.distance(to: own) <= color.distance(to: opponent) {
                    ownMembers.append(color)
                } else {
                    opponentMembers.append(color)
                }
            }
            // タップした色から離れすぎないよう、自チームの代表色は指定色と半々にする
            if let mean = LabColor.mean(ownMembers) {
                own = ownAnchor.blended(with: mean, ratio: 0.5)
            }
            if let mean = LabColor.mean(opponentMembers) {
                opponent = mean
            }
        }
        return (own, opponent)
    }

    /// 色からチームを判定する（どちらとも言えない場合は nil）
    static func team(of color: LabColor, own: LabColor, opponent: LabColor?) -> TeamSide? {
        let ownDistance = color.distance(to: own)
        guard let opponent else {
            return ownDistance < 25 ? .own : .opponent
        }
        let opponentDistance = color.distance(to: opponent)
        if min(ownDistance, opponentDistance) > 60 { return nil }
        if abs(ownDistance - opponentDistance) < 4 { return nil }
        return ownDistance < opponentDistance ? .own : .opponent
    }

    /// ユニフォームの色のパレットから、どちらのチームらしいかを求める
    ///
    /// 色ごとに近いチームへ「割合 x チームの色との近さ」を足し、差を票の強さ（0〜1）にする。
    /// 肌やパンツのように、どちらかのチームに少し近いだけの色はほとんど数えない。
    /// 白・灰・黒の画素は背景のフェンスやネット、ラインと区別できないため、相手が有彩色のチームなら
    /// さらに重みを半分にする。これで、遠くの小さな選手に背景の灰色が混ざっても、有彩色の
    /// ユニフォームを見落としにくくなる（判定できないときは票を入れない）。
    static func teamVote(palette: [WeightedColor], own: LabColor, opponent: LabColor?) -> TeamVote? {
        guard let dominant = palette.first?.color else { return nil }
        guard let opponent else {
            return team(of: dominant, own: own, opponent: nil).map { TeamVote(team: $0, strength: 1) }
        }

        var ownSupport = 0.0
        var opponentSupport = 0.0
        for entry in palette {
            let ownDistance = entry.color.distance(to: own)
            let opponentDistance = entry.color.distance(to: opponent)
            let nearest = min(ownDistance, opponentDistance)
            // どちらのチームの色からも遠い色（肌、パンツ、芝の影など）は数えない
            guard nearest < paletteMatchRadius, abs(ownDistance - opponentDistance) >= 4 else { continue }
            let isOwn = ownDistance < opponentDistance
            let otherTeamColor = isOwn ? opponent : own
            var weight = entry.weight * (1 - nearest / paletteMatchRadius)
            if entry.color.chroma < achromaticChroma && otherTeamColor.chroma >= achromaticChroma {
                weight *= 0.5
            }
            if isOwn {
                ownSupport += weight
            } else {
                opponentSupport += weight
            }
        }

        let strength = abs(ownSupport - opponentSupport)
        guard max(ownSupport, opponentSupport) >= 0.1, strength >= 0.06 else { return nil }
        return TeamVote(team: ownSupport > opponentSupport ? .own : .opponent, strength: min(1, strength))
    }

    /// これより彩度が低い色は、白・灰・黒とみなす
    static let achromaticChroma = 12.0
    /// チームの色とみなす色の差の上限
    static let paletteMatchRadius = 40.0
    /// 審判と判定された人を、チームの選手に戻す票の強さ
    static let refereeOverrideStrength = 0.35

    private static func resolvedTeam(of track: Track, setup: AnalysisSetup) -> TeamSide? {
        // 審判の判定が色の票を上回る追跡は審判のまま（チームに入れない）
        if track.isReferee { return nil }
        // GK は色が違うため、守っているゴールの側で決める
        if track.isGoalkeeper {
            let meanX = track.points.map { Double($0.position.x) }.reduce(0, +) / Double(track.points.count)
            return setup.defendingTeam(atX: meanX)
        }
        return track.colorTeam
    }

    // MARK: - Tracking

    nonisolated struct Observation {
        let detectionIndex: Int
        let position: CGPoint
        let palette: [WeightedColor]
        /// 枠の高さ（画像の高さに対する割合）。小さく写るほど色が当てにならない
        let boxHeight: Double
        let isGoalkeeper: Bool
        let isReferee: Bool
        let jerseyNumber: Int?

        var color: LabColor? {
            palette.first?.color
        }

        /// 票の重み。画像の高さの 12% 未満に写る選手は、小さいほど軽くする
        var voteWeight: Double {
            min(1, max(0.3, boxHeight / 0.12))
        }
    }

    /// 1回の観測から見たチーム
    nonisolated struct TeamVote {
        let team: TeamSide
        /// 0〜1
        let strength: Double
    }

    nonisolated struct TrackPoint {
        /// valid フレームの番号
        let state: Int
        /// そのフレームの観測の番号
        let observation: Int
        let time: Double
        let position: CGPoint
    }

    nonisolated struct Track {
        let id: Int
        var points: [TrackPoint]
        var velocityX = 0.0
        var velocityY = 0.0
        var ownVotes = 0.0
        var opponentVotes = 0.0
        /// 審判と判定され、色でもチームと言い切れなかった観測の重み
        var refereeVotes = 0.0
        var goalkeeperCount = 0
        var numberVotes: [Int: Int] = [:]
        var team: TeamSide?

        var first: TrackPoint { points[0] }
        var last: TrackPoint { points[points.count - 1] }

        /// 色の重み付き多数決によるチーム（GK を除く）
        var colorTeam: TeamSide? {
            if ownVotes > opponentVotes { return .own }
            if opponentVotes > ownVotes { return .opponent }
            return nil
        }

        /// 色の票の差がはっきりしているときのチーム（追跡の対応付けに使う）
        var confidentColorTeam: TeamSide? {
            guard abs(ownVotes - opponentVotes) >= 1 else { return nil }
            return colorTeam
        }

        var isGoalkeeper: Bool {
            goalkeeperCount * 2 > points.count
        }

        var isReferee: Bool {
            refereeVotes > ownVotes + opponentVotes
        }

        /// 観測を1つ加え、チーム・GK・背番号の票を数える
        mutating func add(_ point: TrackPoint, observation: Observation, vote: TeamVote?) {
            points.append(point)
            if observation.isGoalkeeper {
                goalkeeperCount += 1
            } else if observation.isReferee {
                // 審判と判定されても、色がはっきり一方のチームなら選手として数える
                if let vote, vote.strength >= MatchAnalyzer.refereeOverrideStrength {
                    addVote(vote, weight: observation.voteWeight)
                } else {
                    refereeVotes += observation.voteWeight
                }
            } else if let vote {
                addVote(vote, weight: observation.voteWeight)
            }
            if let number = observation.jerseyNumber {
                numberVotes[number, default: 0] += 1
            }
        }

        private mutating func addVote(_ vote: TeamVote, weight: Double) {
            switch vote.team {
            case .own: ownVotes += vote.strength * weight
            case .opponent: opponentVotes += vote.strength * weight
            }
        }

        /// 読み取りの過半数を占める背番号（2回以上読めたもの）
        var jerseyNumber: Int? {
            let total = numberVotes.values.reduce(0, +)
            guard let best = numberVotes.max(by: { $0.value < $1.value }),
                  best.value >= 2, Double(best.value) / Double(total) >= 0.6 else { return nil }
            return best.key
        }
    }

    /// 追跡が途切れた後に始まった追跡のうち、つながりうるものを1本にまとめる
    static func stitch(_ tracks: [Track]) -> [Track] {
        var links: [(from: Int, to: Int, distance: Double)] = []
        // 開始時刻順に並べ、終了直後に始まる追跡だけを調べる
        let byStart = tracks.indices.sorted { tracks[$0].first.time < tracks[$1].first.time }
        let startTimes = byStart.map { tracks[$0].first.time }
        for (a, earlier) in tracks.enumerated() {
            var lower = 0, upper = startTimes.count
            while lower < upper {
                let mid = (lower + upper) / 2
                if startTimes[mid] <= earlier.last.time { lower = mid + 1 } else { upper = mid }
            }
            for k in lower..<startTimes.count {
                let gap = startTimes[k] - earlier.last.time
                guard gap <= maxStitchGap else { break }
                let b = byStart[k]
                let later = tracks[b]
                guard gap > 0, a != b else { continue }
                let d = distance(earlier.last.position, later.first.position)
                guard d <= 2 + 7 * gap else { continue }
                // チームと背番号が食い違うものはつながない
                if let x = earlier.colorTeam, let y = later.colorTeam, x != y { continue }
                if let x = earlier.jerseyNumber, let y = later.jerseyNumber, x != y { continue }
                if earlier.isGoalkeeper != later.isGoalkeeper { continue }
                if earlier.isReferee != later.isReferee { continue }
                links.append((a, b, d))
            }
        }
        links.sort { $0.distance < $1.distance }

        var next: [Int: Int] = [:]
        var previous: [Int: Int] = [:]
        for link in links where next[link.from] == nil && previous[link.to] == nil {
            next[link.from] = link.to
            previous[link.to] = link.from
        }

        var merged: [Track] = []
        for start in tracks.indices where previous[start] == nil {
            var track = Track(id: merged.count, points: [])
            var current: Int? = start
            while let index = current {
                let part = tracks[index]
                track.points += part.points
                track.ownVotes += part.ownVotes
                track.opponentVotes += part.opponentVotes
                track.refereeVotes += part.refereeVotes
                track.goalkeeperCount += part.goalkeeperCount
                track.numberVotes.merge(part.numberVotes, uniquingKeysWith: +)
                current = next[index]
            }
            merged.append(track)
        }
        return merged
    }

    /// 等速の予測と距離による貪欲な対応付けで、フレーム間の同一人物を結ぶ
    ///
    /// 交差や密集で追跡が相手チームの選手に乗り移らないよう、それまでの色の票とはっきり食い違う
    /// 観測には距離の罰則を加える。
    static func track(observations: [[Observation]], votes: [[TeamVote?]], frames: [ProcessedFrame]) -> [Track] {
        var tracks: [Track] = []
        var active: [Int] = []

        for (state, list) in observations.enumerated() {
            let time = frames[state].timestamp
            active = active.filter { time - tracks[$0].last.time <= maxTrackGap }

            var pairs: [(track: Int, observation: Int, distance: Double)] = []
            for trackIndex in active {
                let track = tracks[trackIndex]
                let dt = time - track.last.time
                let predicted = CGPoint(
                    x: Double(track.last.position.x) + track.velocityX * dt,
                    y: Double(track.last.position.y) + track.velocityY * dt
                )
                // 選手の最高速度（約 7 m/s）と座標の誤差を見込んだ範囲
                let gate = 1.5 + 7 * dt
                let trackTeam = track.confidentColorTeam
                for (observationIndex, observation) in list.enumerated() {
                    var d = distance(predicted, observation.position)
                    guard d <= gate else { continue }
                    if let trackTeam, let vote = votes[state][observationIndex],
                       vote.strength >= colorConflictStrength, vote.team != trackTeam {
                        d += colorConflictPenalty
                    }
                    pairs.append((trackIndex, observationIndex, d))
                }
            }
            pairs.sort { $0.distance < $1.distance }

            var usedTracks = Set<Int>()
            var usedObservations = Set<Int>()
            for pair in pairs where !usedTracks.contains(pair.track) && !usedObservations.contains(pair.observation) {
                usedTracks.insert(pair.track)
                usedObservations.insert(pair.observation)

                let position = list[pair.observation].position
                let last = tracks[pair.track].last
                let dt = time - last.time
                if dt > 0 {
                    let speedLimit = 10.0
                    let vx = max(-speedLimit, min(speedLimit, Double(position.x - last.position.x) / dt))
                    let vy = max(-speedLimit, min(speedLimit, Double(position.y - last.position.y) / dt))
                    let isFirstStep = tracks[pair.track].points.count == 1
                    tracks[pair.track].velocityX = isFirstStep ? vx : (tracks[pair.track].velocityX + vx) / 2
                    tracks[pair.track].velocityY = isFirstStep ? vy : (tracks[pair.track].velocityY + vy) / 2
                }
                tracks[pair.track].add(
                    TrackPoint(state: state, observation: pair.observation, time: time, position: position),
                    observation: list[pair.observation],
                    vote: votes[state][pair.observation]
                )
            }

            for (observationIndex, observation) in list.enumerated() where !usedObservations.contains(observationIndex) {
                var track = Track(id: tracks.count, points: [])
                track.add(
                    TrackPoint(state: state, observation: observationIndex, time: time, position: observation.position),
                    observation: observation,
                    vote: votes[state][observationIndex]
                )
                tracks.append(track)
                active.append(tracks.count - 1)
            }
        }
        return tracks
    }

    // MARK: - Ball

    /// フレームごとのボール位置（短い欠損は補間）と、実際に検出されたか
    static func ballPositions(frames: [ProcessedFrame]) -> ([CGPoint?], [Bool]) {
        var positions = [CGPoint?](repeating: nil, count: frames.count)
        var lastTime = -Double.infinity
        var lastPosition: CGPoint?

        for (state, frame) in frames.enumerated() {
            let candidates = frame.detections.filter {
                $0.sportsClass == .ball && $0.inCourt == true && $0.pitchPosition != nil
            }
            guard !candidates.isEmpty else { continue }

            var chosen: ProcessedDetection?
            if let lastPosition, frame.timestamp - lastTime <= maxBallGap {
                // 直前の位置から届く範囲（ボールの速度は最大 30 m/s 程度）で最も近いもの
                let gate = 2 + 30 * (frame.timestamp - lastTime)
                chosen = candidates
                    .map { ($0, distance($0.pitchPosition!, lastPosition)) }
                    .filter { $0.1 <= gate }
                    .min { $0.1 < $1.1 }?.0
                if chosen == nil {
                    chosen = candidates.filter { $0.confidence >= 0.5 }.max { $0.confidence < $1.confidence }
                }
            } else {
                chosen = candidates.max { $0.confidence < $1.confidence }
            }

            if let chosen, let position = chosen.pitchPosition {
                positions[state] = position
                lastPosition = position
                lastTime = frame.timestamp
            }
        }

        let observed = positions.map { $0 != nil }

        // 短い欠損を線形補間する
        var previous: Int?
        for state in positions.indices where positions[state] != nil {
            if let previous, state - previous > 1,
               frames[state].timestamp - frames[previous].timestamp <= maxBallGap,
               let a = positions[previous], let b = positions[state] {
                for missing in (previous + 1)..<state {
                    let ratio = (frames[missing].timestamp - frames[previous].timestamp)
                        / (frames[state].timestamp - frames[previous].timestamp)
                    positions[missing] = interpolate(a, b, ratio)
                }
            }
            previous = state
        }
        return (positions, observed)
    }

    // MARK: - Helpers

    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(Double(a.x - b.x), Double(a.y - b.y))
    }

    static func interpolate(_ a: CGPoint, _ b: CGPoint, _ ratio: Double) -> CGPoint {
        CGPoint(
            x: Double(a.x) + (Double(b.x) - Double(a.x)) * ratio,
            y: Double(a.y) + (Double(b.y) - Double(a.y)) * ratio
        )
    }
}
