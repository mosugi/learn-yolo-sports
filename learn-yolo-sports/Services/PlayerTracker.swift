//
//  PlayerTracker.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation
import CoreGraphics

/// 追跡と選手の識別の結果
nonisolated struct PlayerTrackingResult {
    /// [フレームの番号（frames の添字）: [検出の番号: 割り当て]]
    let assignments: [Int: [Int: Assignment]]
    let teams: [TeamInfo]?
    let players: [PlayerIdentity]

    nonisolated struct Assignment {
        let trackID: Int
        let team: Int?
        let playerID: Int?
    }

    /// 割り当てをフレームに書き込む（審判と判定されたが色でチームが決まった人は選手に戻す）
    func apply(to frames: inout [SavedFrame]) {
        for frameIndex in frames.indices {
            let frameAssignments = assignments[frameIndex] ?? [:]
            frames[frameIndex].detections = frames[frameIndex].detections.enumerated().map { index, detection in
                var updated = detection
                let assignment = frameAssignments[index]
                updated.trackID = assignment?.trackID
                updated.team = assignment?.team
                updated.playerID = assignment?.playerID
                if detection.label == SportsClass.referee.rawValue, assignment?.team != nil {
                    updated = SavedDetection(
                        label: SportsClass.player.rawValue,
                        confidence: updated.confidence,
                        boundingBox: updated.boundingBox,
                        jerseyPalette: updated.jerseyPalette,
                        inCourt: updated.inCourt,
                        team: updated.team,
                        trackID: updated.trackID,
                        playerID: updated.playerID,
                        jerseyNumber: updated.jerseyNumber
                    )
                }
                return updated
            }
        }
    }
}

