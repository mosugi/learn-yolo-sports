//
//  HistoryView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI

/// 保存済みの解析結果の一覧
struct HistoryView: View {
    @Environment(AnalysisStore.self) private var store
    @Environment(VideoAnalysisViewModel.self) private var viewModel

    /// 現在パイプラインが処理中のチェックポイントは、見た目は「中断」のままだが実際は書き込み中なので、
    /// ここから再開・破棄できる一覧には出さない（出すと削除と書き込みが競合する）
    private var displayedInterrupted: [AnalysisCheckpoint] {
        store.interrupted.filter { $0.id != viewModel.processingCheckpointID }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.records.isEmpty && displayedInterrupted.isEmpty {
                    ContentUnavailableView(
                        "解析結果はまだありません",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("解析が完了すると自動的に保存されます")
                    )
                } else {
                    List {
                        if !displayedInterrupted.isEmpty {
                            Section("解析中断") {
                                ForEach(displayedInterrupted) { checkpoint in
                                    InterruptedRow(checkpoint: checkpoint)
                                }
                                .onDelete { offsets in
                                    let targets = offsets.map { displayedInterrupted[$0] }
                                    for checkpoint in targets {
                                        store.discardCheckpoint(checkpoint)
                                    }
                                }
                            }
                        }

                        ForEach(store.records) { record in
                            NavigationLink(value: record.id) {
                                HistoryRow(record: record)
                            }
                        }
                        .onDelete { offsets in
                            let targets = offsets.map { store.records[$0] }
                            for record in targets {
                                store.delete(record)
                            }
                        }
                    }
                }
            }
            .navigationTitle("解析履歴")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in
                if let record = store.record(for: id) {
                    HistoryDetailView(record: record)
                }
            }
            .refreshable {
                store.loadAll()
            }
        }
    }
}

/// 履歴の1行
private struct HistoryRow: View {
    let record: SavedAnalysis
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.videoName)
                .font(.headline)
                .lineLimit(1)
            
            Text(record.createdAt, format: .dateTime.year().month().day().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
            
            HStack(spacing: 12) {
                if let duration = record.videoDuration {
                    Label(durationText(duration), systemImage: "clock")
                }
                Label("\(record.segments?.count ?? 0) シーン", systemImage: "list.bullet.rectangle")
                Label("\(record.totalDetections) 検出", systemImage: "scope")
                if !record.usedRealModel {
                    Label("モック", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func durationText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 中断された解析の1行
private struct InterruptedRow: View {
    @Environment(AnalysisStore.self) private var store
    @Environment(VideoAnalysisViewModel.self) private var viewModel
    let checkpoint: AnalysisCheckpoint

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(checkpoint.videoFileName)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(checkpoint.lastProcessedFrame)/\(checkpoint.totalFrames) フレーム")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("再開") {
                viewModel.resumeAnalysis(checkpoint)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
    }
}

/// 保存済みの解析結果の詳細
struct HistoryDetailView: View {
    let record: SavedAnalysis

    var body: some View {
        AnalysisResultView(record: record)
            .navigationTitle(record.videoName)
            .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    let store = AnalysisStore()
    HistoryView()
        .environment(store)
        .environment(VideoAnalysisViewModel(store: store))
}
