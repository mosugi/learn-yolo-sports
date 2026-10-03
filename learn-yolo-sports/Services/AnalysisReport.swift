//
//  AnalysisReport.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation
import CoreGraphics

/// 解析結果を外部の LLM に渡すためのテキストを生成する
nonisolated enum AnalysisReport {
    
    /// LLM にそのまま貼り付けられる Markdown
    static func markdown(for record: SavedAnalysis) -> String {
        var lines: [String] = []
        
        lines.append("# サッカー動画の物体検出結果")
        lines.append("")
        lines.append("あなたはサッカーの戦術アナリストです。以下は試合動画から一定間隔でフレームを抜き出し、YOLO で物体検出した結果です。この結果をもとに、試合状況の読み取りと戦術的なアドバイスをお願いします。")
        lines.append("")
        
        lines.append("## 前提")
        lines.append("- 検出クラス: ball（ボール）, player（選手）, referee（審判）, goalkeeper（ゴールキーパー）")
        lines.append("- 座標は画像に対する正規化座標（0〜1、左上原点）。x は画面左→右、y は画面上→下")
        lines.append("- チームの区別、選手の個体識別（トラッキング）は行っていない")
        lines.append("- 検出には見逃し・誤検出が含まれる。特にボールは小さく見逃しやすい")
        if !record.usedRealModel {
            lines.append("- 注意: この結果はモックモード（ランダムな検出結果）で生成されている")
        }
        lines.append("")
        
        lines.append("## 動画と解析条件")
        lines.append("- 動画: \(record.videoName)")
        lines.append("- 解像度: \(record.imageWidth) x \(record.imageHeight)")
        lines.append("- 抽出: \(record.frames.count) フレーム（約 \(record.framesPerSecond) FPS、\(format(record.coveredDuration)) 秒分）")
        lines.append("")
        
        lines.append("## 集計")
        lines.append("- 総検出数: \(record.totalDetections)")
        lines.append("- 1フレームあたりの平均検出数: \(format(record.averageDetectionsPerFrame))")
        lines.append("- ボールが検出されたフレームの割合: \(percent(record.ballDetectionRate))")
        for sportsClass in SportsClass.allCases {
            lines.append("- \(sportsClass.rawValue): \(record.classFrequency[sportsClass.rawValue] ?? 0) 件")
        }
        lines.append("")
        
        lines.append("## 位置に関する指標")
        lines.append(AnalysisMetrics(record: record).summaryText)
        lines.append("")
        
        if let advice = record.advice {
            lines.append("## 端末上の AI（Apple Intelligence）による一次所見")
            lines.append(advice.summary)
            lines.append("")
            lines.append(contentsOf: advice.observations.map { "- 観察: \($0)" })
            lines.append(contentsOf: advice.suggestions.map { "- 提案: \($0)" })
            lines.append("")
        }
        
        lines.append("## フレーム別")
        lines.append("| # | 時刻(秒) | player | goalkeeper | referee | ボール中心 (x, y) | 選手の平均位置 (x, y) |")
        lines.append("|---|---|---|---|---|---|---|")
        for frame in record.frames {
            let players = frame.detections(of: .player)
            let ball = frame.detections(of: .ball).max { $0.confidence < $1.confidence }
            let row = [
                "\(frame.frameNumber + 1)",
                format(frame.timestamp),
                "\(players.count)",
                "\(frame.detections(of: .goalkeeper).count)",
                "\(frame.detections(of: .referee).count)",
                ball.map { point($0.center) } ?? "-",
                averageCenter(of: players).map(point) ?? "-",
            ]
            lines.append("| " + row.joined(separator: " | ") + " |")
        }
        lines.append("")
        
        lines.append("## お願いしたいこと")
        lines.append("1. この時間帯の試合状況（攻守、ボールのある位置、選手の密集など）の読み取り")
        lines.append("2. 気になる点と、その根拠となるフレーム")
        lines.append("3. チーム・選手への具体的な改善提案")
        lines.append("4. 検出結果だけでは判断できない点")
        
        return lines.joined(separator: "\n")
    }
    
    // MARK: - Helpers
    
    static func averageCenter(of detections: [SavedDetection]) -> CGPoint? {
        guard !detections.isEmpty else { return nil }
        let sum = detections.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.center.x, y: $0.y + $1.center.y) }
        return CGPoint(x: sum.x / CGFloat(detections.count), y: sum.y / CGFloat(detections.count))
    }
    
    private static func point(_ point: CGPoint) -> String {
        "(\(format(Double(point.x))), \(format(Double(point.y))))"
    }
    
    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
    
    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
