//
//  VideoPickerView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI
import PhotosUI
import AVFoundation

struct VideoPickerView: View {
    @State private var selectedVideoItem: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let videoURL = videoURL {
                    // 動画が選択されている場合
                    VideoPlayerView(videoURL: videoURL)
                        .frame(height: 300)
                        .cornerRadius(12)
                        .padding()
                    
                    VStack(spacing: 10) {
                        Text("動画が読み込まれました")
                            .font(.headline)
                            .foregroundStyle(.green)
                        
                        Text(videoURL.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal)
                    }
                    
                    Button(role: .destructive) {
                        clearVideo()
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
                    // 動画が未選択の場合
                    VStack(spacing: 20) {
                        Image(systemName: "video.badge.plus")
                            .font(.system(size: 80))
                            .foregroundStyle(.blue)
                            .padding()
                        
                        Text("スポーツ動画を選択してください")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text("動画を選択すると、解析が可能になります")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
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
                        .padding(.top, 10)
                    }
                }
                
                if isLoading {
                    ProgressView("動画を読み込み中...")
                        .padding()
                }
                
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding()
                }
                
                Spacer()
            }
            .navigationTitle("動画解析")
            .onChange(of: selectedVideoItem) { oldValue, newValue in
                Task {
                    await loadVideo(from: newValue)
                }
            }
        }
    }
    
    private func loadVideo(from item: PhotosPickerItem?) async {
        guard let item = item else { return }
        
        isLoading = true
        errorMessage = nil
        
        do {
            // 動画データを取得
            guard let movie = try await item.loadTransferable(type: VideoTransferable.self) else {
                errorMessage = "動画の読み込みに失敗しました"
                isLoading = false
                return
            }
            
            videoURL = movie.url
            isLoading = false
            
            // 動画情報を取得
            if let url = videoURL {
                await printVideoInfo(url: url)
            }
            
        } catch {
            errorMessage = "エラー: \(error.localizedDescription)"
            isLoading = false
        }
    }
    
    private func clearVideo() {
        videoURL = nil
        selectedVideoItem = nil
        errorMessage = nil
    }
    
    private func printVideoInfo(url: URL) async {
        let asset = AVAsset(url: url)
        
        do {
            let duration = try await asset.load(.duration)
            let tracks = try await asset.load(.tracks)
            
            print("📹 動画情報:")
            print("  - 長さ: \(CMTimeGetSeconds(duration)) 秒")
            print("  - トラック数: \(tracks.count)")
            
            for track in tracks {
                let mediaType = try await track.load(.mediaType)
                if mediaType == .video {
                    let size = try await track.load(.naturalSize)
                    let fps = try await track.load(.nominalFrameRate)
                    print("  - 解像度: \(Int(size.width)) x \(Int(size.height))")
                    print("  - FPS: \(fps)")
                }
            }
        } catch {
            print("動画情報の取得に失敗: \(error)")
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
            
            if FileManager.default.fileExists(atPath: copy.path()) {
                try FileManager.default.removeItem(at: copy)
            }
            
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}

#Preview {
    VideoPickerView()
}