/// フレーム間で同じ人物を結び、チームと背番号を多数決で決めて、選手ごとに一意の呼び名を付ける
///
/// コートの設定がないため、位置は画面上の足元の位置にカメラの累積の移動量を足したもので表す。
/// 距離は写っている人の身長（枠の高さ）を単位にして、遠近で人の大きさが変わっても同じ基準で比べる。
nonisolated enum PlayerTracker {

    /// 追跡が途切れても同一とみなす最大の間隔（秒）
    static let maxTrackGap = 1.5
    /// 途切れた追跡をつなぎ直す最大の間隔（秒）
    static let maxStitchGap = 5.0
    /// 1秒あたりに動ける距離（身長単位。約 7 m/s）
    static let maxSpeed = 4.0
    /// 位置の誤差を見込んだ余裕（身長単位）
    static let positionTolerance = 1.0
    /// 追跡の色と食い違うとみなす観測の票の強さ
    static let colorConflictStrength = 0.3
    /// 色が食い違う観測を対応付けるときに足す距離（身長単位）
    static let colorConflictPenalty = 1.5
    /// 背番号が読めなかった選手に記号を付ける最短の写っていた時間（秒）
    ///
    /// カメラが動くと、画面外に出て戻った選手は別の追跡になる。短い断片にまで記号を付けると
    /// 呼び名が増えすぎるため、ある程度続けて写っていた選手だけにする（他はチームの色だけで表示する）。
    static let minimumLetteredDuration = 5.0

    /// - Parameters:
    ///   - frames: 時刻順のフレーム（検出は正規化座標）
    ///   - aspectRatio: 画像の幅 / 高さ
    static func analyze(frames: [SavedFrame], aspectRatio: Double) -> PlayerTrackingResult {
        let aspect = aspectRatio > 0 ? aspectRatio : 16.0 / 9.0

        // 1. 人の観測を集める（コート外は除く）。画面が切り替わったら区間を分ける
        var observations: [[Observation]] = []
        var sections: [Int] = []
        var section = 0
        for (index, frame) in frames.enumerated() {
            if index > 0, frame.sceneCut == true { section += 1 }
            sections.append(section)
            let offset = frame.cameraOffset ?? .zero
            var list: [Observation] = []
            for (detectionIndex, detection) in frame.detections.enumerated() {
                guard !detection.isExcluded, let sportsClass = SportsClass(rawValue: detection.label), sportsClass != .ball else { continue }
                let foot = detection.footPoint
                list.append(Observation(
                    detectionIndex: detectionIndex,
                    // 横長の画面で縦横の縮尺をそろえるため、x は画面の高さを 1 とした単位にする
                    position: CGPoint(x: (foot.x + offset.x) * aspect, y: foot.y + offset.y),
                    screenX: Double(foot.x),
                    height: max(0.02, Double(detection.boundingBox.height)),
                    palette: detection.jerseyPalette ?? [],
                    isGoalkeeper: sportsClass == .goalkeeper,
                    isReferee: sportsClass == .referee,
                    jerseyNumber: detection.jerseyNumber
                ))
            }
            observations.append(list)
        }

        // 2. ユニフォームの色で2チームの代表色を求める（GK と審判は色が違うため除く）
        let colors = observations.flatMap { $0.filter { !$0.isGoalkeeper && !$0.isReferee }.compactMap(\.color) }
        let classified = TeamClassifier.classify(colors: colors)
        let votes = observations.map { list in
            list.map { observation in classified.flatMap { teamVote(palette: observation.palette, centroids: $0.centroids) } }
        }

        // 3. 追跡し、途切れた追跡をつなぎ直して、追跡ごとにチームを決める
        var tracks = track(observations: observations, votes: votes, frames: frames, sections: sections)
        tracks = stitch(tracks, sections: sections)
        for index in tracks.indices {
            tracks[index].team = (tracks[index].isGoalkeeper || tracks[index].isReferee) ? nil : tracks[index].colorTeam
        }

        // 4. 選手ごとに一意の呼び名を付ける
        let (players, playerOfTrack) = identify(tracks, frames: frames, observations: observations)

        var assignments: [Int: [Int: PlayerTrackingResult.Assignment]] = [:]
        for track in tracks {
            for point in track.points {
                let observation = observations[point.frame][point.observation]
                assignments[point.frame, default: [:]][observation.detectionIndex] = PlayerTrackingResult.Assignment(
                    trackID: track.id,
                    team: track.team,
                    playerID: playerOfTrack[track.id]
                )
            }
        }

        return PlayerTrackingResult(assignments: assignments, teams: classified?.teams, players: players)
    }

    // MARK: - Identity

    /// 追跡に背番号・記号を割り当てる
    ///
    /// - 同じチーム・同じ背番号の追跡は、時間が重ならなければ同じ選手（つなぎ直せなかった追跡）とみなす。
    /// - 時間が重なる場合は、背番号の票が多い方だけをその背番号にし、残りは記号で呼ぶ。
    /// - 記号は登場順に A, B, C… と付け、チームをまたいでも重複させない。
    private static func identify(_ tracks: [Track], frames: [SavedFrame], observations: [[Observation]]) -> ([PlayerIdentity], [Int: Int]) {
        var players: [PlayerIdentity] = []
        var playerOfTrack: [Int: Int] = [:]

        func duration(_ track: Track) -> Double { track.last.time - track.first.time }
        func overlaps(_ a: Track, _ b: Track) -> Bool {
            a.first.time <= b.last.time && b.first.time <= a.last.time
        }
        func makeIdentity(_ members: [Track], team: Int?, number: Int?, letter: String?, isGoalkeeper: Bool) {
            let id = players.count
            players.append(PlayerIdentity(
                id: id,
                team: team,
                jerseyNumber: number,
                letter: letter,
                isGoalkeeper: isGoalkeeper,
                firstSeen: members.map(\.first.time).min() ?? 0,
                lastSeen: members.map(\.last.time).max() ?? 0,
                frameCount: members.map(\.points.count).reduce(0, +)
            ))
            for member in members {
                playerOfTrack[member.id] = id
            }
        }

        // 背番号の付いた追跡を、票の多い順に (チーム, 背番号) へ割り当てる
        var numbered: [String: [Track]] = [:]
        var unnumbered: [Track] = []
        let fieldTracks = tracks.filter { !$0.isGoalkeeper && !$0.isReferee && $0.team != nil }
        for track in fieldTracks.sorted(by: { $0.jerseyNumberVotes > $1.jerseyNumberVotes }) {
            guard let number = track.jerseyNumber, let team = track.team else {
                unnumbered.append(track)
                continue
            }
            let key = "\(team)-\(number)"
            if numbered[key, default: []].contains(where: { overlaps($0, track) }) {
                unnumbered.append(track)
            } else {
                numbered[key, default: []].append(track)
            }
        }
        for members in numbered.values.sorted(by: { $0.map(\.first.time).min()! < $1.map(\.first.time).min()! }) {
            makeIdentity(members, team: members[0].team, number: members[0].jerseyNumber, letter: nil, isGoalkeeper: false)
        }

        // 背番号のない追跡は、ある程度の時間写っていたものだけ記号で呼ぶ
        var letterIndex = 0
        for track in unnumbered.sorted(by: { $0.first.time < $1.first.time }) where duration(track) >= minimumLetteredDuration {
            makeIdentity([track], team: track.team, number: nil, letter: letterName(letterIndex), isGoalkeeper: false)
            letterIndex += 1
        }

        // GK は画面の左右で呼び分ける（両方のゴール前が同時に写ることは少ないため）
        let goalkeepers = tracks.filter { $0.isGoalkeeper && duration($0) >= 1 }
        var sides: [String: [Track]] = [:]
        for track in goalkeepers {
            let xs = track.points.map { observations[$0.frame][$0.observation].screenX }
            let meanX = xs.reduce(0, +) / Double(max(1, xs.count))
            sides[meanX < 0.5 ? "左" : "右", default: []].append(track)
        }
        for side in ["左", "右"] {
            guard let members = sides[side] else { continue }
            makeIdentity(members, team: nil, number: members.compactMap(\.jerseyNumber).first, letter: side, isGoalkeeper: true)
        }

        return (players, playerOfTrack)
    }

    /// 0 → A, 25 → Z, 26 → AA
    static func letterName(_ index: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var value = index
        var name = ""
        repeat {
            name = String(letters[value % 26]) + name
            value = value / 26 - 1
        } while value >= 0
        return name
    }

    // MARK: - Team votes

    /// これより彩度が低い色は、白・灰・黒とみなす
    static let achromaticChroma = 12.0
    /// チームの色とみなす色の差の上限
    static let paletteMatchRadius = 40.0
    /// 審判と判定された人を、チームの選手に戻す票の強さ
    static let refereeOverrideStrength = 0.35

    /// ユニフォームの色のパレットから、どちらのチームらしいかを求める
    ///
    /// 色ごとに近いチームへ「割合 x チームの色との近さ」を足し、差を票の強さ（0〜1）にする。
    /// 肌やパンツのように、どちらかのチームに少し近いだけの色はほとんど数えない。
    /// 白・灰・黒の画素は背景のフェンスやネット、ラインと区別できないため、相手が有彩色のチームなら
    /// さらに重みを半分にする（判定できないときは票を入れない）。
    static func teamVote(palette: [WeightedColor], centroids: [LabColor]) -> TeamVote? {
        guard centroids.count == 2, !palette.isEmpty else { return nil }

        var support = [0.0, 0.0]
        for entry in palette {
            let distances = centroids.map { entry.color.distance(to: $0) }
            let nearest = min(distances[0], distances[1])
            // どちらのチームの色からも遠い色（肌、パンツ、芝の影など）は数えない
            guard nearest < paletteMatchRadius, abs(distances[0] - distances[1]) >= 4 else { continue }
            let team = distances[0] < distances[1] ? 0 : 1
            var weight = entry.weight * (1 - nearest / paletteMatchRadius)
            if entry.color.chroma < achromaticChroma && centroids[1 - team].chroma >= achromaticChroma {
                weight *= 0.5
            }
            support[team] += weight
        }

        let strength = abs(support[0] - support[1])
        guard max(support[0], support[1]) >= 0.1, strength >= 0.06 else { return nil }
        return TeamVote(team: support[0] > support[1] ? 0 : 1, strength: min(1, strength))
    }

    // MARK: - Tracking

    nonisolated struct Observation {
        let detectionIndex: Int
        /// 動画全体で共通の位置（画面の高さ = 1）
        let position: CGPoint
        /// 画面上の足元の x（0〜1）
        let screenX: Double
        /// 枠の高さ（画像の高さに対する割合）
        let height: Double
        let palette: [WeightedColor]
        let isGoalkeeper: Bool
        let isReferee: Bool
        let jerseyNumber: Int?

        /// 代表色（チームの代表色の計算に使う）。平均すると赤がピンク、白が灰色に寄るため、最も広い色を使う
        var color: LabColor? {
            palette.first?.color
        }

        /// 票の重み。画像の高さの 12% 未満に写る選手は、小さいほど軽くする
        var voteWeight: Double {
            min(1, max(0.3, height / 0.12))
        }
    }

    /// 1回の観測から見たチーム
    nonisolated struct TeamVote {
        let team: Int
        /// 0〜1
        let strength: Double
    }

    nonisolated struct TrackPoint {
        /// frames の添字
        let frame: Int
        /// そのフレームの観測の番号
        let observation: Int
        let time: Double
        let position: CGPoint
        let height: Double
    }

    nonisolated struct Track {
        let id: Int
        var points: [TrackPoint]
        var velocityX = 0.0
        var velocityY = 0.0
        var teamVotes = [0.0, 0.0]
        /// 審判と判定され、色でもチームと言い切れなかった観測の重み
        var refereeVotes = 0.0
        /// 審判と判定された観測の数
        var refereeCount = 0
        var goalkeeperCount = 0
        var numberVotes: [Int: Int] = [:]
        var team: Int?

        var first: TrackPoint { points[0] }
        var last: TrackPoint { points[points.count - 1] }

        /// 色の重み付き多数決によるチーム（GK を除く）
        var colorTeam: Int? {
            if teamVotes[0] > teamVotes[1] { return 0 }
            if teamVotes[1] > teamVotes[0] { return 1 }
            return nil
        }

        /// 色の票の差がはっきりしているときのチーム（追跡の対応付けに使う）
        var confidentColorTeam: Int? {
            guard abs(teamVotes[0] - teamVotes[1]) >= 1 else { return nil }
            return colorTeam
        }

        var isGoalkeeper: Bool {
            goalkeeperCount * 2 > points.count
        }

        /// 過半数の観測で審判と判定されたか
        var isMostlyReferee: Bool {
            refereeCount * 2 > points.count
        }

        /// 審判として扱うか（過半数が審判の判定で、色の票でもチームと言い切れない）
        var isReferee: Bool {
            isMostlyReferee && refereeVotes > teamVotes[0] + teamVotes[1]
        }

        /// 観測を1つ加え、チーム・GK・背番号の票を数える
        mutating func add(_ point: TrackPoint, observation: Observation, vote: TeamVote?) {
            points.append(point)
            if observation.isGoalkeeper {
                goalkeeperCount += 1
            } else if observation.isReferee {
                refereeCount += 1
                // 審判と判定されても、色がはっきり一方のチームなら選手として数える
                if let vote, vote.strength >= PlayerTracker.refereeOverrideStrength {
                    teamVotes[vote.team] += vote.strength * observation.voteWeight
                } else {
                    refereeVotes += observation.voteWeight
                }
            } else if let vote {
                teamVotes[vote.team] += vote.strength * observation.voteWeight
            }
            if let number = observation.jerseyNumber {
                numberVotes[number, default: 0] += 1
            }
        }

        /// 読み取りの過半数を占める背番号（2回以上読めたもの）
        var jerseyNumber: Int? {
            let total = numberVotes.values.reduce(0, +)
            guard let best = numberVotes.max(by: { $0.value < $1.value }),
                  best.value >= 2, Double(best.value) / Double(total) >= 0.6 else { return nil }
            return best.key
        }

        /// 決まった背番号の票の数（重なる追跡のどちらを優先するかに使う）
        var jerseyNumberVotes: Int {
            jerseyNumber.flatMap { numberVotes[$0] } ?? 0
        }
    }

    /// 2つの位置の距離（身長単位）
    private static func distance(_ a: CGPoint, _ b: CGPoint, height: Double) -> Double {
        hypot(Double(a.x - b.x), Double(a.y - b.y)) / height
    }

    /// 等速の予測と距離による貪欲な対応付けで、フレーム間の同一人物を結ぶ
    ///
    /// 交差や密集で追跡が相手チームの選手に乗り移らないよう、それまでの色の票とはっきり食い違う
    /// 観測には距離の罰則を加える。画面が切り替わったフレームでは、それまでの追跡をすべて終える。
    static func track(observations: [[Observation]], votes: [[TeamVote?]], frames: [SavedFrame], sections: [Int]) -> [Track] {
        var tracks: [Track] = []
        var active: [Int] = []

        for (frameIndex, list) in observations.enumerated() {
            let time = frames[frameIndex].timestamp
            active = active.filter {
                time - tracks[$0].last.time <= maxTrackGap && sections[tracks[$0].last.frame] == sections[frameIndex]
            }

            var pairs: [(track: Int, observation: Int, distance: Double)] = []
            for trackIndex in active {
                let track = tracks[trackIndex]
                let dt = time - track.last.time
                let predicted = CGPoint(
                    x: Double(track.last.position.x) + track.velocityX * dt,
                    y: Double(track.last.position.y) + track.velocityY * dt
                )
                let gate = positionTolerance + maxSpeed * dt
                let trackTeam = track.confidentColorTeam
                for (observationIndex, observation) in list.enumerated() {
                    let height = (track.last.height + observation.height) / 2
                    var d = distance(predicted, observation.position, height: height)
                    guard d <= gate else { continue }
                    if let trackTeam, let vote = votes[frameIndex][observationIndex],
                       vote.strength >= colorConflictStrength, vote.team != trackTeam {
                        d += colorConflictPenalty
                    }
                    // 審判の追跡と選手の追跡が、すれ違うときに入れ替わらないようにする
                    if track.points.count >= 3, track.isMostlyReferee != observation.isReferee {
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

                let observation = list[pair.observation]
                let last = tracks[pair.track].last
                let dt = time - last.time
                if dt > 0 {
                    // 1秒あたり身長の 6 倍を上限にする（誤った対応付けで予測が暴れないように）
                    let limit = 6 * observation.height
                    let vx = max(-limit, min(limit, Double(observation.position.x - last.position.x) / dt))
                    let vy = max(-limit, min(limit, Double(observation.position.y - last.position.y) / dt))
                    let isFirstStep = tracks[pair.track].points.count == 1
                    tracks[pair.track].velocityX = isFirstStep ? vx : (tracks[pair.track].velocityX + vx) / 2
                    tracks[pair.track].velocityY = isFirstStep ? vy : (tracks[pair.track].velocityY + vy) / 2
                }
                tracks[pair.track].add(
                    TrackPoint(frame: frameIndex, observation: pair.observation, time: time, position: observation.position, height: observation.height),
                    observation: observation,
                    vote: votes[frameIndex][pair.observation]
                )
            }

            for (observationIndex, observation) in list.enumerated() where !usedObservations.contains(observationIndex) {
                var track = Track(id: tracks.count, points: [])
                track.add(
                    TrackPoint(frame: frameIndex, observation: observationIndex, time: time, position: observation.position, height: observation.height),
                    observation: observation,
                    vote: votes[frameIndex][observationIndex]
                )
                tracks.append(track)
                active.append(tracks.count - 1)
            }
        }
        return tracks
    }

    /// 追跡が途切れた後に始まった追跡のうち、つながりうるものを1本にまとめる
    static func stitch(_ tracks: [Track], sections: [Int]) -> [Track] {
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
                guard gap > 0, a != b, sections[earlier.last.frame] == sections[later.first.frame] else { continue }
                let height = (earlier.last.height + later.first.height) / 2
                let d = distance(earlier.last.position, later.first.position, height: height)
                guard d <= 1 + maxSpeed * gap else { continue }
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
                track.teamVotes[0] += part.teamVotes[0]
                track.teamVotes[1] += part.teamVotes[1]
                track.refereeVotes += part.refereeVotes
                track.refereeCount += part.refereeCount
                track.goalkeeperCount += part.goalkeeperCount
                track.numberVotes.merge(part.numberVotes, uniquingKeysWith: +)
                current = next[index]
            }
            merged.append(track)
        }
        return merged
    }
}
