//
//  AnalysisSettings.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/11.
//

import Foundation

/// 解析の設定（動画を選ぶ画面で変更する）
nonisolated enum AnalysisSettings {
    /// UserDefaults のキー（@AppStorage と共有する）
    static let playersPerTeamKey = "playersPerTeam"
    /// 選べる1チームの人数（GK を含む）
    static let playersPerTeamOptions = [5, 8, 11]

    /// 1チームの人数（GK を含む）。識別する選手の数の上限になる
    static var playersPerTeam: Int {
        let value = UserDefaults.standard.integer(forKey: playersPerTeamKey)
        return playersPerTeamOptions.contains(value) ? value : PlayerTracker.defaultPlayersPerTeam
    }

    static func label(forPlayersPerTeam count: Int) -> String {
        switch count {
        case 5: return "5人（フットサル）"
        case 8: return "8人制"
        case 11: return "11人制"
        default: return "\(count)人"
        }
    }
}
