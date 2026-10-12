//
//  PitchRadarView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/12.
//

import SwiftUI

/// サッカーゲームのレーダーのように、ピッチ全体を真上から見て選手とボールを動かす
///
/// 再生位置を自分で読み取って描き直すため、動画の再生に合わせてなめらかに動く。
struct PitchRadarView: View {
    let radar: PitchRadar
    let teams: [TeamInfo]?
    var focusedPlayerID: Int? = nil
    /// 現在の再生位置（秒）
    let currentTime: () -> Double

    /// 標準のピッチの縦横比（105m × 68m）
    static let pitchAspect = 105.0 / 68.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            Canvas { context, size in
                let time = currentTime()
                let pitch = CGRect(origin: .zero, size: size).insetBy(dx: 14, dy: 10)
                drawPitch(in: &context, rect: pitch)
                drawPlayers(in: &context, rect: pitch, time: time)
                drawBall(in: &context, rect: pitch, time: time)
            }
        }
        .aspectRatio(Self.pitchAspect + 0.1, contentMode: .fit)
        .background(
            LinearGradient(colors: [Color(red: 0.14, green: 0.45, blue: 0.2), Color(red: 0.1, green: 0.36, blue: 0.16)], startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func point(_ radarPoint: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + min(1.03, max(-0.03, radarPoint.x)) * rect.width,
            y: rect.minY + min(1.04, max(-0.04, radarPoint.y)) * rect.height
        )
    }

    // MARK: - Pitch

    private func drawPitch(in context: inout GraphicsContext, rect: CGRect) {
        // 芝の縞
        let stripes = 10
        for index in 0..<stripes where index.isMultiple(of: 2) {
            let width = rect.width / CGFloat(stripes)
            context.fill(Path(CGRect(x: rect.minX + CGFloat(index) * width, y: rect.minY, width: width, height: rect.height)), with: .color(.white.opacity(0.05)))
        }

        var lines = Path()
        lines.addRect(rect)
        lines.move(to: CGPoint(x: rect.midX, y: rect.minY))
        lines.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        let circle = rect.height * 9.15 / 68
        lines.addEllipse(in: CGRect(x: rect.midX - circle, y: rect.midY - circle, width: circle * 2, height: circle * 2))
        // ペナルティエリアとゴールエリア
        for left in [true, false] {
            for (depth, width) in [(16.5, 40.3), (5.5, 18.32)] {
                let w = rect.width * depth / 105, h = rect.height * width / 68
                let x = left ? rect.minX : rect.maxX - w
                lines.addRect(CGRect(x: x, y: rect.midY - h / 2, width: w, height: h))
            }
        }
        context.stroke(lines, with: .color(.white.opacity(0.75)), lineWidth: 1.2)
        context.fill(Path(ellipseIn: CGRect(x: rect.midX - 2, y: rect.midY - 2, width: 4, height: 4)), with: .color(.white.opacity(0.75)))

        // ゴール（動画から見つけたゴールは黄色）
        for left in [true, false] {
            let found = radar.goals.contains { ($0.side == .left) == left }
            let h = rect.height * 7.32 / 68
            let goal = CGRect(x: left ? rect.minX - 6 : rect.maxX, y: rect.midY - h / 2, width: 6, height: h)
            context.fill(Path(goal), with: .color(found ? .yellow.opacity(0.9) : .white.opacity(0.35)))
        }
    }

    // MARK: - Players

    private func drawPlayers(in context: inout GraphicsContext, rect: CGRect, time: Double) {
        for track in radar.tracks {
            guard let position = PitchRadar.position(in: track.samples, at: time) else { continue }
            let center = point(position, in: rect)
            let team = track.team.flatMap { id in teams?.first { $0.id == id } }
            let fill: Color = team?.color.color ?? (track.isGoalkeeper ? .orange : .gray)
            let radius: CGFloat = 6
            let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: circle.offsetBy(dx: 1, dy: 1.5)), with: .color(.black.opacity(0.35)))
            context.fill(Path(ellipseIn: circle), with: .color(fill))
            context.stroke(Path(ellipseIn: circle), with: .color(team?.color.isLight == true ? .gray : .white), lineWidth: 1.2)
            if track.id == focusedPlayerID {
                context.stroke(Path(ellipseIn: circle.insetBy(dx: -4, dy: -4)), with: .color(.yellow), lineWidth: 2.5)
            }
            context.draw(
                Text(track.label).font(.system(size: 8, weight: .bold)).foregroundColor(.white),
                at: CGPoint(x: center.x, y: center.y - radius - 6)
            )
        }
    }

    private func drawBall(in context: inout GraphicsContext, rect: CGRect, time: Double) {
        guard let position = PitchRadar.position(in: radar.ball, at: time, gap: 0.6, hold: 0.3) else { return }
        let center = point(position, in: rect)
        let ball = CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)
        context.fill(Path(ellipseIn: ball), with: .color(.white))
        context.stroke(Path(ellipseIn: ball), with: .color(.black), lineWidth: 1.2)
    }
}

