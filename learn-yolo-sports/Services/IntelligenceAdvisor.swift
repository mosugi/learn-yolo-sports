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
    @Guide(description: "この時間帯の試合状況の総評。2〜3文の日本語")
    var summary: String
    
    @Guide(description: "指標から読み取れる観察ポイント。根拠となる数値に触れた短い日本語の文", .count(3))
    var observations: [String]
    
    @Guide(description: "チームや選手への具体的な改善提案。短い日本語の文", .count(3))
    var suggestions: [String]
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
        あなたはサッカーの戦術コーチです。
        試合動画を物体検出して得た指標をもとに、選手とチームに向けたアドバイスを日本語で返してください。
        検出にはチームの区別がなく、見逃しや誤検出も含まれます。数値から言えることだけを述べ、断定しすぎないでください。
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
                    generatedAt: Date()
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
