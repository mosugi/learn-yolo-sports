//
//  TelestrationOverlay.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/12.
//

import SwiftUI

extension TelestrationTone {
    var color: Color {
        switch self {
        case .highlight: return .yellow
        case .option: return .white
        case .actual: return .cyan
        case .muted: return Color.white.opacity(0.55)
        case .good: return .green
        case .defense: return Color(red: 1, green: 0.35, blue: 0.35)
        }
    }
}

/// 止めた場面に、書き込みを地面に貼り付いたように描く
///
/// 輪・矢印・塗りは地面上の形を作ってから画面に写すので、奥の選手ほど小さく、横長につぶれて見える。
/// 遠近が推定できなかった場面では、画面上の形で描く。
struct TelestrationOverlay: View, Animatable {
    let step: TelestrationStep
    let projection: GroundProjection?
    let displaySize: CGSize
    /// 書き込みの進み具合（0〜1）。要素ごとに少しずつずらして描く
    var progress: Double = 1

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let painter = TelestrationPainter(projection: projection, size: size)
            let count = step.marks.count
            for (index, mark) in step.marks.enumerated() {
                // 1 つ目から順に描き始め、それぞれ全体の半分ほどの時間をかけて描く
                let start = count > 1 ? Double(index) / Double(count) * 0.5 : 0
                let local = max(0, min(1, (progress - start) / 0.5))
                guard local > 0 else { continue }
                painter.draw(mark, progress: local, in: &context)
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .allowsHitTesting(false)
    }
}

/// 再生中に、ボールを持つ選手の足元の輪を追いかけて描く
struct TelestrationFollowView: View {
    let follows: [TelestrationFollow]
    let paths: [Int: PlayerFocusPath]
    let displaySize: CGSize
    /// 指定時刻の遠近
    let projection: (Double) -> GroundProjection?
    /// 現在の再生位置（秒）
    let currentTime: () -> Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            Canvas { context, size in
                let time = currentTime()
                guard let follow = follows.last(where: { $0.start <= time + 0.05 }),
                      let box = paths[follow.playerID]?.box(at: time) else { return }
                let painter = TelestrationPainter(projection: projection(time), size: size)
                painter.draw(.ring(at: CGPoint(x: box.midX, y: box.maxY), label: nil, tone: follow.tone), progress: 1, in: &context)
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .allowsHitTesting(false)
    }
}

/// 書き込みの要素を描く
private struct TelestrationPainter {
    let projection: GroundProjection?
    let size: CGSize

    /// 足元の輪の半径（m）
    private static let ringRadius = 0.75

    func draw(_ mark: TelestrationMark, progress: Double, in context: inout GraphicsContext) {
        let eased = 1 - pow(1 - progress, 3)
        switch mark {
        case let .ring(at, label, tone):
            drawRing(at: at, radius: GroundProjection.units(meters: Self.ringRadius) * (0.4 + 0.6 * eased), tone: tone, dashed: false, opacity: eased, in: &context)
            if let label, progress >= 1 {
                drawBadge(label, at: offset(screen(at), dy: 16), background: tone.color, in: &context)
            }
        case let .arrow(from, to, style, tone, badge):
            drawArrow(from: from, to: to, style: style, tone: tone, progress: eased, in: &context)
            if let badge, progress >= 1 {
                drawBadge(badge, at: screen(to), background: tone.color, in: &context)
            }
        case let .area(center, radius):
            drawArea(center: center, radius: radius * (0.6 + 0.4 * eased), opacity: eased, in: &context)
        case let .defensiveLine(points):
            drawDefensiveLine(points, progress: eased, in: &context)
        case let .distance(from, to, meters):
            drawDistance(from: from, to: to, meters: meters, progress: eased, in: &context)
        case let .ghost(at, label):
            drawGhost(at: at, label: label, opacity: eased, in: &context)
        }
    }

    // MARK: - Coordinates

    private func screen(_ normalized: CGPoint) -> CGPoint {
        CGPoint(x: normalized.x * size.width, y: normalized.y * size.height)
    }

    private func projected(_ point: CGPoint) -> CGPoint? {
        projection?.screen(point).map { screen($0) }
    }

    private func offset(_ point: CGPoint, dx: CGFloat = 0, dy: CGFloat = 0) -> CGPoint {
        CGPoint(x: point.x + dx, y: point.y + dy)
    }

    /// 地面上の点の並びを画面上の多角形にする（写せない点が 1 つでもあれば nil）
    private func polygon(_ points: [CGPoint]) -> Path? {
        let corners = points.compactMap { projected($0) }
        guard corners.count == points.count, corners.count >= 3 else { return nil }
        var path = Path()
        path.addLines(corners)
        path.closeSubpath()
        return path
    }

