//
//  ContentView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI
import PhotosUI
import AVFoundation
import AVKit
import Vision
import CoreML

struct ContentView: View {
    var body: some View {
        TabView {
            SimpleVideoAnalysisView()
                .tabItem {
                    Label("YOLO解析", systemImage: "video.badge.waveform")
                }
            
            SimpleVideoPickerView()
                .tabItem {
                    Label("動画再生", systemImage: "play.rectangle")
                }
            
            InfoView()
                .tabItem {
                    Label("情報", systemImage: "info.circle.fill")
                }
        }
    }
}

// MARK: - Simple Video Picker (すべてこのファイルに統合)

struct SimpleVideoPickerView: View {
    @State private var selectedVideoItem: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var isLoading = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let videoURL = videoURL {
                    SimpleVideoPlayerView(videoURL: videoURL)
                        .frame(height: 300)
                        .cornerRadius(12)
                        .padding()
                    
                    Button(role: .destructive) {
                        self.videoURL = nil
                        self.selectedVideoItem = nil
                    } label: {
                        Label("動画をクリア", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.red.opacity(0.1))
                            .foregroundStyle(.red)
                            .cornerRadius(10)
                    }
                    .padding(.horizontal)
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "video.badge.plus")
                            .font(.system(size: 80))
                            .foregroundStyle(.blue)
                        
                        Text("スポーツ動画を選択")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        PhotosPicker(selection: $selectedVideoItem, matching: .videos) {
                            Label("動画を選択", systemImage: "photo.on.rectangle")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                                .foregroundStyle(.white)
                                .cornerRadius(12)
                        }
                        .padding(.horizontal, 40)
                    }
                }
                
                Spacer()
            }
            .navigationTitle("動画再生")
            .onChange(of: selectedVideoItem) { _, newValue in
                Task {
                    await loadVideo(from: newValue)
                }
            }
        }
    }
    
    private func loadVideo(from item: PhotosPickerItem?) async {
        guard let item = item else { return }
        isLoading = true
        
        do {
            guard let movie = try await item.loadTransferable(type: VideoTransferable.self) else {
                isLoading = false
                return
            }
            videoURL = movie.url
            isLoading = false
        } catch {
            print("❌ 動画読み込みエラー: \(error)")
            isLoading = false
        }
    }
}

// MARK: - Simple Video Player

struct SimpleVideoPlayerView: View {
    let videoURL: URL
    @State private var player: AVPlayer?
    
