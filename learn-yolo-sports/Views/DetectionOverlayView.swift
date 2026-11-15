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
    /// ラベルを置かない領域（重ねて表示するボタンなど）
    var reservedArea: CGRect? = nil
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
        let detections = visibleDetections
        let visibleLabels = isCompact ? [:] : labelPlacement(for: detections)
        ZStack {
            ForEach(Array(detections.enumerated()), id: \.offset) { _, detection in
                let box = rect(for: detection)
                let color = overlayColor(for: detection)
                Rectangle()
                    .strokeBorder(color, lineWidth: isCompact || detection.isExcluded ? 1.5 : 3)
                    .background(color.opacity(0.1))
                    .frame(width: max(0, box.width), height: max(0, box.height))
                    .modifier(PlayerTapModifier(playerID: detection.isExcluded ? nil : detection.playerID, onSelect: onSelectPlayer))
                    .position(x: box.midX, y: box.midY)
            }

            // ラベルは枠とは別の層にして、他の選手の枠に隠れないよう最前面に描く
            ForEach(visibleLabels.sorted(by: { $0.key < $1.key }), id: \.key) { index, placement in
                let detection = detections[index]
                Text(placement.text)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(overlayColor(for: detection))
                    .foregroundStyle(labelTextColor(for: detection))
                    .cornerRadius(4)
                    .fixedSize()
                    .position(x: placement.frame.midX, y: placement.frame.midY)
                    .allowsHitTesting(false)
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

    private static let labelHeight: CGFloat = 16

    private func rect(for detection: SavedDetection) -> CGRect {
        CGRect(
            x: detection.boundingBox.minX * displaySize.width,
            y: detection.boundingBox.minY * displaySize.height,
            width: detection.boundingBox.width * displaySize.width,
            height: detection.boundingBox.height * displaySize.height
        )
    }

    nonisolated struct LabelPlacement {
        let text: String
        let frame: CGRect
    }

    /// ラベルの置き場所。密集した場面で読めなくならないよう、ボールと手前（画面下側）の選手から順に、
    /// 枠の上（だめなら下）で、他のラベル・他の選手の枠・予約領域と重ならず画面に収まる位置に置く。
    /// どこにも置けないラベルは出さない
    private func labelPlacement(for detections: [SavedDetection]) -> [Int: LabelPlacement] {
        let order = detections.indices
            .filter { !detections[$0].isExcluded }
            .sorted { lhs, rhs in
                let lBall = detections[lhs].label == SportsClass.ball.rawValue
                let rBall = detections[rhs].label == SportsClass.ball.rawValue
                if lBall != rBall { return lBall }
                return detections[lhs].boundingBox.maxY > detections[rhs].boundingBox.maxY
            }
        let boxes = detections.map { rect(for: $0) }
        let bounds = CGRect(origin: .zero, size: displaySize)
        var placed: [CGRect] = reservedArea.map { [$0] } ?? []
        var result: [Int: LabelPlacement] = [:]
        for index in order {
            guard let text = label(for: detections[index]) else { continue }
            let box = boxes[index]
            // 文字幅はおおよその見積もり（caption2 の太字で全角 12pt、半角 8pt 程度）
            let width = text.reduce(CGFloat(10)) { $0 + ($1.isASCII ? 8 : 12) }
            let candidates = [box.minY - Self.labelHeight - 2, box.maxY + 2].map { y in
                // 画面からはみ出さないよう内側に寄せる
                CGRect(
                    x: min(max(0, box.midX - width / 2), max(0, bounds.width - width)),
                    y: min(max(0, y), max(0, bounds.height - Self.labelHeight)),
                    width: width,
                    height: Self.labelHeight
                )
            }
            func hitsLabel(_ frame: CGRect) -> Bool {
                placed.contains { $0.insetBy(dx: -1, dy: -1).intersects(frame) }
            }
            func hitsOtherBox(_ frame: CGRect) -> Bool {
                boxes.indices.contains { $0 != index && !detections[$0].isExcluded && boxes[$0].intersects(frame) }
            }
            // 小さなボールは隠れると見つけられないため、どのラベルも重ねない
            func hitsBall(_ frame: CGRect) -> Bool {
                boxes.indices.contains {
                    $0 != index && detections[$0].label == SportsClass.ball.rawValue && boxes[$0].insetBy(dx: -2, dy: -2).intersects(frame)
                }
            }
            // 他の枠にも重ならない位置を優先し、なければラベル同士が重ならない位置で妥協する
            guard let frame = candidates.first(where: { !hitsLabel($0) && !hitsOtherBox($0) })
                ?? candidates.first(where: { !hitsLabel($0) && !hitsBall($0) }) else { continue }
            placed.append(frame)
            result[index] = LabelPlacement(text: text, frame: frame)
        }
        return result
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

    /// 枠に添える呼び名。チームは枠の色で分かるため、呼び名のない選手にはラベルを付けない
    private func label(for detection: SavedDetection) -> String? {
        if let player = detection.playerID.flatMap({ id in players?.first { $0.id == id } }) {
            return player.label
        }
        guard let sportsClass = SportsClass(rawValue: detection.label) else { return detection.label }
        return sportsClass == .player ? nil : sportsClass.japaneseName
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
