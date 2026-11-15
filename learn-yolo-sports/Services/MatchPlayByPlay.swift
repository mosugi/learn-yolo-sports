//
//  MatchPlayByPlay.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/12.
//

import Foundation
import CoreGraphics

/// 実況の 1 つの出来事（「赤チームの#7から#10へパス」など）
nonisolated struct PlayEvent: Hashable, Identifiable {
    enum Kind: Hashable {
        /// 味方へのパス
        case pass
        /// 相手からボールを奪った
        case turnover
        /// ボールを持って運んだ
        case dribble
        /// 重要シーンの始まり
        case scene(SceneKind)
    }

    let id: Int
    let time: Double
    let kind: Kind
    /// 出来事の主役のチーム（TeamInfo.id）
    let team: Int?
    let text: String

    var systemImage: String {
        switch kind {
        case .pass: return "arrow.right"
        case .turnover: return "arrow.triangle.2.circlepath"
        case .dribble: return "figure.run"
        case .scene(let kind): return kind.systemImage
        }
    }
}

/// 試合の流れ（実況の出来事とボール保持率）
///
/// 各フレームでボールに最も近い選手を持ち主とみなし、持ち主が変わった（2 回続けて同じ選手が持った）ところを
/// パス・ボール奪取として拾う。改善の提案ではなく、何が起きたかを伝えるためのもの。
nonisolated struct MatchPlayByPlay {
    /// ボールが見えない間も、同じ持ち主とみなす時間（秒）
    private static let holdGap = 2.0
    /// ドリブルとして伝える、運んだ距離（m）と時間（秒）
    private static let dribbleMeters = 8.0
    private static let dribbleSeconds = 2.0

    let events: [PlayEvent]
    /// チームごとのボール保持率（TeamInfo.id → 0〜1）
    let possession: [Int: Double]

    init(record: SavedAnalysis) {
        let aspect = record.imageWidth > 0 && record.imageHeight > 0
            ? Double(record.imageWidth) / Double(record.imageHeight)
            : 16.0 / 9.0
        let labels = Dictionary((record.players ?? []).map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
        func name(_ playerID: Int, team: Int?) -> String {
            let label = labels[playerID] ?? "選手"
            guard let teamName = record.team(id: team)?.name else { return label }
            return "\(teamName)の\(label)"
        }

        let holdings = BallPossession.holdings(frames: record.frames, aspect: aspect)

        var events: [PlayEvent] = []
        func add(_ time: Double, _ kind: PlayEvent.Kind, team: Int?, _ text: String) {
            events.append(PlayEvent(id: events.count, time: time, kind: kind, team: team, text: text))
        }

        var possessionTime: [Int: Double] = [:]
        var current: BallPossession.Holding?
        /// 今の持ち主が持ち始めた位置と、ドリブルを伝えたか
        var start: BallPossession.Holding?
        var reportedDribble = false
        for (index, holding) in holdings.enumerated() {
            if let current, !holding.sceneCut, holding.time - current.time <= Self.holdGap {
                possessionTime[current.team, default: 0] += holding.time - current.time
            }
            guard let previous = current, !holding.sceneCut, holding.time - previous.time <= Self.holdGap else {
                // 画面が切り替わった・しばらくボールが見えなかったときは、つなげない
                current = holding
                start = holding
                reportedDribble = false
                continue
            }
            if holding.playerID == previous.playerID {
                current = holding
                if !reportedDribble, let start {
                    let meters = hypot(Double(holding.position.x - start.position.x), Double(holding.position.y - start.position.y))
                        / max(0.02, (holding.height + start.height) / 2) * PlayerMetrics.assumedHeight
                    if meters >= Self.dribbleMeters, holding.time - start.time >= Self.dribbleSeconds {
                        add(start.time, .dribble, team: holding.team, "\(name(holding.playerID, team: holding.team))がボールを運びます")
                        reportedDribble = true
                    }
                }
                continue
            }
            // 1 フレームだけ近くを通った選手は持ち主にしない（次も同じ選手が持っていれば渡ったとみなす）
            let next = holdings.indices.contains(index + 1) ? holdings[index + 1] : nil
            guard next == nil || next?.playerID == holding.playerID else { continue }
            if holding.team == previous.team {
                add(holding.time, .pass, team: holding.team, "\(name(previous.playerID, team: previous.team))から\(labels[holding.playerID] ?? "味方")へパス")
            } else {
                add(holding.time, .turnover, team: holding.team, "\(name(holding.playerID, team: holding.team))がボールを奪いました")
            }
            current = holding
            start = holding
            reportedDribble = false
        }

        // 重要シーンの始まりも、流れの目印として入れる
        for segment in record.segments ?? [] {
            let team = segment.team ?? segment.tactics?.attackingTeam
            let teamName = record.team(id: team)?.name
            let text: String
            switch segment.kind {
            case .buildUp: text = teamName.map { "\($0)が後方から組み立てます" } ?? "後方からの組み立て"
            case .congestion: text = "ボールの周りで競り合いになります"
            case .fastBreak: text = teamName.map { "\($0)の速い攻撃" } ?? "速い展開になります"
            case .goalThreat: text = teamName.map { "\($0)がゴール前に迫ります" } ?? "ゴール前の攻防"
            case .transition: text = teamName.map { "\($0)がボールを奪い、攻守が切り替わります" } ?? "攻守が切り替わります"
            case .goal: text = teamName.map { "\($0)が得点" } ?? "得点"
            }
            add(segment.startTime, .scene(segment.kind), team: team, text)
        }

        self.events = events
            .sorted { $0.time < $1.time }
            .enumerated()
            .map { PlayEvent(id: $0.offset, time: $0.element.time, kind: $0.element.kind, team: $0.element.team, text: $0.element.text) }
        let total = possessionTime.values.reduce(0, +)
        possession = total > 0 ? possessionTime.mapValues { $0 / total } : [:]
    }

    /// 指定した時刻の直前の出来事（within 秒以内）
    func latestEvent(at time: Double, within: Double = 3) -> PlayEvent? {
        var lower = 0, upper = events.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if events[mid].time <= time { lower = mid + 1 } else { upper = mid }
        }
        guard lower > 0 else { return nil }
        let event = events[lower - 1]
        return time - event.time <= within ? event : nil
    }

    /// パス・奪取の回数（チームごと）
    func count(of kind: PlayEvent.Kind, team: Int) -> Int {
        events.filter { $0.kind == kind && $0.team == team }.count
    }

    /// AI に渡す試合の流れの要約（長くなりすぎないよう、出来事は間引く）
    func summaryText(record: SavedAnalysis, limit: Int = 40) -> String {
        var lines: [String] = []
        for team in record.teams ?? [] {
            let share = possession[team.id].map { "\(Int(($0 * 100).rounded()))%" } ?? "不明"
            lines.append("- \(team.name): ボール保持率 \(share)、パスがつながった回数 \(count(of: .pass, team: team.id))、ボールを奪った回数 \(count(of: .turnover, team: team.id))")
        }
        lines.append("")
        lines.append("出来事（時刻順）:")
        let step = max(1, Int((Double(events.count) / Double(limit)).rounded(.up)))
        // シーンの始まりとボール奪取は残し、パスとドリブルを間引く
        var playIndex = 0
        for event in events {
            if event.kind == .pass || event.kind == .dribble {
                playIndex += 1
                guard (playIndex - 1) % step == 0 else { continue }
            }
            lines.append("- \(DurationText.clock(event.time)) \(event.text)")
        }
        return lines.joined(separator: "\n")
    }
}

