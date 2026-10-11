//
//  IntelligenceAdvisor.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation
import FoundationModels

/// オンデバイス LLM に生成させる全体総評の構造
@Generable
nonisolated struct GeneratedAdvice {
    @Guide(description: "試合全体の総評。2〜3文の日本語")
    var summary: String

    @Guide(description: "指標から読み取れる観察ポイント。根拠となる数値に触れた短い日本語の文", .count(3))
    var observations: [String]

    @Guide(description: "チームや選手への具体的な改善提案。短い日本語の文", .count(3))
    var suggestions: [String]
}

/// オンデバイス LLM に生成させるシーン解説の構造
@Generable
nonisolated struct GeneratedSceneCommentary {
    @Guide(description: "このシーンの見出し。10文字程度の日本語")
    var headline: String

    @Guide(description: "このシーンの状況説明。2〜3文の日本語")
    var commentary: String

    @Guide(description: "このシーンに対する具体的な一言アドバイス。選択肢の候補がある場合はどれを選ぶべきかに触れる。1文の日本語")
    var suggestion: String

    @Guide(description: "選択肢の候補それぞれへの短い評価（利点とリスク）。候補と同じ順番・同じ数の日本語の文。候補がなければ空の配列")
    var optionComments: [String]

    @Guide(description: "最もおすすめする選択肢の候補番号。候補がなければ0")
    var recommendedOption: Int
}

/// Apple Intelligence（Foundation Models）を使って解析結果へのアドバイスを生成する
///
/// UI の状態は持たず、ViewModel のパイプラインから呼ばれる async なサービス。
/// シーンごとに新しい `LanguageModelSession` を作ることで、コンテキスト長を抑える。
nonisolated enum IntelligenceAdvisor {

    private static let instructions = """
        あなたはサッカーの戦術コーチです。
        試合動画を物体検出して得た指標をもとに、選手とチームに向けたアドバイスを日本語で返してください。
        ユニフォームの色でチームを自動判定し、選手は背番号（#10 など）または記号（A, B など）で呼んでいます。ボール保持の判定は行っていません。
        検出には見逃しや誤検出も含まれます。数値から言えることだけを述べ、断定しすぎないでください。
        """

    /// 端末で Apple Intelligence を利用できない場合の理由（利用できる場合は nil）
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "この端末は Apple Intelligence に対応していません。"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "設定アプリで Apple Intelligence を有効にしてください。"
        case .unavailable(.modelNotReady):
            return "モデルを準備中です。しばらくしてから再度お試しください。"
        case .unavailable(let reason):
            return "Apple Intelligence を利用できません（\(reason)）。"
        }
    }

    /// 試合全体の総評を生成する
    static func overallAdvice(for record: SavedAnalysis) async throws -> AnalysisAdvice {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: overallPrompt(for: record), generating: GeneratedAdvice.self)
        let generated = response.content
        return AnalysisAdvice(
            summary: generated.summary,
            observations: generated.observations,
            suggestions: generated.suggestions,
            generatedAt: Date()
        )
    }

    /// シーン別の解説を生成する（解説者がこの場面まで進めて解説するイメージ）
    static func sceneCommentary(
        for segment: SceneSegment,
        metrics: AnalysisMetrics,
        teams: [TeamInfo]?,
        usedRealModel: Bool
    ) async throws -> SceneCommentary {
        let session = LanguageModelSession(instructions: instructions)
        let prompt = scenePrompt(segment: segment, metrics: metrics, teams: teams, usedRealModel: usedRealModel)
        let response = try await session.respond(to: prompt, generating: GeneratedSceneCommentary.self)
        let generated = response.content

        let options = segment.tactics?.options ?? []
        // 数が合わない・存在しない番号のときは使わない（画面では幾何計算の説明・おすすめにフォールバックする）
        let comments = generated.optionComments.count == options.count && !options.isEmpty ? generated.optionComments : nil
        let recommended = options.contains { $0.id == generated.recommendedOption } ? generated.recommendedOption : nil
        return SceneCommentary(
            headline: generated.headline,
            commentary: generated.commentary,
            suggestion: generated.suggestion,
            optionComments: comments,
            recommendedOptionID: recommended
        )
    }

    /// エラーを表示用の日本語メッセージに変換する
    static func errorMessage(for error: Error) -> String {
        if let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .exceededContextWindowSize:
                return "入力が長すぎるため生成できませんでした。"
            case .guardrailViolation:
                return "安全上の理由により生成できませんでした。"
            case .unsupportedLanguageOrLocale:
                return "現在の言語設定ではアドバイスを生成できません。"
            default:
                return "アドバイスの生成に失敗しました: \(generationError.localizedDescription)"
            }
        }
        return "アドバイスの生成に失敗しました: \(error.localizedDescription)"
    }

    // MARK: - Prompt

    private static func overallPrompt(for record: SavedAnalysis) -> String {
        var lines: [String] = []
        lines.append("以下はサッカー動画全体の物体検出から算出した指標です。")
        if !record.usedRealModel {
            lines.append("（注意: これはテスト用のランダムな検出結果です）")
        }
        lines.append("")
        lines.append(AnalysisMetrics(record: record).summaryText)
        lines.append("")
        lines.append("位置はカメラ画面上の位置で、ピッチ上の絶対位置ではありません。")
        lines.append("この指標から、試合全体の総評、観察ポイント、改善提案を作成してください。")
        return lines.joined(separator: "\n")
    }

    private static func scenePrompt(segment: SceneSegment, metrics: AnalysisMetrics, teams: [TeamInfo]?, usedRealModel: Bool) -> String {
        var lines: [String] = []
        lines.append("以下はサッカー動画の \(Int(segment.startTime))秒〜\(Int(segment.endTime))秒（注目時点 \(Int(segment.keyTime))秒）の物体検出から算出した指標です。")
        lines.append("場面の種類（スコアからの機械的な分類）: \(segment.kind.japaneseName)")
        if !usedRealModel {
            lines.append("（注意: これはテスト用のランダムな検出結果です）")
        }
        lines.append("")
        lines.append(metrics.summaryText)
        lines.append("")
        lines.append("位置はカメラ画面上の位置で、ピッチ上の絶対位置ではありません。")
        lines.append("")
        lines.append(tacticsText(segment.tactics, teams: teams))
        lines.append("")
        lines.append("この場面の見出し、状況説明、具体的なアドバイス、選択肢の候補それぞれへの評価とおすすめの番号を作成してください。")
        return lines.joined(separator: "\n")
    }

    private static func tacticsText(_ tactics: TacticalSnapshot?, teams: [TeamInfo]?) -> String {
        guard let tactics, !tactics.options.isEmpty else {
            return "選択肢の候補: なし（ボール保持者を判定できませんでした）"
        }
        let teamName = teams?.first { $0.id == tactics.attackingTeam }?.name ?? "保持チーム"
        let carrier = tactics.carrierLabel.map { "（\($0)）" } ?? ""
        var lines = ["\(Int(tactics.timestamp))秒時点で\(teamName)\(carrier)がボールを保持しています。画面上の位置関係から計算した選択肢の候補:"]
        for option in tactics.options {
            lines.append(String(
                format: "%d. %@（距離 %.2f、到達点のフリー度 %.2f、コースの空き %.2f）",
                option.id,
                option.summary,
                option.length,
                option.openness,
                option.laneClearance
            ))
        }
        lines.append("距離・フリー度・コースの空きは画面の高さを1とした値で、大きいほど相手から離れています。")
        return lines.joined(separator: "\n")
    }
}
