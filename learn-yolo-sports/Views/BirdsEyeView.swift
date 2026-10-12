//
//  BirdsEyeView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/12.
//

import SwiftUI

/// 画面上の位置を、真上から見た位置に直す（目安）
///
/// カメラの正確な位置は分からないため、写っている選手の大きさから奥行きを推定する。
/// 遠い選手ほど小さく写るので、奥行きは枠の高さの逆数に比例するとみなし、
/// 足元の画面上の高さとの関係を直線で近似して、ボールや矢印の先など人以外の点にも使う。
nonisolated struct BirdsEyeProjection {
    /// 奥行き = intercept + slope * 足元の y
    private let intercept: Double
    private let slope: Double
    private let aspect: Double

    init?(detections: [SavedDetection], aspectRatio: Double) {
        aspect = aspectRatio > 0 ? aspectRatio : 16.0 / 9.0
        let people = detections.filter { detection in
            !detection.isExcluded && detection.label != SportsClass.ball.rawValue && detection.boundingBox.height > 0.01
        }
        guard people.count >= 3 else { return nil }
        let samples = people.map { (v: Double($0.footPoint.y), z: 1 / Double($0.boundingBox.height)) }
        let meanV = samples.map(\.v).reduce(0, +) / Double(samples.count)
        let meanZ = samples.map(\.z).reduce(0, +) / Double(samples.count)
        let covariance = samples.reduce(0) { $0 + ($1.v - meanV) * ($1.z - meanZ) }
        let variance = samples.reduce(0) { $0 + ($1.v - meanV) * ($1.v - meanV) }
        // 画面の上（y が小さい）ほど遠いはずなので、傾きは負になる
        guard variance > 1e-6 else { return nil }
        let fitted = covariance / variance
        guard fitted < 0 else { return nil }
        slope = fitted
        intercept = meanZ - fitted * meanV
    }

    /// 奥行き（大きいほど遠い）
    func depth(atScreenY y: Double) -> Double {
        max(1, intercept + slope * y)
    }

    /// 真上から見た位置（x: ピッチの長さ方向、y: 奥行き。単位はそろっているが絶対値は目安）
    func project(_ point: CGPoint) -> CGPoint {
        let z = depth(atScreenY: Double(point.y))
        return CGPoint(x: (Double(point.x) - 0.5) * aspect * z, y: z)
    }

    /// 画面の高さを 1 とした長さを、その奥行きでの真上から見た長さにする
    func length(_ screenLength: Double, atScreenY y: Double) -> Double {
        screenLength * depth(atScreenY: y)
    }
}