    private func groundCircle(center: CGPoint, radius: Double) -> [CGPoint] {
        (0..<40).map { index in
            let angle = Double(index) / 40 * 2 * .pi
            return CGPoint(x: Double(center.x) + radius * cos(angle), y: Double(center.y) + radius * sin(angle))
        }
    }

    // MARK: - Shapes

    private func drawRing(at foot: CGPoint, radius: Double, tone: TelestrationTone, dashed: Bool, opacity: Double, in context: inout GraphicsContext) {
        let path: Path
        if let center = projection?.ground(foot), let circle = polygon(groundCircle(center: center, radius: radius)) {
            path = circle
        } else {
            // 遠近が分からないときは、横長の楕円で地面に置いたように見せる
            let point = screen(foot)
            let width = CGFloat(radius) * 30
            path = Path(ellipseIn: CGRect(x: point.x - width / 2, y: point.y - width * 0.2, width: width, height: width * 0.4))
        }
        context.opacity = opacity
        defer { context.opacity = 1 }
        context.fill(path, with: .color(tone.color.opacity(0.25)))
        context.stroke(path, with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: 5, dash: dashed ? [6, 4] : []))
        context.stroke(path, with: .color(tone.color), style: StrokeStyle(lineWidth: 3, dash: dashed ? [6, 4] : []))
    }

    private func drawArrow(from: CGPoint, to: CGPoint, style: TelestrationArrowStyle, tone: TelestrationTone, progress: Double, in context: inout GraphicsContext) {
        guard let start = projection?.ground(from), let end = projection?.ground(to) else {
            drawScreenArrow(from: screen(from), to: screen(to), style: style, tone: tone, progress: progress, in: &context)
            return
        }
        let dx = Double(end.x - start.x), dy = Double(end.y - start.y)
        let length = hypot(dx, dy)
        guard length > 0.2 else { return }
        let ux = dx / length, uy = dy / length
        let nx = -uy, ny = ux
        let drawn = length * progress
        let headLength = min(1.1, length * 0.35)
        let headWidth = 0.55
        let shaftWidth = style == .run ? 0.09 : 0.18
        func along(_ t: Double, _ side: Double) -> CGPoint {
            CGPoint(x: Double(start.x) + ux * t + nx * side, y: Double(start.y) + uy * t + ny * side)
        }

        var shapes: [Path] = []
        let shaftEnd = max(0, drawn - headLength)
        switch style {
        case .pass:
            if shaftEnd > 0, let shaft = polygon([along(0, shaftWidth), along(shaftEnd, shaftWidth), along(shaftEnd, -shaftWidth), along(0, -shaftWidth)]) {
                shapes.append(shaft)
            }
        case .dribble, .run:
            // 点線も地面上で区切るので、奥ほど間隔が詰まって見える
            let dash = style == .run ? 0.5 : 0.8
            let gap = style == .run ? 0.45 : 0.55
            var t = 0.0
            while t < shaftEnd {
                let segmentEnd = min(shaftEnd, t + dash)
                if let piece = polygon([along(t, shaftWidth), along(segmentEnd, shaftWidth), along(segmentEnd, -shaftWidth), along(t, -shaftWidth)]) {
                    shapes.append(piece)
                }
                t += dash + gap
            }
        }
        if drawn >= headLength, let head = polygon([along(drawn, 0), along(drawn - headLength, headWidth), along(drawn - headLength, -headWidth)]) {
            shapes.append(head)
        }
        for shape in shapes {
            context.stroke(shape, with: .color(.black.opacity(0.4)), lineWidth: 1.5)
            context.fill(shape, with: .color(tone.color))
        }
    }

    /// 遠近が分からないときの、画面上の矢印
    private func drawScreenArrow(from: CGPoint, to: CGPoint, style: TelestrationArrowStyle, tone: TelestrationTone, progress: Double, in context: inout GraphicsContext) {
        let end = CGPoint(x: from.x + (to.x - from.x) * progress, y: from.y + (to.y - from.y) * progress)
        let dx = end.x - from.x, dy = end.y - from.y
        let length = hypot(dx, dy)
        guard length > 4 else { return }
        let ux = dx / length, uy = dy / length
        let base = CGPoint(x: end.x - ux * 12, y: end.y - uy * 12)
        var shaft = Path()
        shaft.move(to: from)
        shaft.addLine(to: base)
        let lineWidth: CGFloat = style == .run ? 2 : 3.5
        let dash: [CGFloat] = style == .pass ? [] : [8, 6]
        context.stroke(shaft, with: .color(.black.opacity(0.4)), style: StrokeStyle(lineWidth: lineWidth + 2, lineCap: .round, dash: dash))
        context.stroke(shaft, with: .color(tone.color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: dash))
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: base.x - uy * 7, y: base.y + ux * 7))
        head.addLine(to: CGPoint(x: base.x + uy * 7, y: base.y - ux * 7))
        head.closeSubpath()
        context.fill(head, with: .color(tone.color))
    }

    private func drawArea(center: CGPoint, radius: Double, opacity: Double, in context: inout GraphicsContext) {
        let path: Path
        if let groundCenter = projection?.ground(center), let circle = polygon(groundCircle(center: groundCenter, radius: radius)) {
            path = circle
        } else {
            let point = screen(center)
            let width = CGFloat(radius) * 24
            path = Path(ellipseIn: CGRect(x: point.x - width / 2, y: point.y - width * 0.2, width: width, height: width * 0.4))
        }
        context.fill(path, with: .color(.white.opacity(0.25 * opacity)))
        context.stroke(path, with: .color(.white.opacity(0.9 * opacity)), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
    }

    private func drawDefensiveLine(_ points: [CGPoint], progress: Double, in context: inout GraphicsContext) {
        let screenPoints = points.map { screen($0) }
        guard screenPoints.count >= 2 else { return }
        // 線の長さに対する進み具合の分だけ描く
        let lengths = zip(screenPoints, screenPoints.dropFirst()).map { hypot($0.x - $1.x, $0.y - $1.y) }
        var remaining = lengths.reduce(0, +) * progress
        var path = Path()
        path.move(to: screenPoints[0])
        for (index, length) in lengths.enumerated() {
            let a = screenPoints[index], b = screenPoints[index + 1]
            if remaining >= length {
                path.addLine(to: b)
                remaining -= length
            } else {
                let t = length > 0 ? remaining / length : 0
                path.addLine(to: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                break
            }
        }
        context.stroke(path, with: .color(.black.opacity(0.4)), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        context.stroke(path, with: .color(TelestrationTone.defense.color), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
        for point in points {
            drawRing(at: point, radius: GroundProjection.units(meters: 0.45), tone: .defense, dashed: false, opacity: progress, in: &context)
        }
    }

    private func drawDistance(from: CGPoint, to: CGPoint, meters: Double, progress: Double, in context: inout GraphicsContext) {
        let a = screen(from), b = screen(to)
        var path = Path()
        path.move(to: a)
        path.addLine(to: CGPoint(x: a.x + (b.x - a.x) * progress, y: a.y + (b.y - a.y) * progress))
        context.stroke(path, with: .color(.black.opacity(0.4)), style: StrokeStyle(lineWidth: 3.5, dash: [5, 4]))
        context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 1.8, dash: [5, 4]))
        if progress >= 1 {
            let text = meters < 10 ? String(format: "%.1fm", meters) : "\(Int(meters.rounded()))m"
            drawBadge(text, at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 12), background: .white, in: &context)
        }
    }

    private func drawGhost(at foot: CGPoint, label: String, opacity: Double, in context: inout GraphicsContext) {
        drawRing(at: foot, radius: GroundProjection.units(meters: Self.ringRadius), tone: .highlight, dashed: true, opacity: opacity, in: &context)
        let point = screen(foot)
        // 立っているべき位置に、半透明の選手を置く
        let height: CGFloat
        if let ground = projection?.ground(foot), let person = projection?.personHeight(atGround: ground) {
            height = max(18, CGFloat(person) * size.height)
        } else {
            height = 36
        }
        var figure = context.resolve(Image(systemName: "figure.stand"))
        figure.shading = .color(.yellow.opacity(0.6 * opacity))
        context.draw(figure, in: CGRect(x: point.x - height * 0.25, y: point.y - height, width: height * 0.5, height: height))
        if opacity >= 1 {
            drawBadge(label, at: offset(point, dy: -height - 10), background: .yellow, in: &context)
        }
    }

    /// 背景付きの短い文字
    private func drawBadge(_ text: String, at point: CGPoint, background: Color, in context: inout GraphicsContext) {
        let resolved = context.resolve(Text(text).font(.caption2.bold()).foregroundColor(.black))
        let measured = resolved.measure(in: CGSize(width: 200, height: 40))
        let rect = CGRect(
            x: point.x - measured.width / 2 - 6,
            y: point.y - measured.height / 2 - 2,
            width: max(measured.width + 12, measured.height + 4),
            height: measured.height + 4
        )
        let capsule = Path(roundedRect: rect, cornerRadius: rect.height / 2)
        context.fill(capsule.offsetBy(dx: 0, dy: 1), with: .color(.black.opacity(0.35)))
        context.fill(capsule, with: .color(background))
        context.draw(resolved, at: CGPoint(x: rect.midX, y: rect.midY))
    }
}