/// 各フレームのボールの持ち主（ボールに最も近い選手）
nonisolated enum BallPossession {
    /// ボールを持っているとみなす、足元からボールまでの最大距離（画面の高さ=1 の単位）
    static let possessionDistance = 0.12

    nonisolated struct Holding {
        let time: Double
        let playerID: Int
        let team: Int
        /// 動画全体で共通の足元の位置（画面の高さ=1 の単位）と枠の高さ
        let position: CGPoint
        let height: Double
        let sceneCut: Bool
    }

    /// ボールが写っていて、近くにチームの分かる選手がいるフレームの持ち主（時刻順）
    static func holdings(frames: [SavedFrame], aspect: Double) -> [Holding] {
        func gap(_ a: CGPoint, _ b: CGPoint) -> Double {
            hypot(Double(a.x - b.x) * aspect, Double(a.y - b.y))
        }
        var holdings: [Holding] = []
        for frame in frames.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let ball = frame.detections(of: .ball).max(by: { $0.confidence < $1.confidence }) else { continue }
            let people = (frame.detections(of: .player) + frame.detections(of: .goalkeeper))
                .filter { $0.playerID != nil && $0.team != nil }
            guard let holder = people.min(by: { gap($0.footPoint, ball.center) < gap($1.footPoint, ball.center) }),
                  gap(holder.footPoint, ball.center) <= possessionDistance,
                  let playerID = holder.playerID, let team = holder.team else { continue }
            let offset = frame.cameraOffset ?? .zero
            holdings.append(Holding(
                time: frame.timestamp,
                playerID: playerID,
                team: team,
                position: CGPoint(x: (holder.footPoint.x + offset.x) * aspect, y: holder.footPoint.y + offset.y),
                height: Double(holder.boundingBox.height),
                sceneCut: frame.sceneCut == true
            ))
        }
        return holdings
    }

    /// 攻守の切り替え（相手チームの選手が 2 回続けてボールを持った時点）
    /// - Returns: 時刻と、ボールを奪ったチーム、奪ったあとにボールを持ち続けた時間（秒）
    static func turnovers(in holdings: [Holding], holdGap: Double = 2.0) -> [(time: Double, team: Int, playerID: Int, kept: Double)] {
        var result: [(time: Double, team: Int, playerID: Int, kept: Double)] = []
        var currentTeam: Int?
        var lastTime = -Double.infinity
        for (index, holding) in holdings.enumerated() {
            defer { lastTime = holding.time }
            if holding.sceneCut || holding.time - lastTime > holdGap {
                currentTeam = holding.team
                continue
            }
            guard let team = currentTeam, holding.team != team else { continue }
            // 1 フレームだけ近くを通った相手は数えない
            let next = holdings.indices.contains(index + 1) ? holdings[index + 1] : nil
            guard next == nil || next?.team == holding.team else { continue }
            currentTeam = holding.team
            // 奪ったチームがボールを持ち続けた時間（相手に渡るか、途切れるまで）
            var kept = 0.0
            var previous = holding.time
            for later in holdings[(index + 1)...] {
                if later.sceneCut || later.time - previous > holdGap || later.team != holding.team { break }
                kept = later.time - holding.time
                previous = later.time
            }
            result.append((holding.time, holding.team, holding.playerID, kept))
        }
        return result
    }
}
