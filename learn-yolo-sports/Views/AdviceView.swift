//
//  AdviceView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI

/// Apple Intelligence によるアドバイスの表示
struct AdviceView: View {
    @Environment(AnalysisStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    
    let recordID: UUID
    
    @State private var advisor = IntelligenceAdvisor()
    @State private var saveError: String?
    
    private var record: SavedAnalysis? {
        store.record(for: recordID)
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let record {
                        // 生成済みのアドバイスは Apple Intelligence を使えない端末でも表示する
                        if let reason = advisor.unavailableReason, record.advice == nil {
                            ContentUnavailableView(
                                "アドバイスを生成できません",
                                systemImage: "apple.intelligence",
                                description: Text(reason)
                            )
                        } else {
                            content(for: record)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("AIアドバイス")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") {
                        advisor.cancel()
                        dismiss()
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func content(for record: SavedAnalysis) -> some View {
        if !record.usedRealModel {
            Label("モックモードの結果のため、アドバイスは参考になりません", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        
        if advisor.isGenerating, let partial = advisor.partial {
            adviceSections(
                summary: partial.summary,
                observations: partial.observations ?? [],
                suggestions: partial.suggestions ?? [],
                playerAdvice: partial.playerAdvice ?? []
            )
        } else if advisor.isGenerating {
            HStack {
                ProgressView()
                Text("指標を分析しています...")
                    .foregroundStyle(.secondary)
            }
        } else if let advice = record.advice {
            adviceSections(
                summary: advice.summary,
                observations: advice.observations,
                suggestions: advice.suggestions,
                playerAdvice: advice.playerAdvice ?? []
            )
            
            Text("生成日時: \(advice.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        
        if case .failed(let message) = advisor.state {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
        
        if let saveError {
            Text(saveError)
                .font(.caption)
                .foregroundStyle(.red)
        }
        
        if let reason = advisor.unavailableReason {
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !advisor.isGenerating {
            Button {
                generate(for: record)
            } label: {
                Label(record.advice == nil ? "アドバイスを生成" : "再生成", systemImage: "apple.intelligence")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        
        Text(record.coachReport == nil
             ? "Apple Intelligence により端末上で生成されます。コート設定なしの解析のためチームの区別がなく、参考情報としてご利用ください。"
             : "Apple Intelligence により端末上で生成されます。場面の判定は規則に基づいて行い、AI はその言語化だけを担当します。")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
    
    private func adviceSections(summary: String?, observations: [String], suggestions: [String], playerAdvice: [String]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if let summary, !summary.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("総評")
                        .font(.headline)
                    Text(summary)
                }
            }
            
            if !observations.isEmpty {
                bulletSection(title: "場面の解説", systemImage: "eye", items: observations)
            }
            
            if !suggestions.isEmpty {
                bulletSection(title: "次に取り組むこと", systemImage: "lightbulb", items: suggestions)
            }
            
            if !playerAdvice.isEmpty {
                bulletSection(title: "選手へのアドバイス", systemImage: "person.fill", items: playerAdvice)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func bulletSection(title: String, systemImage: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("・")
                    Text(item)
                }
            }
        }
    }
    
    private func generate(for record: SavedAnalysis) {
        saveError = nil
        advisor.generate(for: record) { advice in
            var updated = store.record(for: record.id) ?? record
            updated.advice = advice
            do {
                try store.update(updated)
            } catch {
                saveError = "アドバイスの保存に失敗しました: \(error.localizedDescription)"
            }
        }
    }
}
