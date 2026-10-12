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

/// オンデバイス LLM に生成させる選手個人へのアドバイスの構造
@Generable
nonisolated struct GeneratedPlayerAdvice {
    @Guide(description: "この選手の動きの総評。2〜3文の日本語")
    var summary: String

    @Guide(description: "指標から読み取れる良い点。根拠となる数値に触れた短い日本語の文", .count(2))
    var strengths: [String]

    @Guide(description: "次の試合で意識するとよい具体的な改善点。短い日本語の文", .count(3))
    var improvements: [String]
}

/// オンデバイス LLM に生成させる試合の解説の構造
@Generable
nonisolated struct GeneratedMatchReport {
    @Guide(description: "試合の見出し。15文字程度の日本語")
    var headline: String

    @Guide(description: "試合の流れを伝える解説。実況・解説者が振り返るように、4〜6文の日本語")
    var story: String

    @Guide(description: "試合の見どころ。時刻（例: 3:15）で始まる短い日本語の文", .count(3))
    var highlights: [String]
}

/// Apple Intelligence（Foundation Models）を使って解析結果へのアドバイスを生成する
///
/// UI の状態は持たず、ViewModel のパイプラインから呼ばれる async なサービス。
/// シーンごとに新しい `LanguageModelSession` を作ることで、コンテキスト長を抑える。
nonisolated enum IntelligenceAdvisor {

    /// 指示文・入力の版。変えたときは上げる（同じ動画を選び直したときに AI の文章を作り直す目安になる）
    static let promptVersion = 2

    private static let instructions = """
        あなたはサッカーの戦術コーチです。
        試合動画を物体検出して得た指標をもとに、選手とチームに向けたアドバイスを日本語で返してください。
        ユニフォームの色でチームを自動判定し、選手は背番号（#10 など）または記号（A, B など）で呼んでいます。ボール保持の判定は行っていません。
        動画はサイドライン側から撮影したもので、両チームのゴールは画面の左右にあり、攻撃は画面の左右方向です。
        両チームの人数は常に同じです。画面に写る人数の差はカメラの向きによるもので、チームの人数の差や人数を増やす提案として述べないでください。
        検出には見逃しや誤検出も含まれます。数値から言えることだけを述べ、断定しすぎないでください。
        """

    /// 試合の解説用（改善の提案はせず、何が起きたかを伝える）
    private static let commentatorInstructions = """
        あなたはサッカー中継の解説者です。
        試合動画を物体検出・追跡して得た出来事の記録をもとに、試合の流れを視聴者に伝える解説を日本語で返してください。
        改善の提案やアドバイスはせず、どちらのチームがどう攻め、どこで流れが変わったかを、落ち着いた口調で伝えてください。
        ユニフォームの色でチームを自動判定し、選手は背番号（#10 など）または記号（A, B など）で呼んでいます。
        動画はサイドライン側から撮影したもので、両チームのゴールは画面の左右にあります。両チームの人数は常に同じです。
        ボールの持ち主はボールに最も近い選手から推定しており、見逃しや誤りも含まれます。記録にないことは述べず、得点が記録にない場合は得点に触れないでください。
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

    /// 試合の流れを伝える解説を生成する
    static func matchReport(for record: SavedAnalysis, playByPlay: MatchPlayByPlay) async throws -> MatchReport {
        let session = LanguageModelSession(instructions: commentatorInstructions)
        let response = try await session.respond(to: matchPrompt(for: record, playByPlay: playByPlay), generating: GeneratedMatchReport.self)
        let generated = response.content
        return MatchReport(
            headline: generated.headline,
            story: generated.story,
            highlights: generated.highlights,
            generatedAt: Date()
        )
    }

    /// 指定した選手の動きへのアドバイスを生成する
    static func playerAdvice(metrics: PlayerMetrics, usedRealModel: Bool) async throws -> PlayerAdvice {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: playerPrompt(metrics: metrics, usedRealModel: usedRealModel), generating: GeneratedPlayerAdvice.self)
        let generated = response.content
        return PlayerAdvice(
            playerID: metrics.player.id,
            summary: generated.summary,
            strengths: generated.strengths,
            improvements: generated.improvements,
            generatedAt: Date()
        )
    }

    /// バックグラウンドでは生成が制限されるため、アプリを開いたときに作成することを伝える
    static let deferredMessage = "アプリがバックグラウンドの間は AI 解説を作成できないため、アプリを開いたときに作成します。"

    /// バックグラウンドで実行したために生成が制限されたか
    static func isRateLimited(_ error: Error) -> Bool {
        if let generationError = error as? LanguageModelSession.GenerationError,
           case .rateLimited = generationError {
            return true
        }
        return false
    }

    /// エラーを表示用の日本語メッセージに変換する
    static func errorMessage(for error: Error) -> String {
        if let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .rateLimited:
                return deferredMessage
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

    private static func matchPrompt(for record: SavedAnalysis, playByPlay: MatchPlayByPlay) -> String {
        var lines: [String] = []
        let duration = record.videoDuration ?? record.coveredDuration
        lines.append("以下は\(DurationText.approximate(duration))のサッカー動画から記録した、試合の出来事です。")
        if !record.usedRealModel {
            lines.append("（注意: これはテスト用のランダムな検出結果です）")
        }
        lines.append("")
        lines.append(playByPlay.summaryText(record: record))
        if let segments = record.segments, !segments.isEmpty {
            lines.append("")
            lines.append("重要シーン:")
            for segment in segments.sorted(by: { $0.startTime < $1.startTime }) {
                let headline = segment.commentary?.headline.map { "「\($0)」" } ?? ""
                lines.append("- \(DurationText.clock(segment.startTime)) \(segment.kind.japaneseName)\(headline)")
            }
        }
        lines.append("")
        lines.append("この記録から、試合の見出し、試合の流れを伝える解説、見どころを作成してください。")
        return lines.joined(separator: "\n")
    }

    private static func playerPrompt(metrics: PlayerMetrics, usedRealModel: Bool) -> String {
        var lines: [String] = []
        lines.append("以下はサッカー動画を物体検出・追跡して得た、1人の選手の動きの指標です。")
        if !usedRealModel {
            lines.append("（注意: これはテスト用のランダムな検出結果です）")
        }
        lines.append("")
        lines.append(metrics.summaryText)
        lines.append("")
        lines.append("距離と速さは、写っている選手の身長を\(PlayerMetrics.assumedHeight)mと仮定した目安です。位置はカメラ画面上の位置で、ピッチ上の絶対位置ではありません。")
        lines.append("カメラに写っていない間の動きは含みません。")
        lines.append("この指標から、この選手の動きの総評、良い点、次の試合での改善点を、本人に話しかけるように作成してください。")
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
