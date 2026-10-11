//
//  ContentView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI

struct ContentView: View {
    enum AppTab: String, Hashable {
        case analysis
        case history
        case info
    }
    
    @Environment(VideoAnalysisViewModel.self) private var analysisViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = LaunchOptions.initialTab
    
    var body: some View {
        TabView(selection: $selectedTab) {
            VideoAnalysisView()
                .tabItem {
                    Label("YOLO解析", systemImage: "video.badge.waveform")
                }
                .badge(analysisBadge)
                .tag(AppTab.analysis)
            
            HistoryView()
                .tabItem {
                    Label("履歴", systemImage: "clock.arrow.circlepath")
                }
                .tag(AppTab.history)
            
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
        .onChange(of: scenePhase) { _, newValue in
            // バックグラウンドで生成できなかったAI解説をフォアグラウンド復帰時に再試行する
            if newValue == .active {
                analysisViewModel.appDidBecomeActive()
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
    let store = AnalysisStore()
    ContentView()
        .environment(store)
        .environment(VideoAnalysisViewModel(store: store))
}
