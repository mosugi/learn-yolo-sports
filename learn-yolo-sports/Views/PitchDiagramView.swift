//
//  PitchDiagramView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI

/// ピッチを上から見た配置図（戦術ボード）
///
/// 画面の向きに合わせ、上が奥のタッチライン、左が画面左のゴール。
struct PitchDiagramView: View {
    let snapshot: PitchSnapshot
    let setup: AnalysisSetup

    private var length: Double { setup.pitchLength }
    private var width: Double { setup.pitchWidth }

    var body: some View {
        VStack(spacing: 6) {
            Canvas { context, size in
                draw(in: context, size: size)
            }
            .aspectRatio(length / width, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 12) {
                legend(color: TeamSide.own.color, text: TeamSide.own.displayName)
                legend(color: TeamSide.opponent.color, text: TeamSide.opponent.displayName)
                legend(color: .white, text: "ボール")
                Spacer()
                Text(setup.ownAttacksRight ? "自チームの攻撃方向 →" : "← 自チームの攻撃方向")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 0.5))
                .frame(width: 8, height: 8)
            Text(text)
        }
    }

    // MARK: - Drawing

    private func draw(in context: GraphicsContext, size: CGSize) {
        let scale = size.width / length
        func p(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * scale, y: point.y * scale)
        }
        func r(_ meters: Double) -> Double { meters * scale }

        // 芝とライン
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.16, green: 0.45, blue: 0.24)))

        let s = setup.lengthScale
        var lines = Path()
        lines.addRect(CGRect(x: 0, y: 0, width: r(length), height: r(width)).insetBy(dx: 1, dy: 1))
        lines.move(to: p(CGPoint(x: length / 2, y: 0)))
        lines.addLine(to: p(CGPoint(x: length / 2, y: width)))
        let circleRadius = r(9.15 * s)
        lines.addEllipse(in: CGRect(
            x: r(length / 2) - circleRadius,
            y: r(width / 2) - circleRadius,
            width: circleRadius * 2,
            height: circleRadius * 2
        ))
        let boxDepth = 16.5 * s
        let boxWidth = min(40.3 * s, width * 0.8)
        lines.addRect(CGRect(x: 0, y: r((width - boxWidth) / 2), width: r(boxDepth), height: r(boxWidth)))
        lines.addRect(CGRect(x: r(length - boxDepth), y: r((width - boxWidth) / 2), width: r(boxDepth), height: r(boxWidth)))
        context.stroke(lines, with: .color(.white.opacity(0.7)), lineWidth: 1)

        // 強調表示
        switch snapshot.highlight {
        case .none:
            break
        case .teamBox:
            if let box = boundingBox(of: snapshot.own) {
                let rect = CGRect(x: r(box.minX), y: r(box.minY), width: r(box.width), height: r(box.height))
                context.fill(Path(rect), with: .color(TeamSide.own.color.opacity(0.15)))
                context.stroke(Path(rect), with: .color(TeamSide.own.color), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
        case .ballRadius(let radius):
            if let ball = snapshot.ball {
                let center = p(ball)
                let rect = CGRect(x: center.x - r(radius), y: center.y - r(radius), width: r(radius) * 2, height: r(radius) * 2)
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.12)))
                context.stroke(Path(ellipseIn: rect), with: .color(.white), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
        case .movements(let movements):
            for movement in movements {
                drawArrow(in: context, from: p(movement.from), to: p(movement.to), color: TeamSide.own.color)
            }
        }

        // 選手とボール
        let dot = max(5, size.width / 45)
        for position in snapshot.opponent {
            drawPlayer(in: context, at: p(position), size: dot, color: TeamSide.opponent.color, isGoalkeeper: false)
        }
        for position in snapshot.opponentGoalkeepers {
            drawPlayer(in: context, at: p(position), size: dot, color: TeamSide.opponent.color, isGoalkeeper: true)
        }
        for position in snapshot.own {
            drawPlayer(in: context, at: p(position), size: dot, color: TeamSide.own.color, isGoalkeeper: false)
        }
        for position in snapshot.ownGoalkeepers {
            drawPlayer(in: context, at: p(position), size: dot, color: TeamSide.own.color, isGoalkeeper: true)
        }
        if let ball = snapshot.ball {
            let center = p(ball)
            let rect = CGRect(x: center.x - dot * 0.4, y: center.y - dot * 0.4, width: dot * 0.8, height: dot * 0.8)
            context.fill(Path(ellipseIn: rect), with: .color(.white))
            context.stroke(Path(ellipseIn: rect), with: .color(.black), lineWidth: 1)
        }
    }

    private func drawPlayer(in context: GraphicsContext, at center: CGPoint, size: CGFloat, color: Color, isGoalkeeper: Bool) {
        let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        if isGoalkeeper {
            // GK は枠だけで描き分ける
            context.fill(Path(ellipseIn: rect), with: .color(.black.opacity(0.5)))
            context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 2)
        } else {
            context.fill(Path(ellipseIn: rect), with: .color(color))
            context.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.5)), lineWidth: 0.5)
        }
    }

    private func drawArrow(in context: GraphicsContext, from start: CGPoint, to end: CGPoint, color: Color) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 2 else { return }
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)

        let angle = atan2(dy, dx)
        let head: CGFloat = 6
        for offset in [CGFloat.pi * 0.8, -CGFloat.pi * 0.8] {
            path.move(to: end)
            path.addLine(to: CGPoint(x: end.x + cos(angle + offset) * head, y: end.y + sin(angle + offset) * head))
        }
        context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 1.5)
    }

    private func boundingBox(of points: [CGPoint]) -> CGRect? {
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

#Preview {
    let setup = AnalysisSetup(
        format: .elevenASide,
        pitchLength: 105,
        pitchWidth: 68,
        region: .fullPitch,
        imageCorners: [],
        ownColor: LabColor(l: 50, a: 0, b: -40),
        ownSamplePoint: .zero,
        ownAttacksRight: true
    )
    PitchDiagramView(
        snapshot: PitchSnapshot(
            time: 12,
            own: [CGPoint(x: 30, y: 15), CGPoint(x: 32, y: 30), CGPoint(x: 31, y: 45), CGPoint(x: 55, y: 20), CGPoint(x: 58, y: 40), CGPoint(x: 75, y: 34)],
            opponent: [CGPoint(x: 60, y: 30), CGPoint(x: 50, y: 50), CGPoint(x: 70, y: 20)],
            ownGoalkeepers: [CGPoint(x: 4, y: 34)],
            opponentGoalkeepers: [CGPoint(x: 101, y: 34)],
            ball: CGPoint(x: 57, y: 38),
            highlight: .teamBox
        ),
        setup: setup
    )
    .padding()
}
