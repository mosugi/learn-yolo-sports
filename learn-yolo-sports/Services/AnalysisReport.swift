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
        lines.append("あなたはサッカーの戦術アナリストです。以下は試合動画全体から一定間隔でフレームを抜き出し、YOLO で物体検出した結果です。この結果をもとに、試合状況の読み取りと戦術的なアドバイスをお願いします。")
        lines.append("")

        lines.append("## 前提")
        lines.append("- 検出クラス: ball（ボール）, player（選手）, referee（審判）, goalkeeper（ゴールキーパー）")
        lines.append("- 座標は画像に対する正規化座標（0〜1、左上原点）。x は画面左→右、y は画面上→下")
        lines.append("- ユニフォームの色から2チームに自動で分けている（ボール保持の判定は行っていない）")
        lines.append("- 選手はフレーム間で追跡し、背番号が読めた選手は #番号、読めなかった選手は登場順に A, B, C… の記号で呼んでいる")
        lines.append("- カメラが動くため、位置は画面上の位置。床の色の上に立っていない人（観客など）は除いている")
        lines.append("- 検出には見逃し・誤検出が含まれる。特にボールは小さく見逃しやすい")
        if !record.usedRealModel {
            lines.append("- 注意: この結果はモックモード（ランダムな検出結果）で生成されている")
        }
        lines.append("")

        lines.append("## 動画と解析条件")
        lines.append("- 動画: \(record.videoName)")
        if let duration = record.videoDuration {
            lines.append("- 長さ: \(format(duration)) 秒")
        }
        lines.append("- 抽出: \(record.frames.count) フレーム（\(record.framesPerSecond) FPS、\(format(record.coveredDuration)) 秒分）")
        lines.append("")

        if let teams = record.teams, !teams.isEmpty {
            lines.append("## チーム")
            for team in teams {
                lines.append("- \(team.name)（\(ColorNaming.japaneseName(for: team.color))系ユニフォーム）")
            }
            lines.append("")
        }

        if let players = record.players, !players.isEmpty {
            lines.append("## 識別した選手")
            lines.append("| 選手 | チーム | 写っていた時間(秒) | フレーム数 |")
            lines.append("|---|---|---|---|")
            for player in players.sorted(by: PlayerIdentity.teamOrder) {
                let teamName = record.team(id: player.team)?.name ?? "-"
                lines.append("| \(player.label) | \(teamName) | \(format(player.firstSeen))〜\(format(player.lastSeen)) | \(player.frameCount) |")
            }
            lines.append("")
        }

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
            lines.append("## 端末上の AI（Apple Intelligence）による総評")
            lines.append(advice.summary)
            lines.append("")
            lines.append(contentsOf: advice.observations.map { "- 観察: \($0)" })
            lines.append(contentsOf: advice.suggestions.map { "- 提案: \($0)" })
            lines.append("")
        }

        if let segments = record.segments, !segments.isEmpty {
            lines.append("## シーン別の解説")
            for segment in segments {
                lines.append("### \(format(segment.startTime))秒〜\(format(segment.endTime))秒（\(segment.kind.japaneseName)）")
                if let commentary = segment.commentary {
                    lines.append("**\(commentary.headline)**")
                    lines.append(commentary.commentary)
                    lines.append("- 提案: \(commentary.suggestion)")
                } else {
                    lines.append("（この場面のAI解説は生成できませんでした）")
                }
                if let tactics = segment.tactics, !tactics.options.isEmpty {
                    let teamName = record.teams?.first { $0.id == tactics.attackingTeam }?.name ?? "保持チーム"
                    let carrier = tactics.carrierLabel.map { "、保持者 \($0)" } ?? ""
                    lines.append("- \(format(tactics.timestamp))秒時点の選択肢（\(teamName)の攻撃\(carrier)）:")
                    for (index, option) in tactics.options.enumerated() {
                        let mark = option.id == segment.recommendedOptionID ? "【おすすめ】" : ""
                        var line = "  \(option.id). \(mark)\(option.summary)"
                        if let comment = segment.commentary?.optionComments?[index] {
                            line += " — \(comment)"
                        }
                        lines.append(line)
                    }
                }
                lines.append("")
            }
        }

        lines.append("## 10秒ごとの集計")
        lines.append("| 時間帯(秒) | player | goalkeeper | referee | ボール検出率 | ボール中心 (x, y) |")
        lines.append("|---|---|---|---|---|---|")
        for row in bucketedRows(record: record, bucketSeconds: 10) {
            lines.append("| " + row.joined(separator: " | ") + " |")
        }
        lines.append("")

        lines.append("## お願いしたいこと")
        lines.append("1. この試合全体の状況（攻守、ボールのある位置、選手の密集など）の読み取り")
        lines.append("2. 気になる点と、その根拠となる時間帯")
        lines.append("3. チーム・選手への具体的な改善提案")
        lines.append("4. 検出結果だけでは判断できない点")

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func bucketedRows(record: SavedAnalysis, bucketSeconds: Int) -> [[String]] {
        let grouped = Dictionary(grouping: record.frames) { frame in
            Int(frame.timestamp) / bucketSeconds
        }

        return grouped.keys.sorted().map { bucketIndex -> [String] in
            let frames = grouped[bucketIndex] ?? []
            let playerCount = frames.reduce(0) { $0 + $1.detections(of: .player).count }
            let goalkeeperCount = frames.reduce(0) { $0 + $1.detections(of: .goalkeeper).count }
            let refereeCount = frames.reduce(0) { $0 + $1.detections(of: .referee).count }
            let ballFrameCount = frames.filter { !$0.detections(of: .ball).isEmpty }.count
            let ballRate = frames.isEmpty ? 0 : Double(ballFrameCount) / Double(frames.count)
            let ballCenters = frames.compactMap { $0.detections(of: .ball).max { $0.confidence < $1.confidence }?.center }
            let averageBallCenter = averageCenter(of: ballCenters)

            let start = bucketIndex * bucketSeconds
            let end = start + bucketSeconds
            return [
                "\(start)-\(end)",
                "\(playerCount)",
                "\(goalkeeperCount)",
                "\(refereeCount)",
                percent(ballRate),
                averageBallCenter.map(point) ?? "-",
            ]
        }
    }

    private static func averageCenter(of points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
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
