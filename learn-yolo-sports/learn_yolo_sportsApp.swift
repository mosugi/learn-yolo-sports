//
//  learn_yolo_sportsApp.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI

@main
struct learn_yolo_sportsApp: App {
    /// 解析はタブやアプリの状態に関係なく続くため、アプリ全体で1つ保持する
    @State private var analysisViewModel = VideoAnalysisViewModel()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(analysisViewModel)
        }
    }
}
