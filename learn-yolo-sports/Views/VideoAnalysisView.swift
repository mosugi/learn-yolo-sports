//
//  VideoAnalysisView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI
import PhotosUI

struct VideoAnalysisView: View {
    @State private var viewModel = VideoAnalysisViewModel()
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
                    // 動画選択済み、解析待ち
                    analysisSetupView
                } else {
                    // 動画未選択
                    videoPickerView
                }
                
                // 解析中のオーバーレイ
                if viewModel.isAnalyzing {
                    analyzingOverlay
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
                
                Button {
                    Task {
                        await viewModel.analyzeVideo(
                            url: url,
                            framesPerSecond: framesPerSecond,
                            maxFrames: maxFrames
                        )
                    }
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
            
            Spacer()
        }
    }
    
    // MARK: - Analysis Result View
    
    private var analysisResultView: some View {
        VStack(spacing: 0) {
            // 検出結果画像
            if let frameResult = viewModel.selectedFrameResult,
               let image = frameResult.image {
                
                GeometryReader { geometry in
                    ZStack {
                        Image(uiImage: UIImage(cgImage: image))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                        
                        DetectionOverlayView(
                            detections: frameResult.detections,
                            imageSize: CGSize(width: image.width, height: image.height),
                            displaySize: geometry.size
                        )
                    }
                }
                .background(Color.black)
                .frame(height: 300)
                
                // フレーム情報
                VStack(spacing: 5) {
                    Text("フレーム \(viewModel.selectedFrameIndex + 1) / \(viewModel.totalFrames)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text("\(frameResult.detections.count) 個検出")
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color(.systemBackground))
                
                // フレームスライダー
                HStack {
                    Button {
                        viewModel.previousFrame()
                    } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 44, height: 44)
                    }
                    .disabled(viewModel.selectedFrameIndex == 0)
                    
                    Slider(
                        value: Binding(
                            get: { Double(viewModel.selectedFrameIndex) },
                            set: { viewModel.selectedFrameIndex = Int($0) }
                        ),
                        in: 0...Double(max(0, viewModel.detectionResults.count - 1)),
                        step: 1
                    )
                    
                    Button {
                        viewModel.nextFrame()
                    } label: {
                        Image(systemName: "chevron.right")
                            .frame(width: 44, height: 44)
                    }
                    .disabled(viewModel.selectedFrameIndex >= viewModel.detectionResults.count - 1)
                }
                .padding(.horizontal)
                
                Divider()
                
                // 検出リスト
                if !frameResult.detections.isEmpty {
                    DetectionListView(detections: frameResult.detections)
                } else {
                    ContentUnavailableView(
                        "検出なし",
                        systemImage: "magnifyingglass",
                        description: Text("このフレームでは何も検出されませんでした")
                    )
                }
                
                // 統計情報
                if let result = viewModel.analysisResult {
                    VStack(spacing: 10) {
                        Divider()
                        
                        HStack(spacing: 20) {
                            StatView(
                                title: "総検出数",
                                value: "\(result.totalDetections)",
                                icon: "scope"
                            )
                            
                            StatView(
                                title: "平均",
                                value: String(format: "%.1f", result.averageDetectionsPerFrame),
                                icon: "chart.bar"
                            )
                            
                            StatView(
                                title: "処理時間",
                                value: String(format: "%.1fs", result.duration),
                                icon: "clock"
                            )
                        }
                        .padding()
                    }
                    .background(Color(.secondarySystemBackground))
                }
            }
        }
    }
    
    // MARK: - Analyzing Overlay
    
    private var analyzingOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
                
                VStack(spacing: 10) {
                    Text("解析中...")
                        .font(.headline)
                        .foregroundStyle(.white)
                    
                    Text("フレーム \(viewModel.currentFrame) / \(viewModel.totalFrames)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                    
                    ProgressView(value: viewModel.analysisProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 200)
                        .tint(.white)
                    
                    Text("\(Int(viewModel.analysisProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                
                Button("キャンセル") {
                    viewModel.cancelAnalysis()
                }
                .foregroundStyle(.white)
                .padding(.top, 10)
            }
            .padding(30)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
        }
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

// MARK: - Stat View

struct StatView: View {
    let title: String
    let value: String
    let icon: String
    
    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
            
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
            
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    VideoAnalysisView()
}
