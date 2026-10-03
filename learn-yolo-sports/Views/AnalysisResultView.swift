//
//  AnalysisResultView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI
import UIKit

/// 解析結果の表示（解析直後と履歴の両方で使う）
struct AnalysisResultView: View {
    let record: SavedAnalysis

    private enum Tab: Hashable {
        case coach
        case detections
    }

    @State private var tab: Tab
    @State private var showingAdvice = false

    init(record: SavedAnalysis) {
        self.record = record
        _tab = State(initialValue: record.coachReport != nil ? .coach : .detections)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let report = record.coachReport, let setup = record.setup {
                Picker("表示", selection: $tab) {
                    Text("コーチ解説").tag(Tab.coach)
                    Text("検出結果").tag(Tab.detections)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                switch tab {
                case .coach:
                    CoachReportView(record: record, report: report, setup: setup)
                case .detections:
                    DetectionBrowserView(record: record)
                }
            } else {
                DetectionBrowserView(record: record)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                AnalysisShareMenu(record: record)
            }

            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingAdvice = true
                } label: {
                    Label("AIアドバイス", systemImage: "apple.intelligence")
                }
            }
        }
        .sheet(isPresented: $showingAdvice) {
            AdviceView(recordID: record.id)
        }
    }
}

// MARK: - Detection Browser

/// フレームごとの検出結果
struct DetectionBrowserView: View {
    let record: SavedAnalysis

    @State private var selectedFrameIndex = 0

    var body: some View {
        // 画像が保存されているフレームだけをたどる
        let frames = record.framesWithImages
        VStack(spacing: 0) {
            if frames.indices.contains(selectedFrameIndex) {
                let frame = frames[selectedFrameIndex]

                SavedFrameView(record: record, frame: frame)
                    .frame(height: 260)

                VStack(spacing: 5) {
                    Text("フレーム \(selectedFrameIndex + 1) / \(frames.count)（\(CoachReport.time(frame.timestamp))）")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    Text(detectionSummary(frame))
                        .font(.headline)
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)

                frameSlider(count: frames.count)

                Divider()

                ScrollView {
                    if frame.detections.isEmpty {
                        ContentUnavailableView(
                            "検出なし",
                            systemImage: "magnifyingglass",
                            description: Text("このフレームでは何も検出されませんでした")
                        )
                    } else {
                        DetectionListView(detections: frame.detections)
                    }
                }

                statistics
            } else {
                ContentUnavailableView("フレームがありません", systemImage: "photo.stack")
            }
        }
    }

    private func detectionSummary(_ frame: SavedFrame) -> String {
        let included = frame.detections.filter { !$0.isExcluded }
        let excluded = frame.detections.count - included.count
        guard record.setup != nil else { return "\(frame.detections.count) 個検出" }
        let own = included.filter { $0.team == .own }.count
        let opponent = included.filter { $0.team == .opponent }.count
        var text = "自チーム \(own)・相手 \(opponent)"
        if excluded > 0 {
            text += "（コート外 \(excluded)）"
        }
        return text
    }

    private func frameSlider(count: Int) -> some View {
        HStack {
            Button {
                selectedFrameIndex -= 1
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
            }
            .disabled(selectedFrameIndex == 0)

            if count > 1 {
                Slider(
                    value: Binding(
                        get: { Double(selectedFrameIndex) },
                        set: { selectedFrameIndex = Int($0) }
                    ),
                    in: 0...Double(count - 1),
                    step: 1
                )
            } else {
                Spacer()
            }

            Button {
                selectedFrameIndex += 1
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
            }
            .disabled(selectedFrameIndex >= count - 1)
        }
        .padding(.horizontal)
    }

    private var statistics: some View {
        VStack(spacing: 10) {
            Divider()

            HStack(spacing: 20) {
                StatView(
                    title: "解析フレーム",
                    value: "\(record.frames.count)",
                    icon: "photo.stack"
                )

                StatView(
                    title: "平均検出数",
                    value: String(format: "%.1f", record.averageDetectionsPerFrame),
                    icon: "chart.bar"
                )

                StatView(
                    title: "処理時間",
                    value: String(format: "%.1fs", record.processingDuration),
                    icon: "clock"
                )
            }
            .padding()
        }
        .background(Color(.secondarySystemBackground))
    }
}

// MARK: - Share Menu

/// 解析結果を LLM などへ共有するメニュー
struct AnalysisShareMenu: View {
    @Environment(AnalysisStore.self) private var store
    let record: SavedAnalysis

    var body: some View {
        let report = AnalysisReport.markdown(for: record)

        Menu {
            ShareLink(
                item: report,
                subject: Text("サッカー動画の解析結果"),
                preview: SharePreview("解析結果（LLM向けテキスト）")
            ) {
                Label("LLM向けテキストを共有", systemImage: "text.bubble")
            }

            Button {
                UIPasteboard.general.string = report
            } label: {
                Label("LLM向けテキストをコピー", systemImage: "doc.on.doc")
            }

            let jsonURL = store.jsonURL(for: record)
            if FileManager.default.fileExists(atPath: jsonURL.path()) {
                ShareLink(item: jsonURL, preview: SharePreview("analysis.json")) {
                    Label("JSONを共有", systemImage: "curlybraces")
                }
            }
        } label: {
            Label("共有", systemImage: "square.and.arrow.up")
        }
    }
}

// MARK: - Stat View

struct StatView: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)

            Text(value)
                .font(.title3)
                .fontWeight(.bold)

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