/// 画面に写っている範囲を真上から見た図（選手・ボール・空いた場所・選択肢の矢印・白線）
struct BirdsEyeView: View {
    let frame: SavedFrame
    let teams: [TeamInfo]?
    let players: [PlayerIdentity]?
    let aspectRatio: Double
    var lines: [FieldLine] = []
    var lineShift: CGPoint = .zero
    var spaces: [OpenSpace] = []
    var tactics: TacticalSnapshot? = nil
    var recommendedOptionID: Int? = nil
    /// マーカーを付けている選手
    var focusedPlayerID: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let projection = BirdsEyeProjection(detections: frame.detections, aspectRatio: aspectRatio) {
                Canvas { context, size in
                    draw(in: &context, size: size, projection: projection)
                }
                .background(pitchBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                ZStack {
                    pitchBackground
                    Text("選手が少ないため、この場面は描けません")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.9))
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Text("画面に写っている範囲を、選手の写る大きさから奥行きを推定して真上から見た目安です。上が奥（カメラから遠い側）です。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var pitchBackground: some View {
        // 芝の縞模様
        HStack(spacing: 0) {
            ForEach(0..<10, id: \.self) { index in
                Rectangle().fill(index.isMultiple(of: 2) ? Color(red: 0.20, green: 0.55, blue: 0.25) : Color(red: 0.24, green: 0.60, blue: 0.29))
            }
        }
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize, projection: BirdsEyeProjection) {
        let people = frame.detections.filter { !$0.isExcluded && $0.label != SportsClass.ball.rawValue }
        let ball = frame.detections(of: .ball).max { $0.confidence < $1.confidence }

        // 表示する範囲（選手とボールが収まるように）
        var projected = people.map { projection.project($0.footPoint) }
        if let ball { projected.append(projection.project(ball.center)) }
        guard let minX = projected.map(\.x).min(), let maxX = projected.map(\.x).max(),
              let minY = projected.map(\.y).min(), let maxY = projected.map(\.y).max() else { return }
        let padding: CGFloat = 24
        let spanX = max(maxX - minX, 1), spanY = max(maxY - minY, 1)
        let scale = min((size.width - padding * 2) / spanX, (size.height - padding * 2) / spanY)
        let offsetX = (size.width - spanX * scale) / 2
        let offsetY = (size.height - spanY * scale) / 2
        func toCanvas(_ point: CGPoint) -> CGPoint {
            // 奥（y が大きい）を上にする
            CGPoint(x: offsetX + (point.x - minX) * scale, y: size.height - (offsetY + (point.y - minY) * scale))
        }
        func screenToCanvas(_ screen: CGPoint) -> CGPoint { toCanvas(projection.project(screen)) }

        // 白線
        if !lines.isEmpty {
            var path = Path()
            for line in lines {
                let start = CGPoint(x: line.start.x + lineShift.x, y: line.start.y + lineShift.y)
                let end = CGPoint(x: line.end.x + lineShift.x, y: line.end.y + lineShift.y)
                path.move(to: screenToCanvas(start))
                path.addLine(to: screenToCanvas(end))
            }
            context.stroke(path, with: .color(.white.opacity(0.6)), lineWidth: 1.5)
        }

        // 空いた場所
        for space in spaces {
            let center = screenToCanvas(space.center)
            let radius = projection.length(space.radius, atScreenY: Double(space.center.y)) * scale
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.18)))
            context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }

        // 選択肢の矢印
        if let tactics {
            for option in tactics.options {
                let isRecommended = option.id == recommendedOptionID
                drawArrow(
                    in: &context,
                    from: screenToCanvas(option.from),
                    to: screenToCanvas(option.to),
                    color: isRecommended ? .yellow : .white.opacity(0.85),
                    dashed: option.kind == .dribble,
                    label: "\(option.id)"
                )
            }
        }

        // 選手
        let labels = Dictionary((players ?? []).map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
        for detection in people {
            let center = screenToCanvas(detection.footPoint)
            let team = detection.team.flatMap { id in teams?.first { $0.id == id } }
            let fill: Color
            if let team {
                fill = team.color.color
            } else {
                fill = SportsClass(rawValue: detection.label)?.color ?? .gray
            }
            let radius: CGFloat = 7
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            // 影
            context.fill(Path(ellipseIn: rect.offsetBy(dx: 1.5, dy: 2)), with: .color(.black.opacity(0.3)))
            context.fill(Path(ellipseIn: rect), with: .color(fill))
            context.stroke(Path(ellipseIn: rect), with: .color(team?.color.isLight == true ? .gray : .white), lineWidth: 1.5)
            if detection.playerID != nil, detection.playerID == focusedPlayerID {
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -4, dy: -4)), with: .color(.yellow), lineWidth: 2.5)
            }
            if let label = detection.playerID.flatMap({ labels[$0] }) {
                context.draw(
                    Text(label).font(.system(size: 9, weight: .bold)).foregroundColor(.white),
                    at: CGPoint(x: center.x, y: center.y - radius - 7)
                )
            }
        }

        // ボール
        if let ball {
            let center = screenToCanvas(ball.center)
            let rect = CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: rect), with: .color(.white))
            context.stroke(Path(ellipseIn: rect), with: .color(.black), lineWidth: 1.5)
        }
    }

    private func drawArrow(in context: inout GraphicsContext, from: CGPoint, to: CGPoint, color: Color, dashed: Bool, label: String) {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length > 4 else { return }
        let ux = dx / length, uy = dy / length
        let tip = CGPoint(x: to.x - ux * 9, y: to.y - uy * 9)
        let base = CGPoint(x: tip.x - ux * 8, y: tip.y - uy * 8)

        var shaft = Path()
        shaft.move(to: from)
        shaft.addLine(to: base)
        context.stroke(shaft, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [5, 4] : []))

        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: base.x - uy * 5, y: base.y + ux * 5))
        head.addLine(to: CGPoint(x: base.x + uy * 5, y: base.y - ux * 5))
        head.closeSubpath()
        context.fill(head, with: .color(color))

        let circle = CGRect(x: to.x - 8, y: to.y - 8, width: 16, height: 16)
        context.fill(Path(ellipseIn: circle), with: .color(color))
        context.draw(Text(label).font(.system(size: 10, weight: .bold)).foregroundColor(.black), at: to)
    }
}