    var body: some View {
        VStack {
            if let player = player {
                VideoPlayer(player: player)
                    .onAppear {
                        player.seek(to: .zero)
                    }
                    .onDisappear {
                        player.pause()
                    }
            } else {
                ProgressView("動画を準備中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }
        }
        .onAppear {
            player = AVPlayer(url: videoURL)
        }
        .onChange(of: videoURL) { _, _ in
            player = AVPlayer(url: videoURL)
        }
    }
}

// MARK: - Simple Video Analysis View

struct SimpleVideoAnalysisView: View {
    @State private var viewModel = SimpleVideoAnalysisViewModel()
    @State private var selectedVideoItem: PhotosPickerItem?
    @State private var showSettings = false
    @State private var framesPerSecond = 2
    @State private var maxFrames = 30
    
    var body: some View {
        NavigationStack {
            ZStack {
                if viewModel.hasResults {
                    resultsView
                } else if viewModel.videoURL != nil {
                    setupView
                } else {
                    pickerView
                }
                
                if viewModel.isAnalyzing {
                    analyzingOverlay
                }
            }
            .navigationTitle("YOLO解析")
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
                            showSettings.toggle()
                        } label: {
                            Label("設定", systemImage: "gearshape")
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                settingsSheet
            }
            .onChange(of: selectedVideoItem) { _, newValue in
                Task {
                    await loadVideo(from: newValue)
                }
            }
        }
    }
    
    private var pickerView: some View {
        VStack(spacing: 30) {
            Image(systemName: "video.badge.waveform")
                .font(.system(size: 100))
                .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            
            Text("スポーツ動画を解析")
                .font(.title)
                .fontWeight(.bold)
            
            Text("YOLOで選手やボールを自動検出")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            PhotosPicker(selection: $selectedVideoItem, matching: .videos) {
                Label("動画を選択", systemImage: "photo.on.rectangle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                    .foregroundStyle(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 40)
        }
    }
    
    private var setupView: some View {
        VStack(spacing: 30) {
            if let url = viewModel.videoURL {
                SimpleVideoPlayerView(videoURL: url)
                    .frame(height: 250)
                    .cornerRadius(12)
                    .padding()
                
                Button {
                    Task {
                        await viewModel.analyzeVideo(url: url, framesPerSecond: framesPerSecond, maxFrames: maxFrames)
                    }
                } label: {
                    Label("解析開始", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(LinearGradient(colors: [.green, .blue], startPoint: .leading, endPoint: .trailing))
                        .foregroundStyle(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 40)
            }
            Spacer()
        }
    }
    
    private var resultsView: some View {
        VStack(spacing: 0) {
            if let frameResult = viewModel.selectedFrameResult, let image = frameResult.image {
                GeometryReader { geometry in
                    ZStack {
                        Image(uiImage: UIImage(cgImage: image))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                        
                        DetectionOverlay(
                            detections: frameResult.detections,
                            imageSize: CGSize(width: image.width, height: image.height),
                            displaySize: geometry.size
                        )
                    }
                }
                .background(Color.black)
                .frame(height: 300)
                
                Text("フレーム \(viewModel.selectedFrameIndex + 1) / \(viewModel.totalFrames)")
                    .font(.caption)
                    .padding(.vertical, 8)
                
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
                
                DetectionList(detections: frameResult.detections)
            }
        }
    }
    
    private var analyzingOverlay: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
                
                Text("解析中...")
                    .font(.headline)
                    .foregroundStyle(.white)
                
                Text("フレーム \(viewModel.currentFrame) / \(viewModel.totalFrames)")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                
                ProgressView(value: viewModel.analysisProgress)
                    .frame(width: 200)
                    .tint(.white)
                
                Button("キャンセル") {
                    viewModel.cancelAnalysis()
                }
                .foregroundStyle(.white)
            }
            .padding(30)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
        }
    }
    
    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("抽出設定") {
                    Stepper("フレームレート: \(framesPerSecond) FPS", value: $framesPerSecond, in: 1...10)
                    Stepper("最大フレーム数: \(maxFrames)", value: $maxFrames, in: 10...100, step: 10)
                }
            }
            .navigationTitle("解析設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") {
                        showSettings = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
    
    private func loadVideo(from item: PhotosPickerItem?) async {
        guard let item = item else { return }
        
        do {
            guard let movie = try await item.loadTransferable(type: VideoTransferable.self) else {
                return
            }
            viewModel.videoURL = movie.url
        } catch {
            print("❌ エラー: \(error)")
        }
    }
}

// MARK: - Detection Overlay

struct DetectionOverlay: View {
    let detections: [Detection]
    let imageSize: CGSize
    let displaySize: CGSize
    
    var body: some View {
        GeometryReader { geometry in
            ForEach(detections) { detection in
                let scaledBox = scaleBox(detection.boundingBox)
                
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .strokeBorder(detection.color, lineWidth: 3)
                        .background(detection.color.opacity(0.1))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SportsClass(rawValue: detection.label)?.japaneseName ?? detection.label)
                            .font(.caption2)
                            .fontWeight(.bold)
                        Text("\(detection.confidencePercentage)%")
                            .font(.caption2)
                    }
                    .padding(4)
                    .background(detection.color)
                    .foregroundStyle(.white)
                    .cornerRadius(4)
                    .offset(y: -30)
                }
                .frame(width: scaledBox.width, height: scaledBox.height)
                .position(x: scaledBox.midX, y: scaledBox.midY)
            }
        }
    }
    
    private func scaleBox(_ box: CGRect) -> CGRect {
        let scaleX = displaySize.width / imageSize.width
        let scaleY = displaySize.height / imageSize.height
        
        return CGRect(
            x: box.origin.x * scaleX,
            y: box.origin.y * scaleY,
            width: box.width * scaleX,
            height: box.height * scaleY
        )
    }
}

