//
//  MatchChapter.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation
import CoreGraphics

/// 動画のチャプター（得点シーンなど）
nonisolated struct MatchChapter: Codable, Hashable, Identifiable {

    nonisolated enum Kind: String, Codable, Hashable {
        /// ゴールへの侵入とその後のキックオフの両方を確認した得点
        case goal
        /// キックオフは確認できたが、ゴールへの侵入は見えていない得点
        case probableGoal
        /// ユーザーが追加したチャプター
        case manual

        var displayName: String {
            switch self {
            case .goal: return "得点"
            case .probableGoal: return "得点（推定）"
            case .manual: return "得点（手動）"
            }
        }
    }

    var id = UUID()
    let kind: Kind
    /// 再生を始める時刻（得点に至る攻撃の始まり）
    let startTime: Double
    /// 得点の瞬間
    let eventTime: Double
    /// 再生を終える目安
    let endTime: Double
    /// 得点したチーム（不明な場合は nil）
    let scoringTeam: TeamSide?
    /// 得点者の背番号（推定。不明な場合は nil）
    let scorerNumber: Int?
    /// 判定の根拠
    let note: String

    /// チャプター名（例: 得点 自チーム #10）
    func title(setup: AnalysisSetup?) -> String {
        var parts = [kind.displayName]
        if let scoringTeam {
            parts.append(scoringTeam.displayName)
        }
        if let scorerNumber {
            parts.append(setup?.playerName(number: scorerNumber) ?? "#\(scorerNumber)")
        }
        return parts.joined(separator: " ")
    }
}

extension MatchChapter {
    /// YouTube の説明欄などに貼れるチャプター一覧（先頭は 0:00 から始める）
    nonisolated static func chapterText(_ chapters: [MatchChapter], setup: AnalysisSetup?) -> String {
        var lines = ["0:00 開始"]
        var lastSecond = 0
        for chapter in chapters.sorted(by: { $0.startTime < $1.startTime }) {
            // チャプターは前のチャプターより後ろの時刻にする必要がある
            let second = max(lastSecond + 10, Int(chapter.startTime))
            lines.append("\(timestamp(second)) \(chapter.title(setup: setup))")
            lastSecond = second
        }
        return lines.joined(separator: "\n")
    }

    nonisolated static func timestamp(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let rest = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}

/// 選手ごとのアドバイス
nonisolated struct PlayerReport: Identifiable {
    let number: Int
    let name: String
    /// 主なポジションの傾向（後方 / 中盤 / 前方）
    let role: String
    /// 映像で追跡できた時間（秒）
    let observedTime: Double
    /// 1分あたりの移動距離（m）
    let distancePerMinute: Double?
    /// チーム内の中央値に対する移動距離の比
    let relativeDistance: Double?
    let sprints: Int
    /// ボールに最も近い自チームの選手だった時間（秒）
    let ballTime: Double
    /// ボールを失った直後に寄せた回数 / 機会
    let counterPress: (count: Int, chances: Int)
    /// ボールを奪った直後に前進した回数 / 機会
    let forwardRuns: (count: Int, chances: Int)
    let averagePosition: CGPoint
    /// 位置の分布（表示用に間引いたもの）
    let positions: [CGPoint]
    let advice: [PlayerAdvice]

    var id: Int { number }
}

nonisolated struct PlayerAdvice: Hashable {
    let isPositive: Bool
    let title: String
    let detail: String
}
