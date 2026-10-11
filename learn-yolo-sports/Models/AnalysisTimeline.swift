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

/// シーンの種類（ピーク時点の特徴から決める）
nonisolated enum SceneKind: String, Codable {
    case buildUp
    case congestion
    case fastBreak
    case goalThreat

    var japaneseName: String {
        switch self {
        case .buildUp: return "ビルドアップ"
        case .congestion: return "競り合い"
        case .fastBreak: return "速い展開"
        case .goalThreat: return "ゴール前の攻防"
        }
    }

    var systemImage: String {
        switch self {
        case .buildUp: return "arrow.triangle.swap"
        case .congestion: return "person.3.fill"
        case .fastBreak: return "bolt.fill"
        case .goalThreat: return "target"
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
    /// パスの受け手の背番号（読み取れた場合のみ）
    let targetJerseyNumber: Int?
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

    init(
        id: UUID = UUID(),
        startTime: Double,
        endTime: Double,
        keyTime: Double,
        kind: SceneKind,
        commentary: SceneCommentary? = nil,
        tactics: TacticalSnapshot? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.keyTime = keyTime
        self.kind = kind
        self.commentary = commentary
        self.tactics = tactics
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