// MARK: - Detection List

struct DetectionList: View {
    let detections: [Detection]
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(detections) { detection in
                    HStack {
                        Circle()
                            .fill(detection.color)
                            .frame(width: 12, height: 12)
                        
                        Text(SportsClass(rawValue: detection.label)?.japaneseName ?? detection.label)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Spacer()
                        
                        Text("\(detection.confidencePercentage)%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(detection.color.opacity(0.2))
                            .cornerRadius(8)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(.systemBackground))
                    .cornerRadius(10)
                }
            }
            .padding()
        }
    }
}

// MARK: - Simple ViewModel

@MainActor
@Observable
class SimpleVideoAnalysisViewModel {
    var videoURL: URL?
    var isAnalyzing = false
    var analysisProgress: Double = 0.0
    var currentFrame: Int = 0
    var totalFrames: Int = 0
    var detectionResults: [FrameDetectionResult] = []
    var selectedFrameIndex: Int = 0
    
    var selectedFrameResult: FrameDetectionResult? {
        guard selectedFrameIndex < detectionResults.count else { return nil }
        return detectionResults[selectedFrameIndex]
    }
    
    var hasResults: Bool {
        !detectionResults.isEmpty
    }
    
    private let frameExtractor = VideoFrameExtractor()
    private let detector = YOLODetector()
    
    func analyzeVideo(url: URL, framesPerSecond: Int, maxFrames: Int) async {
        isAnalyzing = true
        analysisProgress = 0.0
        currentFrame = 0
        detectionResults = []
        videoURL = url
        
        do {
            let frames = try await frameExtractor.extractFrames(from: url, fps: framesPerSecond, maxFrames: maxFrames) { current, total in
                Task { @MainActor in
                    self.currentFrame = current
                    self.totalFrames = total
                    self.analysisProgress = Double(current) / Double(total) * 0.5
                }
            }
            
            totalFrames = frames.count
            var results: [FrameDetectionResult] = []
            
            for (index, frame) in frames.enumerated() {
                let detections = try await detector.detect(image: frame)
                results.append(FrameDetectionResult(frameNumber: index, timestamp: Double(index), detections: detections, image: frame))
                currentFrame = index + 1
                analysisProgress = 0.5 + (Double(index + 1) / Double(frames.count) * 0.5)
            }
            
            detectionResults = results
            isAnalyzing = false
        } catch {
            print("❌ エラー: \(error)")
            isAnalyzing = false
        }
    }
    
    func cancelAnalysis() {
        isAnalyzing = false
    }
    
    func reset() {
        videoURL = nil
        isAnalyzing = false
        analysisProgress = 0.0
        currentFrame = 0
        totalFrames = 0
        detectionResults = []
        selectedFrameIndex = 0
    }
    
    func nextFrame() {
        if selectedFrameIndex < detectionResults.count - 1 {
            selectedFrameIndex += 1
        }
    }
    
    func previousFrame() {
        if selectedFrameIndex > 0 {
            selectedFrameIndex -= 1
        }
    }
}

// MARK: - Info View

// 情報表示用のビュー
struct InfoView: View {
    @State private var isAnimating = false
    @State private var textOpacity = 0.0
    @State private var scale = 0.5
    @State private var rotation = 0.0
    
