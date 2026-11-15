//
//  AnalysisLivePreviewView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/11.
//

import SwiftUI

/// 解析中に、いま処理しているフレーム（シーン解説中はそのシーンの場面）を検出枠付きで表示する
struct AnalysisLivePreviewView: View {
    let preview: AnalysisLivePreview?

    var body: some View {
        ZStack {
            Color.black

            if let preview {
                Image(decorative: preview.image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay {
                        GeometryReader { geo in
                            DetectionOverlayView(
                                detections: preview.detections,
                                teams: preview.teams,
                                players: preview.players,
                                displaySize: geo.size,
                                compact: true
                            )
                        }
                    }

                caption(for: preview)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(8)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
    }

    private func caption(for preview: AnalysisLivePreview) -> some View {
        HStack(spacing: 6) {
            if let segment = preview.segment {
                Image(systemName: segment.kind.systemImage)
                Text(segment.kind.japaneseName)
                Text("\(DurationText.clock(segment.startTime))–\(DurationText.clock(segment.endTime))")
                    .monospacedDigit()
            } else {
                Image(systemName: "viewfinder")
                Text(DurationText.clock(preview.timestamp))
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.6), in: Capsule())
    }
}
