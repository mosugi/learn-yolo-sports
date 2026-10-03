//
//  VideoPlayerView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI
import AVKit

struct VideoPlayerView: View {
    let videoURL: URL
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    
    var body: some View {
        VStack(spacing: 0) {
            if let player = player {
                VideoPlayer(player: player)
                    .onAppear {
                        // 動画を最初から再生する準備
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
            setupPlayer()
        }
        .onChange(of: videoURL) { oldValue, newValue in
            setupPlayer()
        }
    }
    
    private func setupPlayer() {
        player = AVPlayer(url: videoURL)
        
        // 動画の終了を監視
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem,
            queue: .main
        ) { _ in
            player?.seek(to: .zero)
        }
    }
}

#Preview {
    // プレビュー用のダミーURL
    if let url = Bundle.main.url(forResource: "sample", withExtension: "mp4") {
        VideoPlayerView(videoURL: url)
            .frame(height: 300)
    } else {
        Text("サンプル動画が見つかりません")
    }
}
