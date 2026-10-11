//
//  LaunchOptions.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/09.
//

import Foundation

/// 起動引数（例: `-initialTab history -demoData YES`）で初期表示を切り替える
///
/// fastlane snapshot の UI テストから各画面を直接開くために使う。
enum LaunchOptions {
    /// 最初に開くタブ
    static var initialTab: ContentView.AppTab {
        UserDefaults.standard.string(forKey: "initialTab").flatMap(ContentView.AppTab.init(rawValue:)) ?? .analysis
    }
    
    /// スクリーンショット用のデモデータを表示する
    static var usesDemoData: Bool {
        UserDefaults.standard.bool(forKey: "demoData")
    }
    
    /// 解析結果画面で AI アドバイスを開いた状態にする
    static var showsAdvice: Bool {
        UserDefaults.standard.bool(forKey: "showAdvice")
    }
}
