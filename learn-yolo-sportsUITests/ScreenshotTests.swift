//
//  ScreenshotTests.swift
//  learn-yolo-sportsUITests
//
//  Created by mosugi on 2026/10/09.
//

import XCTest

/// fastlane snapshot で App Store 用スクリーンショットを撮影する UI テスト
///
/// 各画面は起動引数で直接開く（タブ操作に依存しないので iPhone / iPad 共通で動く）。
/// `-demoData YES` で、生成したピッチ画像と検出結果・アドバイスのデモデータを表示する。
final class ScreenshotTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }
    
    @MainActor
    func testScreenshots() {
        capture("01_Result", tab: "analysis", arguments: ["-demoData", "YES"], waitFor: "総検出数")
        capture("02_Advice", tab: "analysis", arguments: ["-demoData", "YES", "-showAdvice", "YES"], waitFor: "総評")
        capture("03_History", tab: "history", arguments: ["-demoData", "YES"], waitFor: "demo_match.mp4")
        capture("04_Start", tab: "analysis", waitFor: "スポーツ動画を解析")
    }
    
    @MainActor
    private func capture(_ name: String, tab: String, arguments: [String] = [], waitFor text: String) {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments += ["-initialTab", tab] + arguments
        app.launch()
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 10), "\(name): 「\(text)」が表示されません")
        snapshot(name)
        app.terminate()
    }
}
