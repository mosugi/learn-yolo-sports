//
//  CoachReportView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI

/// コーチ解説（場面ごとの静止画・俯瞰図・指摘）
struct CoachReportView: View {
    let record: SavedAnalysis
    let report: CoachReport
    let setup: AnalysisSetup

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !record.usedRealModel {
                    Label("モックモード（ランダムな検出結果）のため、解説は参考になりません", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                summarySection

                if report.scenes.isEmpty {
                    ContentUnavailableView(
                        "目立った場面は見つかりませんでした",
                        systemImage: "sportscourt",
                        description: Text("選手やボールが十分に検出できていない可能性があります。下の注意も確認してください。")
                    )
                } else {
                    ForEach(report.scenes) { scene in
                        CoachSceneCard(record: record, scene: scene, setup: setup)
                    }
                }

                if !report.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("解析上の注意", systemImage: "info.circle")
                            .font(.subheadline.weight(.semibold))
                        ForEach(report.notes, id: \.self) { note in
                            Text("・\(note)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding()
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("集計")
                .font(.headline)
            ForEach(report.summary.lines, id: \.self) { line in
                Text(line)
                    .font(.subheadline)
            }
            Text("\(setup.format.displayName)・\(Int(setup.pitchLength)) m x \(Int(setup.pitchWidth)) m")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

/// 1つの場面の解説
struct CoachSceneCard: View {
    let record: SavedAnalysis
    let scene: CoachScene
    let setup: AnalysisSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(scene.isPositive ? "良い点" : "課題")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(scene.isPositive ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                    .foregroundStyle(scene.isPositive ? .green : .orange)
                    .cornerRadius(6)
                Text(scene.title)
                    .font(.headline)
            }

            Text("\(CoachReport.time(scene.startTime))〜\(CoachReport.time(scene.endTime))・\(scene.phase.displayName)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if let frame = record.nearestFrameWithImage(to: scene.peakTime) {
                SavedFrameView(record: record, frame: frame, showsLabels: false)
                    .aspectRatio(imageAspectRatio, contentMode: .fit)
                    .cornerRadius(8)
            }

            PitchDiagramView(snapshot: scene.snapshot, setup: setup)

            VStack(alignment: .leading, spacing: 6) {
                Label(scene.evidence, systemImage: "number")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(scene.comment)
                    .font(.subheadline)
                Label(scene.suggestion, systemImage: scene.isPositive ? "hand.thumbsup" : "lightbulb")
                    .font(.subheadline)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var imageAspectRatio: CGFloat {
        guard record.imageWidth > 0, record.imageHeight > 0 else { return 16 / 9 }
        return CGFloat(record.imageWidth) / CGFloat(record.imageHeight)
    }
}
