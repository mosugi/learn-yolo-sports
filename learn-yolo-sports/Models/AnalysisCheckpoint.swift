//
//  AnalysisCheckpoint.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation

/// 中断された解析の状態（analysis.json が書き終わる前に残す再開用の情報）
nonisolated struct AnalysisCheckpoint: Codable, Identifiable {
    enum Stage: String, Codable {
        case detecting
        case segmenting
        case commentating
    }

    let id: UUID
    let videoFileName: String
    let videoDuration: Double
    let createdAt: Date
    var updatedAt: Date
    var stage: Stage
    /// 連続して処理済みのフレーム数（このフレームから再開する）
    var lastProcessedFrame: Int
    let totalFrames: Int
    let framesPerSecond: Int
    var usedRealModel: Bool
    /// 検出したフレームの画像サイズ（最初のフレームが処理された時点で確定する）
    var imageWidth: Int?
    var imageHeight: Int?
    /// stage が .segmenting 以降で決定済み
    var teams: [TeamInfo]?
    /// stage が .segmenting 以降で決定済み
    var players: [PlayerIdentity]?
    /// stage が .segmenting 以降で決定済み（commentary は生成済みのシーンだけ入っている）
    var segments: [SceneSegment]?
}
