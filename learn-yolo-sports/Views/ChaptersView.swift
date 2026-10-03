//
//  ChaptersView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI
import AVKit
import UIKit

/// 得点シーンのチャプター一覧
struct ChaptersView: View {
    @Environment(AnalysisStore.self) private var store
    let record: SavedAnalysis

    @State private var playingChapter: MatchChapter?
    @State private var errorMessage: String?

    private var chapters: [MatchChapter] {
        record.chapterList
    }

    var body: some View {
        List {
            Section {
                if chapters.isEmpty {
                    Text("得点シーンは見つかりませんでした。ゴールとセンターサークルが映る区間を解析するか、「検出結果」で得点の時刻を追加してください。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(chapters) { chapter in
                    Button {
                        playingChapter = chapter
                    } label: {
                        ChapterRow(record: record, chapter: chapter)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: delete)
            } header: {
                Text("得点シーン")
            } footer: {
                Text("ゴールへのボールの侵入と、その後のセンターサークルからのキックオフで判定しています。タップすると得点に至る攻撃から再生します。")
            }

            if !chapters.isEmpty {
                Section("チャプターとして書き出す") {
                    let text = MatchChapter.chapterText(chapters, setup: record.setup)
                    Text(text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Label("コピー（YouTube の説明欄の形式）", systemImage: "doc.on.doc")
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .sheet(item: $playingChapter) { chapter in
            ChapterPlayerView(record: record, chapter: chapter)
        }
    }

    private func delete(at offsets: IndexSet) {
        let targets = Set(offsets.map { chapters[$0].id })
        do {
            try store.modify(record.id) { record in
                record.chapters = record.chapterList.filter { !targets.contains($0.id) }
            }
        } catch {
            errorMessage = "チャプターを削除できませんでした: \(error.localizedDescription)"
        }
    }
}

/// チャプターの1行
private struct ChapterRow: View {
    let record: SavedAnalysis
    let chapter: MatchChapter

    var body: some View {
        HStack(spacing: 12) {
            if let frame = record.nearestFrameWithImage(to: chapter.eventTime) {
                SavedFrameView(record: record, frame: frame, showsLabels: false)
                    .frame(width: 96, height: 54)
                    .cornerRadius(6)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "soccerball")
                        .foregroundStyle(chapter.scoringTeam?.color ?? .secondary)
                    Text(chapter.title(setup: record.setup))
                        .font(.subheadline.weight(.semibold))
                }
                Text("\(CoachReport.time(chapter.startTime)) から再生・得点 \(CoachReport.time(chapter.eventTime))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(chapter.note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "play.circle")
                .font(.title3)
                .foregroundStyle(.tint)
        }
        .contentShape(Rectangle())
    }
}

/// チャプターの開始位置から動画を再生する
struct ChapterPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    let record: SavedAnalysis
    let chapter: MatchChapter

    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let player {
                    VideoPlayer(player: player)
                        .aspectRatio(16 / 9, contentMode: .fit)
                } else {
                    ContentUnavailableView(
                        "動画が見つかりません",
                        systemImage: "film",
                        description: Text("解析した動画（\(record.videoName)）が端末に残っていません。")
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(chapter.title(setup: record.setup))
                        .font(.headline)
                    Text(chapter.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if player != nil {
                        HStack {
                            Button {
                                seek(to: chapter.startTime)
                            } label: {
                                Label("攻撃の始まりから", systemImage: "backward.end")
                            }
                            Spacer()
                            Button {
                                seek(to: chapter.eventTime - 3)
                            } label: {
                                Label("得点の直前から", systemImage: "soccerball")
                            }
                        }
                        .font(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

                Spacer()
            }
            .navigationTitle("得点シーン")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") {
                        player?.pause()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            guard player == nil, FileManager.default.fileExists(atPath: record.videoURL.path()) else { return }
            let player = AVPlayer(url: record.videoURL)
            self.player = player
            seek(to: chapter.startTime)
            player.play()
        }
        .onDisappear {
            player?.pause()
        }
    }

    private func seek(to seconds: Double) {
        player?.seek(
            to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }
}
