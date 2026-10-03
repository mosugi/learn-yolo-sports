//
//  AnalysisMetrics.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation
import CoreGraphics

/// 検出結果から算出する戦術的な指標
///
/// オンデバイス LLM はコンテキスト長が短いため、生データではなくこの指標を要約して渡す。
nonisolated struct AnalysisMetrics {
    
    /// ボール周辺とみなす距離（正規化座標）
    static let nearBallDistance: CGFloat = 0.15
    
    let frameCount: Int
    let coveredDuration: Double
    /// 1フレームあたりの平均選手数（GK を含む）
    let averagePlayers: Double
    /// ボールが検出されたフレームの割合
    let ballDetectionRate: Double
    /// ボール位置の左右分布（左・中央・右の割合）
    let ballHorizontalZones: [Double]
    /// ボール位置の上下分布（奥・中央・手前の割合）
    let ballVerticalZones: [Double]
    /// 選手位置の左右分布（左・中央・右の割合）
    let playerHorizontalZones: [Double]
    /// 選手の左右の散らばり（x 座標の標準偏差の平均）
    let averagePlayerSpread: Double
    /// ボール周辺にいる選手数の平均
    let averagePlayersNearBall: Double
    /// ボール周辺の選手が最も多かった瞬間
    let densestMoment: (timestamp: Double, players: Int)?
    /// ボールの平均移動速度（画面幅/秒）
    let averageBallSpeed: Double?
    
    init(record: SavedAnalysis) {
        let frames = record.frames
        frameCount = frames.count
        coveredDuration = record.coveredDuration
        ballDetectionRate = record.ballDetectionRate
        
        func players(in frame: SavedFrame) -> [SavedDetection] {
            frame.detections(of: .player) + frame.detections(of: .goalkeeper)
        }
        func ball(in frame: SavedFrame) -> SavedDetection? {
            frame.detections(of: .ball).max { $0.confidence < $1.confidence }
        }
        
        averagePlayers = frames.isEmpty ? 0 : Double(frames.map { players(in: $0).count }.reduce(0, +)) / Double(frames.count)
        
        let ballCenters = frames.compactMap { ball(in: $0)?.center }
        ballHorizontalZones = Self.zoneRatios(ballCenters.map(\.x))
        ballVerticalZones = Self.zoneRatios(ballCenters.map(\.y))
        playerHorizontalZones = Self.zoneRatios(frames.flatMap { players(in: $0).map(\.center.x) })
        
        let spreads = frames.compactMap { Self.standardDeviation(players(in: $0).map(\.center.x)) }
        averagePlayerSpread = spreads.isEmpty ? 0 : spreads.reduce(0, +) / Double(spreads.count)
        
        // ボール周辺の選手数
        var nearCounts: [(timestamp: Double, players: Int)] = []
        for frame in frames {
            guard let ballCenter = ball(in: frame)?.center else { continue }
            let count = players(in: frame).filter { player in
                hypot(player.center.x - ballCenter.x, player.center.y - ballCenter.y) <= Self.nearBallDistance
            }.count
            nearCounts.append((frame.timestamp, count))
        }
        averagePlayersNearBall = nearCounts.isEmpty ? 0 : Double(nearCounts.map(\.players).reduce(0, +)) / Double(nearCounts.count)
        densestMoment = nearCounts.max { $0.players < $1.players }
        
        // 連続してボールが検出されたフレーム間の移動速度
        var speeds: [Double] = []
        for (previous, current) in zip(frames, frames.dropFirst()) {
            guard let a = ball(in: previous)?.center, let b = ball(in: current)?.center else { continue }
            let interval = current.timestamp - previous.timestamp
            guard interval > 0 else { continue }
            speeds.append(Double(hypot(b.x - a.x, b.y - a.y)) / interval)
        }
        averageBallSpeed = speeds.isEmpty ? nil : speeds.reduce(0, +) / Double(speeds.count)
    }
    
    /// 指標を日本語のテキストにまとめる（LLM への入力用）
    var summaryText: String {
        var lines: [String] = []
        lines.append("- 解析フレーム数: \(frameCount)（\(String(format: "%.1f", coveredDuration)) 秒分）")
        lines.append("- 1フレームあたりの平均選手数: \(String(format: "%.1f", averagePlayers)) 人")
        lines.append("- ボール検出率: \(Self.percent(ballDetectionRate))")
        if ballDetectionRate > 0 {
            lines.append("- ボール位置（画面の左/中央/右）: \(Self.zonesText(ballHorizontalZones))")
            lines.append("- ボール位置（画面の奥/中央/手前）: \(Self.zonesText(ballVerticalZones))")
            lines.append("- ボール周辺（画面幅の\(Int(Self.nearBallDistance * 100))%以内）の平均選手数: \(String(format: "%.1f", averagePlayersNearBall)) 人")
            if let densestMoment, densestMoment.players > 0 {
                lines.append("- ボール周辺が最も密集した瞬間: \(String(format: "%.1f", densestMoment.timestamp)) 秒（\(densestMoment.players) 人）")
            }
            if let averageBallSpeed {
                lines.append("- ボールの平均移動速度: 画面幅の \(Self.percent(averageBallSpeed))/秒")
            }
        }
        lines.append("- 選手位置（画面の左/中央/右）: \(Self.zonesText(playerHorizontalZones))")
        lines.append("- 選手の左右の散らばり（標準偏差、画面幅比）: \(String(format: "%.2f", averagePlayerSpread))")
        return lines.joined(separator: "\n")
    }
    
    // MARK: - Helpers
    
    /// 0〜1 の値を3分割した領域ごとの割合
    private static func zoneRatios(_ values: [CGFloat]) -> [Double] {
        guard !values.isEmpty else { return [0, 0, 0] }
        var counts = [0, 0, 0]
        for value in values {
            counts[min(2, max(0, Int(value * 3)))] += 1
        }
        return counts.map { Double($0) / Double(values.count) }
    }
    
    private static func standardDeviation(_ values: [CGFloat]) -> Double? {
        guard values.count >= 2 else { return nil }
        let mean = values.reduce(0, +) / CGFloat(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / CGFloat(values.count)
        return Double(variance.squareRoot())
    }
    
    private static func zonesText(_ zones: [Double]) -> String {
        zones.map(percent).joined(separator: " / ")
    }
    
    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
