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
    @State private var showingSettings = false
    @State private var framesPerSecond = 2
    @State private var maxFrames = 30
    
    var body: some View {
        NavigationStack {
            ZStack {
                if let _ = viewModel.videoURL, viewModel.hasResults {
                    // 解析結果表示
                    analysisResultView
                } else if viewModel.videoURL != nil {
                    // 動画選択済み（解析待ち・解析中）
                    analysisSetupView
                } else {
                    // 動画未選択
                    videoPickerView
                }
            }
            .navigationTitle("スポーツ動画解析")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel.videoURL != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            viewModel.reset()
                            selectedVideoItem = nil
                        } label: {
                            Label("リセット", systemImage: "arrow.clockwise")
                        }
                    }
                }
                
                if !viewModel.isAnalyzing && viewModel.videoURL != nil && !viewModel.hasResults {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingSettings.toggle()
                        } label: {
                            Label("設定", systemImage: "gearshape")
                        }
                    }
                }
            }
            .task {
                await viewModel.checkModel()
            }
            .sheet(isPresented: $showingSettings) {
                settingsSheet
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
        VStack(spacing: 30) {
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
            
            VStack(spacing: 10) {
                Text("スポーツ動画を解析")
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("YOLOで選手・審判・ボールを自動検出")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
        }
    }
    
    // MARK: - Analysis Setup View
    
    private var analysisSetupView: some View {
        VStack(spacing: 30) {
            if let url = viewModel.videoURL {
                // 動画プレビュー
                VideoPlayerView(videoURL: url)
                    .frame(height: 250)
                    .cornerRadius(12)
                    .shadow(radius: 5)
                    .padding()
                
                VStack(spacing: 15) {
                    Text(url.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                    
                    HStack(spacing: 20) {
                        Label("\(framesPerSecond) FPS", systemImage: "film")
                        Label("最大 \(maxFrames) フレーム", systemImage: "photo.stack")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    
                    if let isUsingRealModel = viewModel.isUsingRealModel {
                        Label(
                            isUsingRealModel ? "サッカー検出モデル" : "モックモード（モデル未配置）",
                            systemImage: isUsingRealModel ? "cpu" : "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(isUsingRealModel ? .green : .orange)
                    }
                }
                
                if viewModel.isAnalyzing {
                    analysisProgressCard
                        .padding(.horizontal, 40)
                } else {
                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    
                    startButton(url: url)
                }
            }
            
            Spacer()
        }
    }
    
    private func startButton(url: URL) -> some View {
        Button {
            viewModel.startAnalysis(
                url: url,
                framesPerSecond: framesPerSecond,
                maxFrames: maxFrames
            )
        } label: {
            Label("解析開始", systemImage: "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(
                    LinearGradient(
                        colors: [.green, .blue],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundStyle(.white)
                .cornerRadius(12)
        }
        .padding(.horizontal, 40)
    }
    
    // MARK: - Analysis Result View
    
    @ViewBuilder
    private var analysisResultView: some View {
        if let id = viewModel.currentRecordID, let record = store.record(for: id) {
            AnalysisResultView(record: record, frames: viewModel.detectionResults)
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
                Text("フレーム \(viewModel.currentFrame) / \(viewModel.totalFrames)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("キャンセル", role: .cancel) {
                    viewModel.cancelAnalysis()
                }
                .font(.caption)
            }
            
            Text("他のタブへの移動やアプリを閉じても解析は続きます")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Settings Sheet
    
    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("抽出設定") {
                    Stepper("フレームレート: \(framesPerSecond) FPS", value: $framesPerSecond, in: 1...10)
                    Stepper("最大フレーム数: \(maxFrames)", value: $maxFrames, in: 10...100, step: 10)
                }
                
                Section("説明") {
                    Text("フレームレートが高いほど詳細な解析ができますが、処理時間が長くなります。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("解析設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") {
                        showingSettings = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
    
    // MARK: - Helper Methods
    
    private func loadVideo(from item: PhotosPickerItem?) async {
        guard let item = item else { return }
        
        do {
            guard let movie = try await item.loadTransferable(type: VideoTransferable.self) else {
                viewModel.errorMessage = "動画の読み込みに失敗しました"
                return
            }
            
            viewModel.videoURL = movie.url
            
        } catch {
            viewModel.errorMessage = "エラー: \(error.localizedDescription)"
        }
    }
}

#Preview {
    let store = AnalysisStore()
    VideoAnalysisView()
        .environment(store)
        .environment(VideoAnalysisViewModel(store: store))
}
