//
//  VideoAnalysisView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI
import PhotosUI

struct VideoAnalysisView: View {
    @Environment(VideoAnalysisViewModel.self) private var viewModel
    @Environment(AnalysisStore.self) private var store
    @State private var selectedVideoItem: PhotosPickerItem?
    /// 動画読み込み（iCloud からのダウンロードを含む）の進捗
    @State private var importer = VideoImporter()

    var body: some View {
        NavigationStack {
            ZStack {
                if viewModel.hasResults {
                    // 解析結果表示
                    analysisResultView
                } else if viewModel.isAnalyzing {
                    // 解析中（検出・選手の識別・シーン区切り・AI解説の生成まで自動で進む）
                    analyzingView
                } else if importer.isLoading {
                    videoLoadingView
                } else {
                    // 動画未選択（中断された解析があればここに表示する）
                    videoPickerView
                }
            }
            .navigationTitle("スポーツ動画解析")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel.hasResults {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            viewModel.reset()
                            selectedVideoItem = nil
                        } label: {
                            Label("リセット", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            .task {
                await viewModel.checkModel()
            }
            .onChange(of: selectedVideoItem) { oldValue, newValue in
                Task {
                    await loadVideo(from: newValue)
                }
            }
        }
    }

    // MARK: - Video Picker View

    private var videoPickerView: some View {
        ScrollView {
            VStack(spacing: 30) {
                if !store.interrupted.isEmpty {
                    VStack(spacing: 12) {
                        ForEach(store.interrupted) { checkpoint in
                            interruptedCard(checkpoint)
                        }
                    }
                    .padding(.top, 20)
                }

                Image(systemName: "video.badge.waveform")
                    .font(.system(size: 100))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .symbolEffect(.bounce, options: .repeating)
                    .padding(.top, store.interrupted.isEmpty ? 40 : 0)

                VStack(spacing: 10) {
                    Text("スポーツ動画を解析")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("動画を選ぶと、全編の検出から選手の識別、AI解説の生成までを自動で行います")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                PhotosPicker(
                    selection: $selectedVideoItem,
                    matching: .videos
                ) {
                    Label("動画を選択", systemImage: "photo.on.rectangle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .foregroundStyle(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 40)

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer(minLength: 20)
            }
        }
    }

    // MARK: - Video Loading View

    private var videoLoadingView: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            VStack(spacing: 16) {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)
                    .symbolEffect(.pulse, options: .repeating)

                Text("動画を読み込み中")
                    .font(.headline)

                if let fraction = importer.fraction {
                    VStack(spacing: 6) {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)

                        HStack {
                            Text("\(Int(fraction * 100))%")
                                .monospacedDigit()
                            Spacer()
                            if let remaining = importer.estimatedRemaining(now: context.date) {
                                Text("残り\(DurationText.approximate(remaining))")
                                    .monospacedDigit()
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                    Text("準備中...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let startDate = importer.startDate {
                    Text("経過 \(DurationText.clock(context.date.timeIntervalSince(startDate)))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Text("iCloud に保存されている動画は、ダウンロードに時間がかかることがあります")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("キャンセル", role: .cancel) {
                    importer.cancel()
                    selectedVideoItem = nil
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 40)
        }
    }

    // MARK: - Interrupted Analysis Card

    private func interruptedCard(_ checkpoint: AnalysisCheckpoint) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("中断された解析", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)

            Text(checkpoint.videoFileName)
                .font(.subheadline)
                .lineLimit(1)

            Text(stageDescription(checkpoint))
                .font(.caption)
                .foregroundStyle(.secondary)

            ProgressView(value: Double(checkpoint.lastProcessedFrame), total: Double(max(1, checkpoint.totalFrames)))

            HStack {
                Button("破棄", role: .destructive) {
                    store.discardCheckpoint(checkpoint)
                }
                Spacer()
                Button("再開") {
                    viewModel.resumeAnalysis(checkpoint)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal, 24)
    }

    private func stageDescription(_ checkpoint: AnalysisCheckpoint) -> String {
        switch checkpoint.stage {
        case .detecting:
            return "物体検出 \(checkpoint.lastProcessedFrame)/\(checkpoint.totalFrames) フレーム"
        case .segmenting:
            return "選手の識別・シーンの区切りの前で中断しました"
        case .commentating:
            let done = checkpoint.segments?.filter { $0.commentary != nil }.count ?? 0
            let total = checkpoint.segments?.count ?? 0
            return "シーン解説 \(done)/\(total)"
        }
    }

    // MARK: - Analyzing View

    private var analyzingView: some View {
        VStack(spacing: 30) {
            if let url = viewModel.activeVideoURL {
                VideoPlayerView(videoURL: url)
                    .frame(height: 250)
                    .cornerRadius(12)
                    .shadow(radius: 5)
                    .padding()
            }

            VStack(spacing: 15) {
                Text(viewModel.activeVideoURL?.lastPathComponent ?? "")
                    .font(.headline)
                    .lineLimit(1)

                if let isUsingRealModel = viewModel.isUsingRealModel {
                    Label(
                        isUsingRealModel ? "サッカー検出モデル" : "モックモード（モデル未配置）",
                        systemImage: isUsingRealModel ? "cpu" : "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(isUsingRealModel ? .green : .orange)
                }
            }

            analysisProgressCard
                .padding(.horizontal, 40)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()
        }
    }

    // MARK: - Analysis Result View

    @ViewBuilder
    private var analysisResultView: some View {
        if let id = viewModel.currentRecordID, let record = store.record(for: id) {
            AnalysisResultView(record: record)
                .id(id)
        } else if let errorMessage = viewModel.errorMessage {
            ContentUnavailableView(
                "結果を表示できません",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        }
    }

    // MARK: - Analysis Progress

    /// 解析中の進捗（操作をブロックしない）
    private var analysisProgressCard: some View {
        VStack(spacing: 12) {
            HStack {
                ProgressView()
                Text("解析中（\(viewModel.phase.label)）")
                    .font(.headline)
                Spacer()
                Text("\(Int(viewModel.analysisProgress * 100))%")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: viewModel.analysisProgress)
                .progressViewStyle(.linear)

            HStack {
                Text(viewModel.progressDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("一時停止", role: .cancel) {
                    viewModel.cancelAnalysis()
                }
                .font(.caption)
            }

            Text("他のタブへの移動やアプリを閉じても解析は続きます。中断しても続きから再開できます。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Helper Methods

    private func loadVideo(from item: PhotosPickerItem?) async {
        guard let item = item else { return }
        viewModel.errorMessage = nil

        do {
            let movie = try await importer.load(item)
            viewModel.startNewAnalysis(videoAt: movie.url)
        } catch is CancellationError {
            // ユーザーが読み込みをキャンセルした
        } catch {
            viewModel.errorMessage = "エラー: \(error.localizedDescription)"
        }
    }
}

// 動画を転送可能にするための構造体
struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let fileName = received.file.lastPathComponent
            let copy = URL.documentsDirectory.appending(path: fileName)

            if FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: copy)
            }

            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}

#Preview {
    let store = AnalysisStore()
    VideoAnalysisView()
        .environment(store)
        .environment(VideoAnalysisViewModel(store: store))
}