/// 見つけたゴールを、動画の上に枠（ポストとクロスバー）として描く
struct GoalOverlayView: View {
    let radar: PitchRadar
    let frame: SavedFrame
    let displaySize: CGSize

    var body: some View {
        Canvas { context, size in
            for goal in radar.goals {
                drawGoal(goal, in: &context, size: size)
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .allowsHitTesting(false)
    }

    private func drawGoal(_ goal: PitchRadar.Goal, in context: inout GraphicsContext, size: CGSize) {
        let half = GroundProjection.units(meters: radar.goalSize.width / 2)
        let direction = radar.widthDirection
        let posts = [-half, half].map { offset in
            CGPoint(x: Double(goal.world.x) + Double(direction.x) * offset, y: Double(goal.world.y) + Double(direction.y) * offset)
        }
        let postHeight = GroundProjection.units(meters: radar.goalSize.height)
        var bases: [CGPoint] = [], tops: [CGPoint] = []
        for post in posts {
            guard let base = radar.screen(post, in: frame), let person = radar.personHeight(at: post, in: frame) else { return }
            bases.append(CGPoint(x: base.x * size.width, y: base.y * size.height))
            tops.append(CGPoint(x: base.x * size.width, y: (Double(base.y) - person * postHeight) * size.height))
        }
        // 画面からほとんど外れているときは描かない
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -size.width * 0.1, dy: -size.height * 0.1)
        guard bases.contains(where: bounds.contains) || tops.contains(where: bounds.contains) else { return }

        var frameLines = Path()
        frameLines.move(to: bases[0])
        frameLines.addLine(to: tops[0])
        frameLines.addLine(to: tops[1])
        frameLines.addLine(to: bases[1])
        context.stroke(frameLines, with: .color(.black.opacity(0.45)), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        context.stroke(frameLines, with: .color(.yellow), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        var mouth = Path()
        mouth.move(to: bases[0])
        mouth.addLine(to: bases[1])
        context.stroke(mouth, with: .color(.yellow.opacity(0.7)), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))

        let label = context.resolve(Text("ゴール").font(.caption2.bold()).foregroundColor(.black))
        let labelSize = label.measure(in: CGSize(width: 100, height: 30))
        let anchor = CGPoint(x: (tops[0].x + tops[1].x) / 2, y: min(tops[0].y, tops[1].y) - labelSize.height / 2 - 6)
        let background = CGRect(x: anchor.x - labelSize.width / 2 - 6, y: anchor.y - labelSize.height / 2 - 2, width: labelSize.width + 12, height: labelSize.height + 4)
        context.fill(Path(roundedRect: background, cornerRadius: background.height / 2), with: .color(.yellow))
        context.draw(label, at: anchor)
    }
}
