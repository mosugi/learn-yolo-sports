//
//  PlayerFocusMarker.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/11.
//

import SwiftUI

/// 1人の選手が写っていた位置（時刻順）
///
/// 解析は 1 秒に数フレームしか行わないため、その間は前後のフレームの枠を補間して、
/// 動画の再生に合わせてマーカーがなめらかに動くようにする。
nonisolated struct PlayerFocusPath {
    /// 前後のフレームの間隔がこれ以内なら補間する（追跡が途切れた区間はつながない）
    static let maxInterpolationGap = 1.0
    /// 前後どちらかのフレームにしか写っていない場合に、そのまま表示する時間の幅
    static let holdDuration = 0.4

    let playerID: Int
    private let points: [(time: Double, box: CGRect)]

    init(frames: [SavedFrame], playerID: Int) {
        self.playerID = playerID
        points = frames.compactMap { frame in
            frame.detections
                .first { $0.playerID == playerID && !$0.isExcluded }
                .map { (frame.timestamp, $0.boundingBox) }
        }
    }

    var isEmpty: Bool { points.isEmpty }

    /// 指定時刻の枠（正規化座標）。写っていない場合は nil
    func box(at time: Double) -> CGRect? {
        guard !points.isEmpty else { return nil }

        // time 以上になる最初の位置
        var lower = 0, upper = points.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if points[mid].time < time { lower = mid + 1 } else { upper = mid }
        }
        let after = lower < points.count ? points[lower] : nil
        let before = lower > 0 ? points[lower - 1] : nil

        if let before, let after {
            let gap = after.time - before.time
            if gap <= Self.maxInterpolationGap, gap > 0 {
                let t = CGFloat((time - before.time) / gap)
                return CGRect(
                    x: before.box.minX + (after.box.minX - before.box.minX) * t,
                    y: before.box.minY + (after.box.minY - before.box.minY) * t,
                    width: before.box.width + (after.box.width - before.box.width) * t,
                    height: before.box.height + (after.box.height - before.box.height) * t
                )
            }
        }
        let nearest = [before, after]
            .compactMap { $0 }
            .min { abs($0.time - time) < abs($1.time - time) }
        guard let nearest, abs(nearest.time - time) <= Self.holdDuration else { return nil }
        return nearest.box
    }

    /// 指定時刻以降で最初に写る時刻（なければ最初に写った時刻）
    func nextAppearance(after time: Double) -> Double? {
        points.first { $0.time >= time }?.time ?? points.first?.time
    }
}

/// 選んだ選手だけに付け続けるマーカー
///
/// 再生位置を自分で読み取って描き直すため、親の View を高い頻度で更新しなくてよい。
struct PlayerFocusMarker: View {
    let path: PlayerFocusPath
    let label: String
    let displaySize: CGSize
    /// 現在の再生位置（秒）
    let currentTime: () -> Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            if let box = path.box(at: currentTime()) {
                marker(for: box)
                    .frame(width: displaySize.width, height: displaySize.height)
            } else {
                Text("\(label) は画面外")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(8)
            }
        }
        .allowsHitTesting(false)
    }

    private func marker(for box: CGRect) -> some View {
        let rect = CGRect(
            x: box.minX * displaySize.width,
            y: box.minY * displaySize.height,
            width: box.width * displaySize.width,
            height: box.height * displaySize.height
        )
        return ZStack {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.yellow, lineWidth: 3)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .frame(width: max(8, rect.width + 6), height: max(8, rect.height + 6))
                .position(x: rect.midX, y: rect.midY)

            VStack(spacing: 0) {
                Text(label)
                    .font(.caption.bold())
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.yellow, in: Capsule())
                    .foregroundStyle(.black)
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.yellow)
            }
            .fixedSize()
            .shadow(color: .black.opacity(0.5), radius: 2)
            .position(x: rect.midX, y: max(12, rect.minY - 18))
        }
    }
}
