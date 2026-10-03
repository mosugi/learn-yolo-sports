//
//  IntelligenceAdvisor.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation
import FoundationModels

/// オンデバイス LLM に生成させるアドバイスの構造
@Generable
nonisolated struct GeneratedAdvice {
    @Guide(description: "この時間帯の自チームの戦い方の総評。コーチが選手に語りかける口調で2〜3文の日本語")
    var summary: String
    
    @Guide(description: "判定された場面についての解説。時刻と根拠の数値に触れた短い日本語の文", .count(3))
    var observations: [String]
    
    @Guide(description: "次の練習や試合で取り組むこと。具体的な行動を示す短い日本語の文", .count(3))
    var suggestions: [String]
    
    @Guide(description: "背番号を挙げた選手ごとの短いアドバイス。「#10: 〜」の形式の日本語。選手の情報がなければ空", .maximumCount(5))
    var playerAdvice: [String]
}

/// Apple Intelligence（Foundation Models）を使って解析結果へのアドバイスを生成する
@MainActor
@Observable
final class IntelligenceAdvisor {
    
    enum State {
        case idle
        case generating
        case failed(String)
    }
    
    private(set) var state: State = .idle
    /// 生成途中の内容（ストリーミング表示用）
    private(set) var partial: GeneratedAdvice.PartiallyGenerated?
    
    private var generationTask: Task<Void, Never>?
    
    private static let instructions = """
        あなたは育成年代も指導するサッカーのコーチです。
        試合動画の解析で判定済みの場面と集計をもとに、自チームの選手に向けた解説を日本語で返してください。
        場面の良し悪しの判定はすでに行われています。与えられた判定と数値だけを使い、新しい数値や場面を作らないでください。
        検出には見逃しや誤検出が含まれるため、断定しすぎず、前向きで具体的な言葉を選んでください。
        """
    
    /// 端末で Apple Intelligence を利用できない場合の理由（利用できる場合は nil）
    var unavailableReason: String? {
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
    
    var isGenerating: Bool {
        if case .generating = state { return true }
        return false
    }
    
    /// アドバイスを生成する
    /// - Parameter onComplete: 生成完了時に結果を受け取る
    func generate(for record: SavedAnalysis, onComplete: @escaping (AnalysisAdvice) -> Void) {
        guard !isGenerating else { return }
        
        state = .generating
        partial = nil
        
        generationTask = Task {
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let stream = session.streamResponse(
                    to: Self.prompt(for: record),
                    generating: GeneratedAdvice.self
                )
                
                for try await snapshot in stream {
                    partial = snapshot.content
                }
                
                let advice = AnalysisAdvice(
                    summary: partial?.summary ?? "",
                    observations: partial?.observations ?? [],
                    suggestions: partial?.suggestions ?? [],
                    generatedAt: Date(),
                    playerAdvice: partial?.playerAdvice ?? []
                )
                state = .idle
                onComplete(advice)
                
            } catch is CancellationError {
                state = .idle
            } catch let error as LanguageModelSession.GenerationError {
                state = .failed(Self.message(for: error))
            } catch {
                state = .failed("アドバイスの生成に失敗しました: \(error.localizedDescription)")
            }
            generationTask = nil
        }
    }
    
    func cancel() {
        generationTask?.cancel()
    }
    
    // MARK: - Prompt
    
    private static func prompt(for record: SavedAnalysis) -> String {
        var lines: [String] = []
        if let report = record.coachReport, let setup = record.setup {
            lines.append("以下はサッカーの試合動画（\(setup.format.displayName)）を解析し、規則に基づいて判定した結果です。")
            if !record.usedRealModel {
                lines.append("（注意: これはテスト用のランダムな検出結果です）")
            }
            lines.append("")
            lines.append(report.promptText)
            let chapters = record.chapterList
            if !chapters.isEmpty {
                lines.append("")
                lines.append("## 得点シーン")
                lines.append(contentsOf: chapters.map { "- \(CoachReport.time($0.eventTime)) \($0.title(setup: setup))" })
            }
            // オンデバイス LLM は入力が短いため、選手は追跡できた時間の長い順に絞る
            let players = PlayerAnalyzer.reports(for: record)
                .sorted { $0.observedTime > $1.observedTime }
                .prefix(6)
            if !players.isEmpty {
                lines.append("")
                lines.append("## 選手別（背番号）")
                lines.append(contentsOf: players.map { "- \($0.summaryLine)" })
            }
            lines.append("")
            lines.append("この結果から、総評、場面ごとの解説、次に取り組むこと、背番号ごとの選手へのアドバイスを作成してください。")
            return lines.joined(separator: "\n")
        }
        
        lines.append("以下はサッカー動画の物体検出から算出した指標です。")
        if !record.usedRealModel {
            lines.append("（注意: これはテスト用のランダムな検出結果です）")
        }
        lines.append("")
        lines.append(AnalysisMetrics(record: record).summaryText)
        lines.append("")
        lines.append("位置はカメラ画面上の位置で、ピッチ上の絶対位置ではありません。")
        lines.append("この指標から、試合状況の総評、観察ポイント、改善提案を作成してください。")
        return lines.joined(separator: "\n")
    }
    
    private static func message(for error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize:
            return "入力が長すぎるため生成できませんでした。"
        case .guardrailViolation:
            return "安全上の理由により生成できませんでした。"
        case .unsupportedLanguageOrLocale:
            return "現在の言語設定ではアドバイスを生成できません。"
        default:
            return "アドバイスの生成に失敗しました: \(error.localizedDescription)"
        }
    }
}
