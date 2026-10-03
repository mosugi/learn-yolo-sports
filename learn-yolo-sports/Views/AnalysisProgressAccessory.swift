//
//  AnalysisProgressAccessory.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI

/// タブバー上に表示する解析進捗のミニバー
struct AnalysisProgressAccessory: View {
    @Environment(VideoAnalysisViewModel.self) private var viewModel
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    
    /// タップ時に解析タブを開く
    let onOpen: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Gauge(value: viewModel.analysisProgress) {
                        EmptyView()
                    } currentValueLabel: {
                        Text("\(Int(viewModel.analysisProgress * 100))")
                            .monospacedDigit()
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .scaleEffect(0.5)
                    .frame(width: 28, height: 28)
                    
                    VStack(alignment: .leading, spacing: 0) {
                        Text("解析中")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        
                        // 折りたたみ時は幅が狭いため詳細を省く
                        if placement != .inline {
                            Text(viewModel.progressDescription)
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            Button {
                viewModel.cancelAnalysis()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("解析をキャンセル")
        }
        .padding(.horizontal)
    }
}
