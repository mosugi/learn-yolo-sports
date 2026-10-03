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

    static func analyze(frames: [ProcessedFrame], setup: AnalysisSetup) -> MatchAnalysisResult {
        let valid = frames.filter { !$0.cameraMoved }.sorted { $0.timestamp < $1.timestamp }

        // 1. 選手の観測を集める
        var observations: [[Observation]] = []
        for frame in valid {
            var list: [Observation] = []
            for (index, detection) in frame.detections.enumerated() {
                guard detection.inCourt == true, let position = detection.pitchPosition else { continue }
                switch detection.sportsClass {
                case .player?, .goalkeeper?:
                    list.append(Observation(
                        detectionIndex: index,
                        position: position,
                        color: detection.jerseyColor,
                        isGoalkeeper: detection.sportsClass == .goalkeeper
                    ))
                default:
                    continue
                }
            }
            observations.append(list)
        }

        // 2. ユニフォームの色でチームを分ける
        let colors = observations.flatMap { $0.filter { !$0.isGoalkeeper }.compactMap(\.color) }
        let centroids = teamCentroids(colors: colors, ownAnchor: setup.ownColor)

        // 3. 追跡し、追跡ごとに多数決でチームを決める
        var tracks = track(observations: observations, frames: valid)
        for index in tracks.indices {
            for point in tracks[index].points {
                let observation = observations[point.state][point.observation]
                if observation.isGoalkeeper {
                    tracks[index].goalkeeperCount += 1
                } else if let color = observation.color {
                    switch team(of: color, own: centroids.own, opponent: centroids.opponent) {
                    case .own?: tracks[index].ownVotes += 1
                    case .opponent?: tracks[index].opponentVotes += 1
                    case nil: break
                    }
                }
            }
            tracks[index].team = resolvedTeam(of: tracks[index], setup: setup)
        }

        // 4. フレームごとの配置（短い欠損は補間する）
        var ownPlayers = Array(repeating: [TrackedPlayer](), count: valid.count)
        var opponentPlayers = Array(repeating: [TrackedPlayer](), count: valid.count)
        var assignments: [Int: [Int: DetectionAssignment]] = [:]

        for track in tracks {
            let isGoalkeeper = track.goalkeeperCount * 2 > track.points.count
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
            cameraMovedFrameCount: frames.count - valid.count
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

    private static func resolvedTeam(of track: Track, setup: AnalysisSetup) -> TeamSide? {
        // GK は色が違うため、守っているゴールの側で決める
        if track.goalkeeperCount * 2 > track.points.count {
            let meanX = track.points.map { Double($0.position.x) }.reduce(0, +) / Double(track.points.count)
            return setup.defendingTeam(atX: meanX)
        }
        if track.ownVotes > track.opponentVotes { return .own }
        if track.opponentVotes > track.ownVotes { return .opponent }
        return nil
    }

    // MARK: - Tracking

    nonisolated struct Observation {
        let detectionIndex: Int
        let position: CGPoint
        let color: LabColor?
        let isGoalkeeper: Bool
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
        var ownVotes = 0
        var opponentVotes = 0
        var goalkeeperCount = 0
        var team: TeamSide?

        var last: TrackPoint { points[points.count - 1] }
    }

    /// 等速の予測と距離による貪欲な対応付けで、フレーム間の同一人物を結ぶ
    static func track(observations: [[Observation]], frames: [ProcessedFrame]) -> [Track] {
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
                for (observationIndex, observation) in list.enumerated() {
                    let d = distance(predicted, observation.position)
                    if d <= gate {
                        pairs.append((trackIndex, observationIndex, d))
                    }
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
                tracks[pair.track].points.append(TrackPoint(state: state, observation: pair.observation, time: time, position: position))
            }

            for (observationIndex, observation) in list.enumerated() where !usedObservations.contains(observationIndex) {
                tracks.append(Track(
                    id: tracks.count,
                    points: [TrackPoint(state: state, observation: observationIndex, time: time, position: observation.position)]
                ))
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