    var body: some View {
        NavigationStack {
            ZStack {
                // グラデーション背景
                LinearGradient(
                    colors: [.purple, .blue, .pink],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                .hueRotation(.degrees(isAnimating ? 45 : 0))
                .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: isAnimating)
                
                VStack(spacing: 30) {
                    // アニメーションするスポーツアイコン
                    Image(systemName: "sportscourt.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, .cyan, .blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .rotationEffect(.degrees(rotation))
                        .shadow(color: .white.opacity(0.5), radius: 20)
                        .scaleEffect(scale)
                    
                    VStack(spacing: 10) {
                        Text("Sports")
                            .font(.system(size: 50, weight: .thin, design: .rounded))
                            .foregroundStyle(.white)
                            .opacity(textOpacity)
                        
                        Text("Analyzer")
                            .font(.system(size: 60, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.yellow, .orange, .pink],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .shadow(color: .pink.opacity(0.8), radius: 10, x: 0, y: 5)
                            .opacity(textOpacity)
                        
                        Text("YOLO Sports Edition")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                            .opacity(textOpacity)
                            .padding(.top, 5)
                    }
                    
                    // 装飾的なシンボル
                    HStack(spacing: 20) {
                        ForEach(0..<5) { index in
                            Circle()
                                .fill(.white.opacity(0.7))
                                .frame(width: 10, height: 10)
                                .scaleEffect(isAnimating ? 1.5 : 0.5)
                                .animation(
                                    .easeInOut(duration: 1)
                                        .repeatForever(autoreverses: true)
                                        .delay(Double(index) * 0.2),
                                    value: isAnimating
                                )
                        }
                    }
                }
            }
            .navigationTitle("アプリ情報")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // アイコンの回転とスケール
                withAnimation(.easeOut(duration: 1.5)) {
                    scale = 1.0
                }
                
                withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
                
                // テキストのフェードイン
                withAnimation(.easeIn(duration: 1.5).delay(0.5)) {
                    textOpacity = 1.0
                }
                
                // 背景とドットのアニメーション開始
                isAnimating = true
            }
        }
    }
}

#Preview {
    ContentView()
}

// 情報表示用のビュー
struct InfoView: View {
    @State private var isAnimating = false
    @State private var textOpacity = 0.0
    @State private var scale = 0.5
    @State private var rotation = 0.0
    
    var body: some View {
        NavigationStack {
            ZStack {
                // グラデーション背景
                LinearGradient(
                    colors: [.purple, .blue, .pink],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                .hueRotation(.degrees(isAnimating ? 45 : 0))
                .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: isAnimating)
                
                VStack(spacing: 30) {
                    // アニメーションするスポーツアイコン
                    Image(systemName: "sportscourt.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, .cyan, .blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .rotationEffect(.degrees(rotation))
                        .shadow(color: .white.opacity(0.5), radius: 20)
                        .scaleEffect(scale)
                    
                    VStack(spacing: 10) {
                        Text("Sports")
                            .font(.system(size: 50, weight: .thin, design: .rounded))
                            .foregroundStyle(.white)
                            .opacity(textOpacity)
                        
                        Text("Analyzer")
                            .font(.system(size: 60, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.yellow, .orange, .pink],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .shadow(color: .pink.opacity(0.8), radius: 10, x: 0, y: 5)
                            .opacity(textOpacity)
                        
                        Text("YOLO Sports Edition")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                            .opacity(textOpacity)
                            .padding(.top, 5)
                    }
                    
                    // 装飾的なシンボル
                    HStack(spacing: 20) {
                        ForEach(0..<5) { index in
                            Circle()
                                .fill(.white.opacity(0.7))
                                .frame(width: 10, height: 10)
                                .scaleEffect(isAnimating ? 1.5 : 0.5)
                                .animation(
                                    .easeInOut(duration: 1)
                                        .repeatForever(autoreverses: true)
                                        .delay(Double(index) * 0.2),
                                    value: isAnimating
                                )
                        }
                    }
                }
            }
            .navigationTitle("アプリ情報")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // 地球の回転とスケール
                withAnimation(.easeOut(duration: 1.5)) {
                    scale = 1.0
                }
                
                withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
                
                // テキストのフェードイン
                withAnimation(.easeIn(duration: 1.5).delay(0.5)) {
                    textOpacity = 1.0
                }
                
                // 背景とドットのアニメーション開始
                isAnimating = true
            }
        }
    }
}

#Preview {
    ContentView()
}
