//
//  TacticalBoardView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/10.
//

import SwiftUI

/// シーンの注目時点の静止画に検出結果を重ね、選択肢の一覧と並べて表示する
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
                Image(systemName: "list.number")
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
