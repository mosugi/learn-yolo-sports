//
//  learn_yolo_sportsApp.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI

@main
struct learn_yolo_sportsApp: App {
    @State private var store: AnalysisStore
    /// 解析はタブやアプリの状態に関係なく続くため、アプリ全体で1つ保持する
    @State private var analysisViewModel: VideoAnalysisViewModel
    
    init() {
        guard LaunchOptions.usesDemoData else {
            let store = AnalysisStore()
            _store = State(initialValue: store)
            _analysisViewModel = State(initialValue: VideoAnalysisViewModel(store: store))
            return
        }
        
        // スクリーンショット用: 実データとは別の一時ディレクトリにデモデータを保存して表示する
        let directory = URL.temporaryDirectory.appending(path: "DemoAnalyses", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: directory)
        let store = AnalysisStore(baseURL: directory)
        let viewModel = VideoAnalysisViewModel(store: store)
        let record = DemoData.make(directory: store.directoryURL(for: DemoData.id))
        viewModel.showDemo(record: record)
        _store = State(initialValue: store)
        _analysisViewModel = State(initialValue: viewModel)
        
        Task {
            try? await store.save(record)
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(analysisViewModel)
        }
    }
}
