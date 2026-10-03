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
    /// コート設定に使うフレーム（取得できたら設定画面を開く）
    @State private var setupFrame: SetupFrame?
    @State private var isLoadingSetupFrame = false
    
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
                if viewModel.hasResults && !viewModel.isAnalyzing {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            viewModel.closeResult()
                        } label: {
                            Label("設定に戻る", systemImage: "slider.horizontal.3")
                        }
                    }
                }
                
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
            .sheet(item: $setupFrame) { frame in
                CourtSetupView(image: frame.image, initialSetup: viewModel.setup) { setup in
                    viewModel.applySetup(setup, image: frame.image)
                }
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
        ScrollView {
            VStack(spacing: 20) {
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
                            Label("\(viewModel.settings.framesPerSecond) FPS", systemImage: "film")
                            Label("\(CoachReport.time(viewModel.settings.startTime)) から \(durationText(viewModel.settings.duration))", systemImage: "timer")
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
                        courtSetupCard
                            .padding(.horizontal, 40)
                    
                        if let errorMessage = viewModel.errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                    
                        startButton
                    }
                }
            }
            .padding(.bottom)
        }
    }
    
    /// コート・チームの設定状況
    private var courtSetupCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: viewModel.setup == nil ? "sportscourt" : "checkmark.circle.fill")
                    .foregroundStyle(viewModel.setup == nil ? Color.secondary : Color.green)
                Text("コート・チームの設定")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    Task { await openCourtSetup() }
                } label: {
                    if isLoadingSetupFrame {
                        ProgressView()
                    } else {
                        Text(viewModel.setup == nil ? "設定する" : "変更")
                    }
                }
                .disabled(isLoadingSetupFrame)
            }
            
            if let setup = viewModel.setup {
                Text("\(setup.format.displayName)・\(Int(setup.pitchLength))x\(Int(setup.pitchWidth)) m・自チームは画面\(setup.ownAttacksRight ? "右" : "左")へ攻撃")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("設定するとコート外の選手を除外し、チーム分けとコーチ解説を行います。未設定の場合は物体検出のみです。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private var startButton: some View {
        Button {
            viewModel.startAnalysis()
        } label: {
            Label(viewModel.setup == nil ? "解析開始（検出のみ）" : "解析開始", systemImage: "play.fill")
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
        @Bindable var viewModel = viewModel
        let videoDuration = max(1, viewModel.videoDuration ?? 600)
        
        return NavigationStack {
            Form {
                Section("解析する区間") {
                    VStack(alignment: .leading) {
                        Text("開始位置: \(CoachReport.time(viewModel.settings.startTime))")
                        Slider(value: $viewModel.settings.startTime, in: 0...max(1, videoDuration - 1), step: 1)
                    }
                    Stepper(
                        "長さ: \(durationText(viewModel.settings.duration))",
                        value: $viewModel.settings.duration,
                        in: 15...2700,
                        step: viewModel.settings.duration >= 300 ? 60 : 15
                    )
                    Button("動画の最後まで") {
                        viewModel.settings.duration = min(2700, max(15, (videoDuration - viewModel.settings.startTime).rounded(.up)))
                    }
                    Text("約 \(Int(viewModel.settings.duration) * viewModel.settings.framesPerSecond) フレームを処理します")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Section("検出") {
                    Stepper("フレームレート: \(viewModel.settings.framesPerSecond) FPS", value: $viewModel.settings.framesPerSecond, in: 1...10)
                }
                
                Section("説明") {
                    Text("フレームは1枚ずつ処理して手放すため、区間を長くしてもメモリは増えません。処理時間は「長さ x フレームレート」に比例します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("選手の追跡とボール保持の判定には 3〜5 FPS 程度を推奨します。1〜2 FPS では切り替えの局面が判定しにくくなります。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("得点シーンを探す場合は、試合全体（最長 45 分）を 2 FPS 程度で解析すると処理時間を抑えられます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("カメラを固定して撮影した動画が対象です。カメラが動いたフレームは戦術分析から除外されます。")
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
        .presentationDetents([.medium, .large])
    }
    
    private func durationText(_ seconds: Double) -> String {
        let value = Int(seconds)
        return value >= 60 ? "\(value / 60) 分 \(value % 60) 秒" : "\(value) 秒"
    }
    
    /// コート設定の画面を開く（解析の開始位置のフレームを使う）
    private func openCourtSetup() async {
        isLoadingSetupFrame = true
        defer { isLoadingSetupFrame = false }
        if let image = await viewModel.loadSetupFrame() {
            setupFrame = SetupFrame(image: image)
        }
    }
    
    // MARK: - Helper Methods
    
    private func loadVideo(from item: PhotosPickerItem?) async {
        guard let item = item else { return }
        
        do {
            guard let movie = try await item.loadTransferable(type: VideoTransferable.self) else {
                viewModel.errorMessage = "動画の読み込みに失敗しました"
                return
            }
            
            await viewModel.selectVideo(movie.url)
            
        } catch {
            viewModel.errorMessage = "エラー: \(error.localizedDescription)"
        }
    }
}

/// シートに渡すコート設定用のフレーム
private struct SetupFrame: Identifiable {
    let id = UUID()
    let image: CGImage
}

#Preview {
    let store = AnalysisStore()
    VideoAnalysisView()
        .environment(store)
        .environment(VideoAnalysisViewModel(store: store))
}
