//
//  Telestrator.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/12.
//

import Foundation
import CoreGraphics

/// 書き込みの色の役割
nonisolated enum TelestrationTone: Hashable {
    /// 注目する選手・おすすめ（黄）
    case highlight
    /// 選択肢（白）
    case option
    /// 実際の選択（水色）
    case actual
    /// 実際の選択を別解と並べるときの控えめな表示（灰）
    case muted
    /// 良い判断（緑）
    case good
    /// 相手の守備（赤）
    case defense
}

/// 矢印の線の種類
nonisolated enum TelestrationArrowStyle: Hashable {
    /// パス（実線）
    case pass
    /// ドリブル（点線）
    case dribble
    /// ボールを持たない選手の走り込み（細い点線）
    case run
}

/// 画面に書き込む要素（座標はその手順で止める場面の正規化座標）
nonisolated enum TelestrationMark: Hashable {
    /// 選手の足元の輪
    case ring(at: CGPoint, label: String?, tone: TelestrationTone)
    /// 矢印（badge は矢印の先に付ける番号や短い言葉）
    case arrow(from: CGPoint, to: CGPoint, style: TelestrationArrowStyle, tone: TelestrationTone, badge: String?)
    /// 空いた場所（地面に塗る円。半径は地面上の長さ・身長単位）
    case area(center: CGPoint, radius: Double)
    /// 相手の最終ライン（選手の足元をつなぐ）
    case defensiveLine([CGPoint])
    /// 2 人の間の距離
    case distance(from: CGPoint, to: CGPoint, meters: Double)
    /// ここに立つべきだった、という仮想の選手
    case ghost(at: CGPoint, label: String)
}

/// 再生しながら足元の輪で追いかける選手
nonisolated struct TelestrationFollow: Hashable {
    let playerID: Int
    let start: Double
    let end: Double
    let tone: TelestrationTone
}

/// 解説の 1 手順
nonisolated struct TelestrationStep: Hashable, Identifiable {
    enum Kind: Hashable {
        case situation
        case options
        case space
        case actual
        case alternative

        var title: String {
            switch self {
            case .situation: return "状況"
            case .options: return "選択肢"
            case .space: return "スペース"
            case .actual: return "実際の選択"
            case .alternative: return "別解"
            }
        }
    }

    let kind: Kind
    /// 止めて書き込む時刻（秒）
    let time: Double
    /// 書き込む場面のフレーム（遠近の推定に使う）
    let frameNumber: Int
    /// この手順の前に再生する区間（実際の選択を見せるとき）
    var playback: ClosedRange<Double>? = nil
    /// 再生中に追いかける選手
    var follows: [TelestrationFollow] = []
    let caption: String
    var detail: String? = nil
    /// 書き込む要素（見やすさのため 3 つまでに抑える）
    let marks: [TelestrationMark]
    /// 書き込んでから次の手順へ進むまでの時間（秒）
    let hold: Double

    var id: Kind { kind }
}

/// 1 シーンの解説の流れ（状況 → 選択肢 → スペース → 実際の選択 → 別解）
nonisolated struct TelestrationScript: Hashable {
    let segmentID: SceneSegment.ID
    let steps: [TelestrationStep]
    /// 解説を終えたあとに再生を続ける時刻
    let resumeTime: Double
}

