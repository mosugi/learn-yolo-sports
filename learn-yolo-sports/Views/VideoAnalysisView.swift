//
//  VideoAnalysisView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI
import PhotosUI

struct VideoAnalysisView: View {
    /// 読み込みがこの秒数を超えたら iCloud からのダウンロードの可能性を案内する
    private static let slowImportThreshold: TimeInterval = 5

    @Environment(VideoAnalysisViewModel.self) private var viewModel
    @Environment(AnalysisStore.self) private var store
    @State private var selectedVideoItem: PhotosPickerItem?
    /// 1チームの人数（識別する選手の数の上限）
    @AppStorage(AnalysisSettings.playersPerTeamKey) private var playersPerTeam = PlayerTracker.defaultPlayersPerTeam
    /// 動画読み込み（フォトライブラリからのコピー。iCloud にしかない場合はダウンロードも含む）の進捗
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

                VStack(alignment: .leading, spacing: 6) {
                    Text("1チームの人数")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Picker("1チームの人数", selection: $playersPerTeam) {
                        ForEach(AnalysisSettings.playersPerTeamOptions, id: \.self) { count in
                            Text(AnalysisSettings.label(forPlayersPerTeam: count)).tag(count)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.horizontal, 40)

                PhotosPicker(
                    selection: $selectedVideoItem,
                    matching: .videos,
                    // 写真ライブラリの識別子（itemIdentifier）を受け取り、同じ動画を見分けるために使う
                    photoLibrary: .shared()
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
                Image(systemName: "film.stack")
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

                // 端末内の動画はすぐ終わるため、時間がかかっているときだけ iCloud の可能性を伝える
                if let startDate = importer.startDate,
                   context.date.timeIntervalSince(startDate) > Self.slowImportThreshold {
                    Text("端末に保存されていない動画は、iCloud からのダウンロードに時間がかかることがあります")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

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
            AnalysisLivePreviewView(preview: viewModel.livePreview)
                .frame(height: 250)
                .cornerRadius(12)
                .shadow(radius: 5)
                .padding()

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

            if viewModel.isReusingDetections {
                Label("前に解析した動画のため、保存済みの検出結果を使って解析し直しています", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

        // 同じ動画を解析したことがあれば、読み込みも検出も省いて前回の検出結果から解析し直す
        let assetIdentifier = item.itemIdentifier
        if let assetIdentifier,
           let recordID = await viewModel.reusableRecordID(for: VideoFingerprint(assetIdentifier: assetIdentifier)) {
            viewModel.reanalyze(recordID: recordID, fingerprint: VideoFingerprint(assetIdentifier: assetIdentifier))
            return
        }

        // 読み込み中にアプリを離れても止まらないよう、選んだ直後にバックグラウンド継続を申請する
        let importer = importer
        let session = viewModel.beginImportSession {
            importer.cancel()
        }

        do {
            let movie = try await importer.load(item) { fraction in
                session.update(fraction: fraction, subtitle: "動画を読み込み中 \(Int(fraction * 100))%")
            }
            let url = movie.url
            let fingerprint = try? await Task.detached(priority: .userInitiated) {
                try VideoFingerprint.make(fileAt: url, assetIdentifier: assetIdentifier)
            }.value

            // 写真ライブラリの識別子で見分けられなかった場合も、中身が同じなら前回の検出結果を使う
            if let fingerprint, let recordID = await viewModel.reusableRecordID(for: fingerprint) {
                try? FileManager.default.removeItem(at: url)
                session.finish(success: true)
                viewModel.reanalyze(recordID: recordID, fingerprint: fingerprint)
                return
            }
            viewModel.startNewAnalysis(videoAt: url, fingerprint: fingerprint, session: session)
        } catch is CancellationError {
            // ユーザーが読み込みをキャンセルした
            session.finish(success: false)
        } catch {
            viewModel.errorMessage = "エラー: \(error.localizedDescription)"
            session.finish(success: false)
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
            let destination = URL.documentsDirectory.appending(path: fileName)

            if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: destination)
            }

            // 受け取ったファイルが一時コピーなら、もう一度コピーせずに移動する（大きな動画で時間がかかるため）
            if received.isOriginalFile {
                try FileManager.default.copyItem(at: received.file, to: destination)
            } else {
                do {
                    try FileManager.default.moveItem(at: received.file, to: destination)
                } catch {
                    try FileManager.default.copyItem(at: received.file, to: destination)
                }
            }
            return Self(url: destination)
        }
    }
}

#Preview {
    let store = AnalysisStore()
    VideoAnalysisView()
        .environment(store)
        .environment(VideoAnalysisViewModel(store: store))
}
