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
    /// 識別した選手（枠に #10、A などの呼び名を出す）
    var players: [PlayerIdentity]? = nil
    let displaySize: CGSize
    /// 小さな表示向け（細い枠・ラベルなし）
    var compact = false
    /// 注目している選手。その選手の枠は PlayerFocusMarker が描くため除き、他の人は控えめに描く
    var focusedPlayerID: Int? = nil
    /// 指定すると、識別した選手の枠をタップしてその選手を選べるようにする（他の部分のタップは下の動画へ通す）
    var onSelectPlayer: ((Int) -> Void)? = nil

    private var visibleDetections: [SavedDetection] {
        guard let focusedPlayerID else { return detections }
        return detections.filter { $0.playerID != focusedPlayerID }
    }

    var body: some View {
        let isCompact = compact || focusedPlayerID != nil
        ZStack {
            ForEach(Array(visibleDetections.enumerated()), id: \.offset) { _, detection in
                let box = CGRect(
                    x: detection.boundingBox.minX * displaySize.width,
                    y: detection.boundingBox.minY * displaySize.height,
                    width: detection.boundingBox.width * displaySize.width,
                    height: detection.boundingBox.height * displaySize.height
                )
                let color = overlayColor(for: detection)

                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .strokeBorder(color, lineWidth: isCompact || detection.isExcluded ? 1.5 : 3)
                        .background(color.opacity(0.1))

                    if !isCompact && !detection.isExcluded {
                        Text(label(for: detection))
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(4)
                            .background(color)
                            .foregroundStyle(labelTextColor(for: detection))
                            .cornerRadius(4)
                            .fixedSize()
                            .offset(y: -22)
                    }
                }
                .frame(width: max(0, box.width), height: max(0, box.height))
                .modifier(PlayerTapModifier(playerID: detection.isExcluded ? nil : detection.playerID, onSelect: onSelectPlayer))
                .position(x: box.midX, y: box.midY)
            }
        }
        .opacity(focusedPlayerID == nil ? 1 : 0.5)
    }

    /// 選手の枠だけをタップできるようにする
    private struct PlayerTapModifier: ViewModifier {
        let playerID: Int?
        let onSelect: ((Int) -> Void)?

        func body(content: Content) -> some View {
            if let playerID, let onSelect {
                content
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(playerID) }
                    .accessibilityAddTraits(.isButton)
            } else {
                content.allowsHitTesting(false)
            }
        }
    }

    private func overlayColor(for detection: SavedDetection) -> Color {
        // コート外（観客など）は灰色の細い枠にする
        if detection.isExcluded { return .gray }
        if let teamID = detection.team, let team = teams?.first(where: { $0.id == teamID }) {
            return team.color.color
        }
        return SportsClass(rawValue: detection.label)?.color ?? .gray
    }

    /// 白いユニフォームのチームなど、明るい色の上では黒い文字にする
    private func labelTextColor(for detection: SavedDetection) -> Color {
        let team = detection.team.flatMap { teamID in teams?.first { $0.id == teamID } }
        return team?.color.isLight == true ? .black : .white
    }

    private func label(for detection: SavedDetection) -> String {
        let player = detection.playerID.flatMap { id in players?.first { $0.id == id } }
        if let teamID = detection.team, let team = teams?.first(where: { $0.id == teamID }) {
            return player.map { "\(team.name) \($0.label)" } ?? team.name
        }
        if let player { return player.label }
        return SportsClass(rawValue: detection.label)?.japaneseName ?? detection.label
    }
}

#Preview {
    let mockDetections = [
        SavedDetection(
            label: "player",
            confidence: 0.92,
            boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.5),
            team: 0,
            playerID: 0
        ),
        SavedDetection(
            label: "ball",
            confidence: 0.85,
            boundingBox: CGRect(x: 0.6, y: 0.4, width: 0.1, height: 0.1)
        ),
    ]
    let teams = [TeamInfo(id: 0, name: "赤チーム", color: RGBColor(red: 0.8, green: 0.1, blue: 0.1))]
    let players = [PlayerIdentity(id: 0, team: 0, jerseyNumber: 10, letter: nil, isGoalkeeper: false, firstSeen: 0, lastSeen: 10, frameCount: 30)]

    DetectionOverlayView(detections: mockDetections, teams: teams, players: players, displaySize: CGSize(width: 320, height: 240))
        .frame(width: 320, height: 240)
        .background(Color.gray.opacity(0.3))
}
