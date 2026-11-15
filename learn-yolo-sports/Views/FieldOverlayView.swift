//
//  FieldOverlayView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/12.
//

import SwiftUI

/// コートの白線と、ボール周辺の空いた場所（点線）を重ねる
struct FieldOverlayView: View {
    let lines: [FieldLine]
    /// 白線を求めたフレームから、表示中のフレームまでのカメラの動き（正規化座標）
    var lineShift: CGPoint = .zero
    let spaces: [OpenSpace]
    let displaySize: CGSize

    var body: some View {
        ZStack {
            Path { path in
                for line in lines {
                    path.move(to: point(line.start, shift: lineShift))
                    path.addLine(to: point(line.end, shift: lineShift))
                }
            }
            .stroke(Color.cyan.opacity(0.85), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .shadow(color: .black.opacity(0.4), radius: 1)

            ForEach(Array(spaces.enumerated()), id: \.offset) { _, space in
                let center = point(space.center, shift: .zero)
                let radius = space.radius * displaySize.height
                // 地面に描いたように見えるよう、縦をつぶした楕円にする
                Ellipse()
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        Ellipse().stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    )
                    .frame(width: radius * 2, height: radius)
                    .position(center)
            }
        }
        .allowsHitTesting(false)
    }

    private func point(_ normalized: CGPoint, shift: CGPoint) -> CGPoint {
        CGPoint(
            x: (normalized.x + shift.x) * displaySize.width,
            y: (normalized.y + shift.y) * displaySize.height
        )
    }
}
