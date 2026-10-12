//
//  AnalysisTimeline.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation
import CoreGraphics

/// ユニフォーム色から判定したチーム
nonisolated struct TeamInfo: Codable, Hashable, Identifiable {
    let id: Int
    let name: String
    let color: RGBColor
}

/// 追跡して識別した選手
///
/// 背番号が読めた選手は「#10」、読めなかった選手は登場順に「A」「B」…の記号で呼ぶ。
/// 同じチームで同じ背番号が同時に2人写ることはないため、時間が重なる追跡には同じ背番号を付けない。
nonisolated struct PlayerIdentity: Codable, Hashable, Identifiable {
    let id: Int
    /// チーム（TeamInfo.id。GK・審判は nil）
    let team: Int?
    let jerseyNumber: Int?
    /// 背番号が読めなかった選手の記号（A, B, …, Z, AA, …）
    let letter: String?
    let isGoalkeeper: Bool
    /// 画面に写っていた時間
    let firstSeen: Double
    let lastSeen: Double
    /// 写っていたフレーム数
    let frameCount: Int

    /// 短い呼び名（例: #10、A、GK左）
    var label: String {
        if isGoalkeeper {
            return "GK" + (letter ?? "") + (jerseyNumber.map { " #\($0)" } ?? "")
        }
        if let jerseyNumber { return "#\(jerseyNumber)" }
        return letter ?? "?"
    }

    /// チーム名を含む呼び名（例: 赤チーム #10）
    func displayName(teams: [TeamInfo]?) -> String {
        guard let team, let info = teams?.first(where: { $0.id == team }) else { return label }
        return "\(info.name) \(label)"
    }

    /// チームごとに並べる表示順（チームのない GK は最後）
    static func teamOrder(_ lhs: PlayerIdentity, _ rhs: PlayerIdentity) -> Bool {
        let a = lhs.team ?? Int.max, b = rhs.team ?? Int.max
        return a != b ? a < b : sortOrder(lhs, rhs)
    }

    /// 表示順（背番号順、記号順）
    static func sortOrder(_ lhs: PlayerIdentity, _ rhs: PlayerIdentity) -> Bool {
        if lhs.isGoalkeeper != rhs.isGoalkeeper { return lhs.isGoalkeeper }
        switch (lhs.jerseyNumber, rhs.jerseyNumber) {
        case let (a?, b?): return a < b
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil):
            let a = lhs.letter ?? "", b = rhs.letter ?? ""
            return a.count != b.count ? a.count < b.count : a < b
        }
    }
}

/// シーンの種類（ピーク時点の特徴から決める）
nonisolated enum SceneKind: String, Codable {
    case buildUp
    case congestion
    case fastBreak
    case goalThreat
    /// 攻守の切り替え（ボールを奪った直後）
    case transition
    /// 得点（ユーザーが記録した場面）
    case goal

    var japaneseName: String {
        switch self {
        case .buildUp: return "ビルドアップ"
        case .congestion: return "競り合い"
        case .fastBreak: return "速い展開"
        case .goalThreat: return "ゴール前の攻防"
        case .transition: return "攻守の切り替え"
        case .goal: return "得点"
        }
    }

    var systemImage: String {
        switch self {
        case .buildUp: return "arrow.triangle.swap"
        case .congestion: return "person.3.fill"
        case .fastBreak: return "bolt.fill"
        case .goalThreat: return "target"
        case .transition: return "arrow.triangle.2.circlepath"
        case .goal: return "soccerball"
        }
    }
}

/// AI が生成するシーン解説
nonisolated struct SceneCommentary: Codable, Hashable {
    let headline: String
    let commentary: String
    let suggestion: String
    /// 選択肢（TacticalOption）ごとの短い評価。選択肢と同じ順番
    var optionComments: [String]? = nil
    /// AI がおすすめする選択肢の番号（TacticalOption.id）
    var recommendedOptionID: Int? = nil
    /// この場面で良かったプレー（褒める一言）
    var praise: String? = nil
}

/// 選択肢の種類
nonisolated enum TacticalOptionKind: String, Codable {
    case pass
    case dribble

    var japaneseName: String {
        switch self {
        case .pass: return "パス"
        case .dribble: return "ドリブル"
        }
    }
}

/// シーンの注目時点で、ボール保持者が取れる選択肢（画面上の矢印として表示する）
nonisolated struct TacticalOption: Codable, Hashable, Identifiable {
    /// 矢印に表示する番号（1始まり）
    let id: Int
    let kind: TacticalOptionKind
    /// 矢印の始点・終点（正規化座標、左上原点）
    let from: CGPoint
    let to: CGPoint
    /// パスの受け手の呼び名（#10、A など。識別できた場合のみ）
    var targetLabel: String? = nil
    /// 到達点から最も近い相手までの距離（画面の高さ=1 とした距離）。大きいほどフリー
    let openness: Double
    /// パスコース上で最も近い相手までの距離（ドリブルは進路上）。大きいほどコースが空いている
    let laneClearance: Double
    /// 始点から終点までの距離（画面の高さ=1 とした距離）
    let length: Double
    /// 幾何計算による評価値（大きいほどよい）
    let score: Double
    /// 「右奥の#7へパス（フリー・コース空き）」のような説明
    let summary: String
}

/// シーンの注目時点の局面（ボール保持者と選択肢）
nonisolated struct TacticalSnapshot: Codable, Hashable {
    /// 局面を切り出したフレーム
    let frameNumber: Int
    let timestamp: Double
    /// ボール保持チーム（TeamInfo.id）
    let attackingTeam: Int
    /// ボール保持者の呼び名（識別できた場合のみ）
    var carrierLabel: String? = nil
    /// ボール保持者の足元とボールの位置（正規化座標）
    let carrier: CGPoint
    let ball: CGPoint
    /// 評価値の高い順の選択肢（最大3つ）
    let options: [TacticalOption]

    /// 幾何計算で最もよい選択肢
    var bestOptionID: Int? { options.max { $0.score < $1.score }?.id }
}

/// 重要シーンの区切り（解説者がそのシーンまで進めて解説するイメージ）
nonisolated struct SceneSegment: Codable, Hashable, Identifiable {
    let id: UUID
    let startTime: Double
    let endTime: Double
    let keyTime: Double
    let kind: SceneKind
    var commentary: SceneCommentary?
    /// 注目時点の選択肢（ボール保持者が判定できなかった場合は nil）
    var tactics: TacticalSnapshot?
    /// 場面の主役のチーム（攻守の切り替えはボールを奪ったチーム、得点は決めたチーム）
    var team: Int? = nil
    /// 得点のシーンを記録したときに区切ったり除いたりした元のシーン（取り消したときに戻す）
    var displacedSegments: [SceneSegment]? = nil

    init(
        id: UUID = UUID(),
        startTime: Double,
        endTime: Double,
        keyTime: Double,
        kind: SceneKind,
        commentary: SceneCommentary? = nil,
        tactics: TacticalSnapshot? = nil,
        team: Int? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.keyTime = keyTime
        self.kind = kind
        self.commentary = commentary
        self.tactics = tactics
        self.team = team
    }

    var title: String { kind.japaneseName }

    /// AI のおすすめ（なければ幾何計算で最もよいもの）の選択肢番号
    var recommendedOptionID: Int? {
        if let id = commentary?.recommendedOptionID, tactics?.options.contains(where: { $0.id == id }) == true {
            return id
        }
        return tactics?.bestOptionID
    }

    func contains(_ time: Double) -> Bool {
        time >= startTime && time < endTime
    }
}
