//
//  ContentView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI

struct ContentView: View {
    enum AppTab: Hashable {
        case analysis
        case player
        case info
    }
    
    @Environment(VideoAnalysisViewModel.self) private var analysisViewModel
    @State private var selectedTab: AppTab = .analysis
    
    var body: some View {
        TabView(selection: $selectedTab) {
            VideoAnalysisView()
                .tabItem {
                    Label("YOLO解析", systemImage: "video.badge.waveform")
                }
                .badge(analysisBadge)
                .tag(AppTab.analysis)
            
            VideoPickerView()
                .tabItem {
                    Label("動画再生", systemImage: "play.rectangle")
                }
                .tag(AppTab.player)
            
            InfoView()
                .tabItem {
                    Label("情報", systemImage: "info.circle.fill")
                }
                .tag(AppTab.info)
        }
        .tabViewBottomAccessory(isEnabled: analysisViewModel.isAnalyzing) {
            AnalysisProgressAccessory {
                selectedTab = .analysis
            }
        }
        .onChange(of: selectedTab) { _, newValue in
            if newValue == .analysis {
                analysisViewModel.markResultSeen()
            }
        }
        .onChange(of: analysisViewModel.hasUnseenResult) { _, newValue in
            // 解析タブを開いたまま完了した場合は確認済みとみなす
            if newValue && selectedTab == .analysis {
                analysisViewModel.markResultSeen()
            }
        }
    }
    
    /// 解析タブのバッジ（解析中は進捗、完了後は未確認の印）
    private var analysisBadge: Text? {
        if analysisViewModel.isAnalyzing {
            return Text("\(Int(analysisViewModel.analysisProgress * 100))%")
        }
        if analysisViewModel.hasUnseenResult {
            return Text("完了")
        }
        return nil
    }
}

#Preview {
    ContentView()
        .environment(VideoAnalysisViewModel())
}
