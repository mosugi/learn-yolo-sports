//
//  ContentView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            VideoAnalysisView()
                .tabItem {
                    Label("YOLO解析", systemImage: "video.badge.waveform")
                }
            
            VideoPickerView()
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

#Preview {
    ContentView()
        .environment(VideoAnalysisViewModel())
}