/// 解析結果から、放送のテレストレーターのような書き込みの手順を自動で組み立てる
///
/// 止める位置はシーンの局面（ボール保持者が判断する直前）で、そこから先のフレームで
/// 実際にボールが誰に渡ったかを調べ、選択肢やおすすめと比べる。
nonisolated enum Telestrator {
    /// ボールを持っているとみなす、足元からボールまでの最大距離（画面の高さ=1 の単位）
    private static let possessionDistance = 0.12
    /// 実際の選択を探す時間（秒）
    private static let lookahead = 5.0
    /// 実際の選択の再生速度
    static let playbackRate: Float = 0.5
    /// 最終ラインとみなす、最も深い相手からの距離（m）
    private static let defensiveLineDepth = 7.0

    static func script(for segment: SceneSegment, in record: SavedAnalysis) -> TelestrationScript? {
        guard let tactics = segment.tactics, !tactics.options.isEmpty,
              let frame0 = record.frames.first(where: { $0.frameNumber == tactics.frameNumber }) else { return nil }
        let aspect = record.imageWidth > 0 && record.imageHeight > 0
            ? Double(record.imageWidth) / Double(record.imageHeight)
            : 16.0 / 9.0
        let context = Context(record: record, aspect: aspect)
        let t0 = frame0.timestamp
        let projection0 = GroundProjection(detections: frame0.detections, aspectRatio: aspect)

        let carrier = context.people(in: frame0)
            .filter { $0.team == tactics.attackingTeam }
            .min { context.gap($0.footPoint, tactics.carrier) < context.gap($1.footPoint, tactics.carrier) }
        let carrierFoot = carrier?.footPoint ?? tactics.carrier
        let carrierLabel = tactics.carrierLabel ?? carrier?.playerID.flatMap(context.label(of:))
        let teamName = record.team(id: tactics.attackingTeam)?.name

        var steps: [TelestrationStep] = []

        // 1. 状況: ボール保持者、最も近い相手との距離、相手の最終ライン
        do {
            var marks: [TelestrationMark] = [.ring(at: carrierFoot, label: carrierLabel, tone: .highlight)]
            var notes: [String] = []
            let opponents = context.people(in: frame0).filter { $0.team != nil && $0.team != tactics.attackingTeam }
            if let projection0, let groundCarrier = projection0.ground(carrierFoot) {
                let nearest = opponents.compactMap { opponent -> (SavedDetection, Double)? in
                    projection0.ground(opponent.footPoint).map { (opponent, GroundProjection.distance($0, groundCarrier)) }
                }.min { $0.1 < $1.1 }
                if let (opponent, distance) = nearest {
                    let meters = GroundProjection.meters(distance)
                    marks.append(.distance(from: carrierFoot, to: opponent.footPoint, meters: meters))
                    notes.append("最も近い相手まで約\(Self.metersText(meters))")
                }
                if let line = defensiveLine(opponents: opponents, ball: tactics.ball, projection: projection0) {
                    marks.append(.defensiveLine(line))
                    notes.append("相手の最終ラインは\(line.count)人")
                }
            }
            let who = [teamName, carrierLabel].compactMap { $0 }.joined(separator: "の")
            var details: [String] = []
            if !notes.isEmpty { details.append(notes.joined(separator: "、")) }
            if let commentary = segment.commentary?.commentary { details.append(commentary) }
            steps.append(TelestrationStep(
                kind: .situation,
                time: t0,
                frameNumber: frame0.frameNumber,
                caption: situationCaption(for: segment, who: who.isEmpty ? "攻撃側" : who, record: record),
                detail: details.isEmpty ? nil : details.joined(separator: "\n"),
                marks: marks,
                hold: 5
            ))
        }

        // 2. 選択肢: 番号付きの矢印（最大 3 本）
        do {
            let marks = tactics.options.prefix(3).map { option in
                TelestrationMark.arrow(
                    from: option.from,
                    to: option.to,
                    style: option.kind == .dribble ? .dribble : .pass,
                    tone: .option,
                    badge: "\(option.id)"
                )
            }
            let lines = tactics.options.prefix(3).enumerated().map { index, option in
                let comment = segment.commentary?.optionComments.flatMap { $0.indices.contains(index) ? $0[index] : nil }
                return "\(option.id). \(option.summary)" + (comment.map { "\n   \($0)" } ?? "")
            }
            steps.append(TelestrationStep(
                kind: .options,
                time: t0,
                frameNumber: frame0.frameNumber,
                caption: "選択肢は\(Self.countText(marks.count))あります",
                detail: lines.joined(separator: "\n"),
                marks: marks,
                hold: 6
            ))
        }

        // 3. スペース: 空いた場所を塗り、近くの味方の走り込みを示す
        let spaces = SpaceFinder.spaces(in: frame0, aspectRatio: aspect).prefix(2)
        if !spaces.isEmpty {
            func area(_ space: OpenSpace) -> TelestrationMark {
                .area(center: space.center, radius: groundRadius(of: space, projection: projection0, aspect: aspect))
            }
            var marks = spaces.map(area)
            var detail: String?
            if let best = spaces.first,
               let runner = context.people(in: frame0)
                .filter({ $0.team == tactics.attackingTeam && $0.footPoint != carrierFoot })
                .min(by: { context.gap($0.footPoint, best.center) < context.gap($1.footPoint, best.center) }),
               context.gap(runner.footPoint, best.center) > 0.05 {
                let label = runner.playerID.flatMap(context.label(of:))
                // 書き込みを 3 つまでにするため、走り込みを示すときは最も広い場所だけを塗る
                marks = [area(best)]
                marks.append(.arrow(from: runner.footPoint, to: best.center, style: .run, tone: .highlight, badge: nil))
                marks.append(.ghost(at: best.center, label: "ここ"))
                detail = "\(label ?? "近くの味方")がこのスペースへ走り込めば、パスの受け手になれます"
            }
            steps.append(TelestrationStep(
                kind: .space,
                time: t0,
                frameNumber: frame0.frameNumber,
                caption: marks.count == 2 ? "空いているのはこの2か所です" : "空いているのはこのエリアです",
                detail: detail,
                marks: marks,
                hold: 5
            ))
        }

        // 4. 実際の選択: 少しゆっくり再生し、ボールが渡った先で止める
        let outcome = carrier?.playerID.flatMap {
            actualOutcome(after: frame0, carrierID: $0, attackingTeam: tactics.attackingTeam, context: context)
        }
        let recommended = tactics.options.first { $0.id == segment.recommendedOptionID }
        var matchedOptionID: Int?
        var actualArrowAtStart: TelestrationMark?
        if let outcome, let frame1 = record.frames.first(where: { $0.frameNumber == outcome.frameNumber }) {
            let shift = context.shift(from: frame0, to: frame1)
            let start1 = CGPoint(x: carrierFoot.x + shift.x, y: carrierFoot.y + shift.y)
            // 止めた場面での行き先（パスは受け手のそのときの位置、ドリブルは運んだ先をカメラの動きを戻して求める）
            let carriedTo = CGPoint(x: outcome.foot.x - shift.x, y: outcome.foot.y - shift.y)
            let end0 = outcome.kind == .dribble ? carriedTo : (context.position(of: outcome.playerID, in: frame0) ?? carriedTo)
            let label = context.label(of: outcome.playerID)

            let caption: String
            let style: TelestrationArrowStyle
            let carrierID = carrier?.playerID ?? outcome.playerID
            // ボールが渡る少し前から、受けた選手に輪を移す
            let handover = max(t0, outcome.time - 0.3)
            var follows: [TelestrationFollow] = []
            switch outcome.kind {
            case .pass:
                matchedOptionID = tactics.options.filter { $0.kind == .pass }
                    .min { context.gap($0.to, end0) < context.gap($1.to, end0) }
                    .flatMap { context.gap($0.to, end0) < 0.08 ? $0.id : nil }
                caption = "実際は\(label ?? "味方")へパスしました" + (matchedOptionID.map { "（選択肢\($0)）" } ?? "")
                style = .pass
                follows = [
                    TelestrationFollow(playerID: carrierID, start: t0, end: handover, tone: .highlight),
                    TelestrationFollow(playerID: outcome.playerID, start: handover, end: outcome.time, tone: .actual),
                ]
            case .dribble:
                matchedOptionID = tactics.options.first { $0.kind == .dribble }?.id
                caption = "実際はドリブルで運びました" + (matchedOptionID.map { "（選択肢\($0)）" } ?? "")
                style = .dribble
                follows = [TelestrationFollow(playerID: carrierID, start: t0, end: outcome.time, tone: .highlight)]
            case .lost:
                caption = "ここで相手に奪われました"
                style = .pass
                follows = [
                    TelestrationFollow(playerID: carrierID, start: t0, end: handover, tone: .highlight),
                    TelestrationFollow(playerID: outcome.playerID, start: handover, end: outcome.time, tone: .defense),
                ]
            }
            steps.append(TelestrationStep(
                kind: .actual,
                time: outcome.time,
                frameNumber: frame1.frameNumber,
                playback: t0...outcome.time,
                follows: follows,
                caption: caption,
                marks: [
                    .arrow(from: start1, to: outcome.foot, style: style, tone: .actual, badge: "実際"),
                    .ring(at: outcome.foot, label: label, tone: outcome.kind == .lost ? .defense : .actual),
                ],
                hold: 4
            ))
            actualArrowAtStart = .arrow(from: carrierFoot, to: end0, style: style, tone: .muted, badge: "実際")
        }

        // 5. 別解: 止めた場面に戻り、実際の選択とおすすめを並べる
        if let recommended {
            let recommendedArrow = TelestrationMark.arrow(
                from: recommended.from,
                to: recommended.to,
                style: recommended.kind == .dribble ? .dribble : .pass,
                tone: .highlight,
                badge: "\(recommended.id)"
            )
            let comment = segment.commentary?.optionComments.flatMap { comments in
                tactics.options.firstIndex { $0.id == recommended.id }.flatMap { comments.indices.contains($0) ? comments[$0] : nil }
            }
            let detail = [comment, segment.commentary?.suggestion].compactMap { $0 }.joined(separator: "\n")
            if matchedOptionID == recommended.id {
                steps.append(TelestrationStep(
                    kind: .alternative,
                    time: t0,
                    frameNumber: frame0.frameNumber,
                    caption: "良い判断です。おすすめの選択肢\(recommended.id)を選べています",
                    detail: detail.isEmpty ? nil : detail,
                    marks: [
                        .arrow(from: recommended.from, to: recommended.to, style: recommended.kind == .dribble ? .dribble : .pass, tone: .good, badge: "\(recommended.id)"),
                        .ring(at: recommended.to, label: recommended.targetLabel, tone: .good),
                    ],
                    hold: 6
                ))
            } else {
                var marks: [TelestrationMark] = [recommendedArrow, .ring(at: recommended.to, label: recommended.targetLabel, tone: .highlight)]
                if let actualArrowAtStart { marks.insert(actualArrowAtStart, at: 0) }
                steps.append(TelestrationStep(
                    kind: .alternative,
                    time: t0,
                    frameNumber: frame0.frameNumber,
                    caption: outcome == nil ? "おすすめは選択肢\(recommended.id)です" : alternativeCaption(for: recommended),
                    detail: detail.isEmpty ? recommended.summary : detail,
                    marks: marks,
                    hold: 7
                ))
            }
        }

        // 最後の手順で、良かったプレーを褒める
        if let praise = segment.commentary?.praise, let last = steps.indices.last {
            let step = steps[last]
            steps[last] = TelestrationStep(
                kind: step.kind,
                time: step.time,
                frameNumber: step.frameNumber,
                playback: step.playback,
                follows: step.follows,
                caption: step.caption,
                detail: ["良かった点: \(praise)", step.detail].compactMap { $0 }.joined(separator: "\n"),
                marks: step.marks,
                hold: step.hold + 2
            )
        }

        guard steps.count >= 2 else { return nil }
        return TelestrationScript(segmentID: segment.id, steps: steps, resumeTime: outcome?.time ?? t0)
    }

    // MARK: - Actual choice

    private struct Outcome {
        enum Kind { case pass, dribble, lost }
        let kind: Kind
        let playerID: Int
        let time: Double
        let frameNumber: Int
        let foot: CGPoint
    }

    /// 止めた場面のあとで、ボールが誰に渡ったか
    ///
    /// 各フレームでボールに最も近い選手を持ち主とみなし、別の選手が 2 フレーム続けて持ったら渡ったとする。
    /// 渡らないまま保持者が運び続けた場合はドリブルとみなす。
    private static func actualOutcome(after frame0: SavedFrame, carrierID: Int, attackingTeam: Int, context: Context) -> Outcome? {
        let following = context.record.frames
            .filter { $0.timestamp > frame0.timestamp && $0.timestamp <= frame0.timestamp + lookahead }
            .sorted { $0.timestamp < $1.timestamp }

        var possessions: [(frame: SavedFrame, holder: SavedDetection)] = []
        for frame in following {
            if frame.sceneCut == true { break }
            guard let ball = frame.detections(of: .ball).max(by: { $0.confidence < $1.confidence }) else { continue }
            guard let holder = context.people(in: frame)
                .filter({ $0.playerID != nil })
                .min(by: { context.gap($0.footPoint, ball.center) < context.gap($1.footPoint, ball.center) }),
                context.gap(holder.footPoint, ball.center) <= possessionDistance else { continue }
            possessions.append((frame, holder))
        }

        var lastCarrier: (frame: SavedFrame, holder: SavedDetection)?
        for (index, possession) in possessions.enumerated() {
            guard let id = possession.holder.playerID else { continue }
            if id == carrierID {
                lastCarrier = possession
                continue
            }
            let next = possessions.indices.contains(index + 1) ? possessions[index + 1].holder.playerID : nil
            guard next == nil || next == id else { continue }
            let kind: Outcome.Kind = possession.holder.team == attackingTeam ? .pass : .lost
            return Outcome(kind: kind, playerID: id, time: possession.frame.timestamp, frameNumber: possession.frame.frameNumber, foot: possession.holder.footPoint)
        }
        if let lastCarrier, lastCarrier.frame.timestamp - frame0.timestamp >= 1.0 {
            return Outcome(
                kind: .dribble,
                playerID: carrierID,
                time: lastCarrier.frame.timestamp,
                frameNumber: lastCarrier.frame.frameNumber,
                foot: lastCarrier.holder.footPoint
            )
        }
        return nil
    }

    // MARK: - Geometry

    /// 相手の最終ライン（ゴールに最も近い守備者たち）を、奥から手前の順に並べた足元
    ///
    /// 攻撃方向は分からないため、守備側の選手の多くがボールより片側（自陣のゴール側）にいることから決める。
    private static func defensiveLine(opponents: [SavedDetection], ball: CGPoint, projection: GroundProjection) -> [CGPoint]? {
        let outfield = opponents.filter { $0.label == SportsClass.player.rawValue }
        let grounded = outfield.compactMap { detection in projection.ground(detection.footPoint).map { (detection.footPoint, $0) } }
        guard grounded.count >= 2, let groundBall = projection.ground(ball) else { return nil }
        let meanX = grounded.map { Double($0.1.x) }.reduce(0, +) / Double(grounded.count)
        let offset = meanX - Double(groundBall.x)
        guard abs(offset) > GroundProjection.units(meters: 2) else { return nil }
        let direction = offset > 0 ? 1.0 : -1.0
        let depth = grounded.map { (foot: $0.0, ground: $0.1, depth: Double($0.1.x) * direction) }
        guard let deepest = depth.map(\.depth).max(), deepest > Double(groundBall.x) * direction else { return nil }
        let line = depth
            .filter { $0.depth >= deepest - GroundProjection.units(meters: defensiveLineDepth) }
            .sorted { $0.depth > $1.depth }
            .prefix(4)
        guard line.count >= 2 else { return nil }
        return line.sorted { $0.ground.y > $1.ground.y }.map(\.foot)
    }

    /// 空いた場所の半径を、地面上の長さにする
    private static func groundRadius(of space: OpenSpace, projection: GroundProjection?, aspect: Double) -> Double {
        let edge = CGPoint(x: space.center.x + space.radius / aspect, y: space.center.y)
        if let projection, let center = projection.ground(space.center), let side = projection.ground(edge) {
            return GroundProjection.distance(center, side)
        }
        return GroundProjection.units(meters: 4)
    }

    // MARK: - Text

    private static func metersText(_ meters: Double) -> String {
        meters < 10 ? String(format: "%.1fm", meters) : "\(Int(meters.rounded()))m"
    }

    private static func countText(_ count: Int) -> String {
        let words = ["", "一つ", "二つ", "三つ"]
        return words.indices.contains(count) ? words[count] : "\(count)つ"
    }

    /// 状況の一言（攻守の切り替え・得点の場面は、そのことから伝える）
    private static func situationCaption(for segment: SceneSegment, who: String, record: SavedAnalysis) -> String {
        let teamName = record.team(id: segment.team)?.name
        switch segment.kind {
        case .transition:
            return "攻守の切り替え。\(teamName.map { "\($0)が奪って、" } ?? "")\(who)がボールを持っています"
        case .goal:
            return "\(teamName.map { "\($0)の" } ?? "")得点につながった場面。\(who)がボールを持っています"
        default:
            return "\(who)がボールを持っています"
        }
    }

    /// 「ここで右奥の#7へ出していれば」のような、別解の言い方
    private static func alternativeCaption(for option: TacticalOption) -> String {
        let summary = option.summary
        switch option.kind {
        case .pass:
            if let range = summary.range(of: "へパス") {
                return "ここで\(summary[..<range.lowerBound])へ出していれば"
            }
        case .dribble:
            if let range = summary.range(of: "へ運ぶドリブル") {
                return "ここで\(summary[..<range.lowerBound])へ運んでいれば"
            }
        }
        return "ここで選択肢\(option.id)を選んでいれば"
    }

    // MARK: - Context

    private struct Context {
        let record: SavedAnalysis
        let aspect: Double
        let labels: [Int: String]

        init(record: SavedAnalysis, aspect: Double) {
            self.record = record
            self.aspect = aspect
            labels = Dictionary((record.players ?? []).map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
        }

        func label(of playerID: Int) -> String? { labels[playerID] }

        /// フィールドプレーヤーと GK（コート外を除く）
        func people(in frame: SavedFrame) -> [SavedDetection] {
            frame.detections(of: .player) + frame.detections(of: .goalkeeper)
        }

        func position(of playerID: Int, in frame: SavedFrame) -> CGPoint? {
            people(in: frame).first { $0.playerID == playerID }?.footPoint
        }

        /// 画面の高さを 1 とした距離
        func gap(_ a: CGPoint, _ b: CGPoint) -> Double {
            hypot(Double(a.x - b.x) * aspect, Double(a.y - b.y))
        }

        /// from の場面の位置を to の場面の位置に直すためのずれ（カメラの動きを打ち消す）
        func shift(from: SavedFrame, to: SavedFrame) -> CGPoint {
            let a = from.cameraOffset ?? .zero, b = to.cameraOffset ?? .zero
            return CGPoint(x: a.x - b.x, y: a.y - b.y)
        }
    }
}
