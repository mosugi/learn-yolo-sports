//
//  DetectionOverlayView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI

/// 検出結果をオーバーレイ表示するビュー（正規化座標の SavedDetection を使う）
struct DetectionOverlayView: View {
    let detections: [SavedDetection]
    let teams: [TeamInfo]?
    let displaySize: CGSize
    /// 小さな表示向け（細い枠・ラベルなし）
    var compact = false

    var body: some View {
        ZStack {
            ForEach(Array(detections.enumerated()), id: \.offset) { _, detection in
                let box = CGRect(
                    x: detection.boundingBox.minX * displaySize.width,
                    y: detection.boundingBox.minY * displaySize.height,
                    width: detection.boundingBox.width * displaySize.width,
                    height: detection.boundingBox.height * displaySize.height
                )
                let color = overlayColor(for: detection)

                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .strokeBorder(color, lineWidth: compact ? 1.5 : 3)
                        .background(color.opacity(0.1))

                    if !compact {
                        Text(label(for: detection))
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(4)
                            .background(color)
                            .foregroundStyle(.white)
                            .cornerRadius(4)
                            .fixedSize()
                            .offset(y: -22)
                    }
                }
                .frame(width: max(0, box.width), height: max(0, box.height))
                .position(x: box.midX, y: box.midY)
            }
        }
    }

    private func overlayColor(for detection: SavedDetection) -> Color {
        if let teamID = detection.team, let team = teams?.first(where: { $0.id == teamID }) {
            return team.color.color
        }
        return SportsClass(rawValue: detection.label)?.color ?? .gray
    }

    private func label(for detection: SavedDetection) -> String {
        var text: String
        if let teamID = detection.team, let team = teams?.first(where: { $0.id == teamID }) {
            text = team.name
        } else {
            text = SportsClass(rawValue: detection.label)?.japaneseName ?? detection.label
        }
        if let number = detection.jerseyNumber {
            text += " #\(number)"
        }
        return text
    }
}

#Preview {
    let mockDetections = [
        SavedDetection(
            label: "player",
            confidence: 0.92,
            boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.5),
            uniformColor: RGBColor(red: 0.8, green: 0.1, blue: 0.1),
            team: 0,
            jerseyNumber: 10
        ),
        SavedDetection(
            label: "ball",
            confidence: 0.85,
            boundingBox: CGRect(x: 0.6, y: 0.4, width: 0.1, height: 0.1)
        ),
    ]
    let teams = [TeamInfo(id: 0, name: "赤チーム", color: RGBColor(red: 0.8, green: 0.1, blue: 0.1))]

    DetectionOverlayView(detections: mockDetections, teams: teams, displaySize: CGSize(width: 320, height: 240))
        .frame(width: 320, height: 240)
        .background(Color.gray.opacity(0.3))
}
