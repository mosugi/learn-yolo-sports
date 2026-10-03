//
//  CoachReport.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation
import CoreGraphics

/// 自チームから見た局面
nonisolated enum GamePhase: String, Codable, Hashable {
    case attack
    case defense
    /// ボールを失った直後（攻撃から守備への切り替え）
    case transitionToDefense
    /// ボールを奪った直後（守備から攻撃への切り替え）
    case transitionToAttack
    /// ボールが見えない、または保持が判定できない
    case unknown

    var displayName: String {
        switch self {
        case .attack: return "攻撃"
        case .defense: return "守備"
        case .transitionToDefense: return "攻→守の切り替え"
        case .transitionToAttack: return "守→攻の切り替え"
        case .unknown: return "局面不明"
        }
    }
}

/// 解説の判定規則
nonisolated enum CoachRule: String, Codable, Hashable, CaseIterable {
    /// 縦の間延び・コンパクトさ
    case compactness
    /// ボールサイドへのスライド
    case slide
    /// 攻撃時の幅
    case width
    /// ボール保持者へのサポート
    case support
    /// ボールを失った直後の寄せ
    case counterPress
    /// ボールを奪った直後の前進
    case forwardRuns
}

/// 俯瞰図で強調するもの
nonisolated enum SceneHighlight: Codable, Hashable {
    case none
    /// 自チームのフィールドプレーヤーを囲む長方形（縦幅・横幅）
    case teamBox
    /// ボールを中心とした円（半径 m）
    case ballRadius(Double)
    /// 選手の移動（始点 → 終点）
    case movements([PitchMovement])
}

nonisolated struct PitchMovement: Codable, Hashable {
    let from: CGPoint
    let to: CGPoint
}

/// ある瞬間のピッチ上の配置（m）
nonisolated struct PitchSnapshot: Codable, Hashable {
    let time: Double
    /// 自チームのフィールドプレーヤー
    let own: [CGPoint]
    /// 相手のフィールドプレーヤー
    let opponent: [CGPoint]
    let ownGoalkeepers: [CGPoint]
    let opponentGoalkeepers: [CGPoint]
    let ball: CGPoint?
    let highlight: SceneHighlight
}

/// 解説する場面
nonisolated struct CoachScene: Codable, Hashable, Identifiable {
    let id: Int
    let rule: CoachRule
    /// 良い場面か（false は課題）
    let isPositive: Bool
    let startTime: Double
    let endTime: Double
    /// 俯瞰図・静止画に使う時刻
    let peakTime: Double
    let phase: GamePhase
    let title: String
    /// 根拠となる数値
    let evidence: String
    /// 指摘
    let comment: String
    /// 改善点・続けたいこと
    let suggestion: String
    let snapshot: PitchSnapshot
}

/// 解析区間全体の集計
nonisolated struct CoachSummary: Codable, Hashable {
    /// 戦術分析に使えた時間（秒）
    let analyzedDuration: Double
    /// ボールが見えていた割合
    let ballVisibleRatio: Double
    /// 保持が判定できた時間のうち、自チームが保持していた割合
    let ownPossessionRatio: Double?
    /// 保持が判定できた時間の割合
    let possessionKnownRatio: Double
    /// 平均の縦幅（m）
    let averageDepth: Double?
    /// 平均の横幅（m）
    let averageWidth: Double?
    /// 守備時の平均の縦幅（m）
    let averageDepthInDefense: Double?
    /// 攻撃時の平均の横幅（m）
    let averageWidthInAttack: Double?
    /// ボールを失った回数
    let ballsLost: Int
    /// ボールを奪った回数
    let ballsWon: Int
}

/// コーチ解説
nonisolated struct CoachReport: Codable, Hashable {
    let summary: CoachSummary
    let scenes: [CoachScene]
    /// 解析上の注意
    let notes: [String]
    /// 相手チームのユニフォームの色（推定できた場合）
    let opponentColor: LabColor?
}

extension CoachReport {
    /// LLM への入力用テキスト（判定済みの事実のみ）
    nonisolated var promptText: String {
        var lines: [String] = []
        lines.append("## 集計")
        lines.append(contentsOf: summary.lines.map { "- \($0)" })
        lines.append("")
        lines.append("## 判定された場面")
        if scenes.isEmpty {
            lines.append("- 目立った場面は検出されませんでした")
        }
        for scene in scenes {
            let kind = scene.isPositive ? "良い点" : "課題"
            lines.append("- [\(kind)] \(Self.time(scene.startTime))〜\(Self.time(scene.endTime)) \(scene.title)（\(scene.phase.displayName)）: \(scene.evidence)。\(scene.comment)")
        }
        if !notes.isEmpty {
            lines.append("")
            lines.append("## 注意")
            lines.append(contentsOf: notes.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    /// 動画内の時刻（例: 1:05.2）
    nonisolated static func time(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let rest = seconds - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, rest)
    }
}

extension CoachSummary {
    /// 表示・共有用の行
    nonisolated var lines: [String] {
        var lines: [String] = []
        lines.append("分析できた時間: \(String(format: "%.0f", analyzedDuration)) 秒")
        lines.append("ボールが見えていた割合: \(Self.percent(ballVisibleRatio))")
        if let ownPossessionRatio {
            lines.append("ボール保持率（判定できた時間のうち）: 自チーム \(Self.percent(ownPossessionRatio)) / 相手 \(Self.percent(1 - ownPossessionRatio))")
        }
        lines.append("保持を判定できた時間の割合: \(Self.percent(possessionKnownRatio))")
        if let averageDepthInDefense {
            lines.append("守備時の平均の縦幅: \(Self.meters(averageDepthInDefense))")
        } else if let averageDepth {
            lines.append("平均の縦幅: \(Self.meters(averageDepth))")
        }
        if let averageWidthInAttack {
            lines.append("攻撃時の平均の横幅: \(Self.meters(averageWidthInAttack))")
        } else if let averageWidth {
            lines.append("平均の横幅: \(Self.meters(averageWidth))")
        }
        lines.append("ボールを奪った回数: \(ballsWon) / 失った回数: \(ballsLost)")
        return lines
    }

    nonisolated static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    nonisolated static func meters(_ value: Double) -> String {
        String(format: "%.0f m", value)
    }
}
