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
        let store = AnalysisStore()
        _store = State(initialValue: store)
        _analysisViewModel = State(initialValue: VideoAnalysisViewModel(store: store))
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(analysisViewModel)
        }
    }
}
