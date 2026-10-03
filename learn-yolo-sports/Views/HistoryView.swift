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
    
    var body: some View {
        NavigationStack {
            Group {
                if store.records.isEmpty {
                    ContentUnavailableView(
                        "解析結果はまだありません",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("解析が完了すると自動的に保存されます")
                    )
                } else {
                    List {
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
                Label("\(record.frames.count) フレーム", systemImage: "photo.stack")
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
}

/// 保存済みの解析結果の詳細
struct HistoryDetailView: View {
    @Environment(AnalysisStore.self) private var store
    let record: SavedAnalysis
    
    @State private var frames: [FrameDetectionResult]?
    
    var body: some View {
        Group {
            if let frames {
                AnalysisResultView(record: record, frames: frames)
            } else {
                ProgressView("読み込み中...")
            }
        }
        .navigationTitle(record.videoName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: record.id) {
            frames = await store.loadFrames(for: record)
        }
    }
}

#Preview {
    HistoryView()
        .environment(AnalysisStore())
}
