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
    let frames: [FrameDetectionResult]
    
    @State private var selectedFrameIndex = 0
    
    private var selectedFrame: FrameDetectionResult? {
        guard frames.indices.contains(selectedFrameIndex) else { return nil }
        return frames[selectedFrameIndex]
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if let frameResult = selectedFrame {
                frameImage(frameResult)
                    .background(Color.black)
                    .frame(height: 300)
                
                // フレーム情報
                VStack(spacing: 5) {
                    Text("フレーム \(selectedFrameIndex + 1) / \(frames.count)（\(String(format: "%.1f", frameResult.timestamp))秒）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text("\(frameResult.detections.count) 個検出")
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color(.systemBackground))
                
                frameSlider
                
                Divider()
                
                // 検出リスト
                if !frameResult.detections.isEmpty {
                    DetectionListView(detections: frameResult.detections)
                } else {
                    ContentUnavailableView(
                        "検出なし",
                        systemImage: "magnifyingglass",
                        description: Text("このフレームでは何も検出されませんでした")
                    )
                }
                
                statistics
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                AnalysisShareMenu(record: record)
            }
        }
    }
    
    // MARK: - Components
    
    private func frameImage(_ frameResult: FrameDetectionResult) -> some View {
        GeometryReader { geometry in
            if let image = frameResult.image {
                ZStack {
                    Image(uiImage: UIImage(cgImage: image))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    
                    DetectionOverlayView(
                        detections: frameResult.detections,
                        imageSize: CGSize(width: image.width, height: image.height),
                        displaySize: geometry.size
                    )
                }
            } else {
                ContentUnavailableView("画像なし", systemImage: "photo")
                    .foregroundStyle(.white)
            }
        }
    }
    
    private var frameSlider: some View {
        HStack {
            Button {
                selectedFrameIndex -= 1
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
            }
            .disabled(selectedFrameIndex == 0)
            
            if frames.count > 1 {
                Slider(
                    value: Binding(
                        get: { Double(selectedFrameIndex) },
                        set: { selectedFrameIndex = Int($0) }
                    ),
                    in: 0...Double(frames.count - 1),
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
            .disabled(selectedFrameIndex >= frames.count - 1)
        }
        .padding(.horizontal)
    }
    
    private var statistics: some View {
        VStack(spacing: 10) {
            Divider()
            
            HStack(spacing: 20) {
                StatView(
                    title: "総検出数",
                    value: "\(record.totalDetections)",
                    icon: "scope"
                )
                
                StatView(
                    title: "平均",
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
