//
//  DetectionOverlayView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI

/// 検出結果をオーバーレイ表示するビュー
struct DetectionOverlayView: View {
    let detections: [Detection]
    let imageSize: CGSize
    let displaySize: CGSize
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(detections) { detection in
                    let scaledBox = scaleBox(detection.boundingBox, from: imageSize, to: displaySize)
                    
                    ZStack(alignment: .topLeading) {
                        // バウンディングボックス
                        Rectangle()
                            .strokeBorder(detection.color, lineWidth: 3)
                            .background(detection.color.opacity(0.1))
                        
                        // ラベル
                        VStack(alignment: .leading, spacing: 2) {
                            Text(SportsClass(rawValue: detection.label)?.japaneseName ?? detection.label)
                                .font(.caption2)
                                .fontWeight(.bold)
                            
                            Text("\(detection.confidencePercentage)%")
                                .font(.caption2)
                        }
                        .padding(4)
                        .background(detection.color)
                        .foregroundStyle(.white)
                        .cornerRadius(4)
                        .offset(y: -30)
                    }
                    .frame(width: scaledBox.width, height: scaledBox.height)
                    .position(x: scaledBox.midX, y: scaledBox.midY)
                }
            }
        }
    }
    
    /// バウンディングボックスをスケーリング
    private func scaleBox(_ box: CGRect, from originalSize: CGSize, to displaySize: CGSize) -> CGRect {
        let scaleX = displaySize.width / originalSize.width
        let scaleY = displaySize.height / originalSize.height
        
        return CGRect(
            x: box.origin.x * scaleX,
            y: box.origin.y * scaleY,
            width: box.width * scaleX,
            height: box.height * scaleY
        )
    }
}

/// 検出結果リスト表示
struct DetectionListView: View {
    let detections: [Detection]
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(detections) { detection in
                    HStack {
                        Circle()
                            .fill(detection.color)
                            .frame(width: 12, height: 12)
                        
                        Text(SportsClass(rawValue: detection.label)?.japaneseName ?? detection.label)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Spacer()
                        
                        Text("\(detection.confidencePercentage)%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(detection.color.opacity(0.2))
                            .cornerRadius(8)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(.systemBackground))
                    .cornerRadius(10)
                    .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
                }
            }
            .padding()
        }
    }
}

#Preview("Overlay") {
    let mockDetections = [
        Detection(
            label: "person",
            confidence: 0.92,
            boundingBox: CGRect(x: 100, y: 100, width: 200, height: 300),
            color: .blue
        ),
        Detection(
            label: "sports ball",
            confidence: 0.85,
            boundingBox: CGRect(x: 300, y: 200, width: 80, height: 80),
            color: .red
        )
    ]
    
    DetectionOverlayView(
        detections: mockDetections,
        imageSize: CGSize(width: 640, height: 480),
        displaySize: CGSize(width: 320, height: 240)
    )
    .frame(width: 320, height: 240)
    .background(Color.gray.opacity(0.3))
}

#Preview("List") {
    let mockDetections = [
        Detection(
            label: "person",
            confidence: 0.92,
            boundingBox: CGRect(x: 100, y: 100, width: 200, height: 300),
            color: .blue
        ),
        Detection(
            label: "sports ball",
            confidence: 0.85,
            boundingBox: CGRect(x: 300, y: 200, width: 80, height: 80),
            color: .red
        ),
        Detection(
            label: "tennis racket",
            confidence: 0.78,
            boundingBox: CGRect(x: 150, y: 250, width: 100, height: 150),
            color: .green
        )
    ]
    
    DetectionListView(detections: mockDetections)
}
