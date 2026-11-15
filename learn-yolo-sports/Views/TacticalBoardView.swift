//
//  TacticalBoardView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/10.
//

import SwiftUI

/// 選択肢を番号付きの矢印で描くオーバーレイ（正規化座標の TacticalSnapshot を使う）
struct TacticalArrowsView: View, Animatable {
    let snapshot: TacticalSnapshot
    let recommendedOptionID: Int?
    let displaySize: CGSize
    /// 矢印を描く割合（0〜1）。アニメーションで 0 から 1 にすると、矢印が伸びていくように描かれる
    var progress: Double = 1

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    private static let recommendedColor = Color.yellow
    private static let otherColor = Color.white

    var body: some View {
        ZStack {
            Canvas { context, size in
                // 他の選択肢を先に描き、おすすめを最前面にする
                let ordered = snapshot.options.sorted { lhs, _ in lhs.id != recommendedOptionID }
                for option in ordered {
                    let isRecommended = option.id == recommendedOptionID
                    let color = isRecommended ? Self.recommendedColor : Self.otherColor.opacity(0.85)
                    let from = point(option.from, in: size)
                    let to = point(option.to, in: size)
                    // おすすめは他の矢印より少し遅れて伸ばし、目に留まるようにする
                    let local = isRecommended ? max(0, min(1, (progress - 0.25) / 0.75)) : min(1, progress / 0.75)
                    guard local > 0 else { continue }
                    drawArrow(
                        in: &context,
                        from: from,
                        to: CGPoint(x: from.x + (to.x - from.x) * local, y: from.y + (to.y - from.y) * local),
                        color: color,
                        lineWidth: isRecommended ? 4 : 2.5,
                        dashed: option.kind == .dribble
                    )
                }

                // ボール保持者の足元に輪を描く
                let carrier = point(snapshot.carrier, in: size)
                let ring = Path(ellipseIn: CGRect(x: carrier.x - 14, y: carrier.y - 6, width: 28, height: 12))
                context.stroke(ring, with: .color(Self.recommendedColor), lineWidth: 2.5)
            }

            ForEach(snapshot.options) { option in
                let isRecommended = option.id == recommendedOptionID
                Text("\(option.id)")
                    .font(.caption.bold())
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(isRecommended ? Self.recommendedColor : Self.otherColor))
                    .foregroundStyle(.black)
                    .scaleEffect(progress >= 1 && isRecommended ? 1.15 : 1)
                    .opacity(progress >= 1 ? 1 : 0)
                    .position(point(option.to, in: displaySize))
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
    }

    private func point(_ normalized: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: normalized.x * size.width, y: normalized.y * size.height)
    }

    private func drawArrow(in context: inout GraphicsContext, from: CGPoint, to: CGPoint, color: Color, lineWidth: CGFloat, dashed: Bool) {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let ux = dx / length, uy = dy / length

        // 番号の円と重ならないよう、終点を少し手前で止める
        let tip = CGPoint(x: to.x - ux * 13, y: to.y - uy * 13)
        let headLength: CGFloat = 12
        let headWidth: CGFloat = 7
        let base = CGPoint(x: tip.x - ux * headLength, y: tip.y - uy * headLength)

        var shaft = Path()
        shaft.move(to: from)
        shaft.addLine(to: base)
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: dashed ? [8, 6] : [])
        context.stroke(shaft, with: .color(.black.opacity(0.4)), style: StrokeStyle(lineWidth: lineWidth + 2, lineCap: .round, dash: style.dash))
        context.stroke(shaft, with: .color(color), style: style)

        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: base.x - uy * headWidth, y: base.y + ux * headWidth))
        head.addLine(to: CGPoint(x: base.x + uy * headWidth, y: base.y - ux * headWidth))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }
}

/// シーンの注目時点の静止画に、検出結果と選択肢の矢印を重ねて、選択肢の一覧と並べて表示する
struct TacticalBoardView: View {
    @Environment(AnalysisStore.self) private var store
    let record: SavedAnalysis
    let segment: SceneSegment
    let snapshot: TacticalSnapshot

    @State private var image: CGImage?

    private var aspectRatio: CGFloat {
        guard record.imageWidth > 0, record.imageHeight > 0 else { return 16.0 / 9.0 }
        return CGFloat(record.imageWidth) / CGFloat(record.imageHeight)
    }

    private var frame: SavedFrame? {
        record.frames.first { $0.frameNumber == snapshot.frameNumber }
    }

    private var attackingTeam: TeamInfo? {
        record.teams?.first { $0.id == snapshot.attackingTeam }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.forward.circle")
                Text("この場面の選択肢")
                    .font(.subheadline.bold())
                Spacer()
                if let attackingTeam {
                    Circle().fill(attackingTeam.color.color).frame(width: 10, height: 10)
                    Text("\(attackingTeam.name)の攻撃" + (snapshot.carrierLabel.map { "（\($0)）" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { geo in
                ZStack {
                    if let image {
                        Image(uiImage: UIImage(cgImage: image))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Color.black
                    }
                    if let frame {
                        DetectionOverlayView(detections: frame.detections, teams: record.teams, players: record.players, displaySize: geo.size, compact: true)
                    }
                    TacticalArrowsView(snapshot: snapshot, recommendedOptionID: segment.recommendedOptionID, displaySize: geo.size)
                }
            }
            .aspectRatio(aspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            ForEach(Array(snapshot.options.enumerated()), id: \.element.id) { index, option in
                optionRow(option, comment: segment.commentary?.optionComments?[safe: index])
            }

            Text("画面上の位置関係からの目安です。攻撃方向や画面外の選手は考慮していません。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .task(id: snapshot.frameNumber) {
            image = await store.loadFrameImage(for: record, frameNumber: snapshot.frameNumber)
        }
    }

    private func optionRow(_ option: TacticalOption, comment: String?) -> some View {
        let isRecommended = option.id == segment.recommendedOptionID
        return HStack(alignment: .top, spacing: 10) {
            Text("\(option.id)")
                .font(.caption.bold())
                .frame(width: 22, height: 22)
                .background(Circle().fill(isRecommended ? Color.yellow : Color(.systemGray4)))
                .foregroundStyle(.black)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(option.summary)
                        .font(.subheadline)
                    if isRecommended {
                        Text("おすすめ")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.yellow))
                            .foregroundStyle(.black)
                    }
                }
                if let comment {
                    Text(comment)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
