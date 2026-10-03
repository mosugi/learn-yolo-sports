//
//  PlayersView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI

/// 背番号ごとの選手へのアドバイス
struct PlayersView: View {
    let record: SavedAnalysis
    let setup: AnalysisSetup

    @State private var reports: [PlayerReport]?

    /// 背番号の割り当てが変わったら集計し直す
    private var reloadKey: [Int: Int] {
        record.effectiveTrackNumbers
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let reports {
                    if reports.isEmpty {
                        ContentUnavailableView(
                            "背番号を特定できた選手がいません",
                            systemImage: "person.crop.circle.badge.questionmark",
                            description: Text("背番号は選手が大きく写り、背中が見えたときに読み取ります。「検出結果」で自チームの選手をタップすると、背番号を割り当てられます。")
                        )
                    } else {
                        Text("背番号を特定できた \(reports.count) 人の、追跡できた時間の範囲での集計です。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(reports) { report in
                            PlayerCard(report: report, setup: setup)
                        }
                    }
                } else {
                    ProgressView("集計中...")
                        .frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .task(id: reloadKey) {
            let record = record
            reports = await Task.detached(priority: .userInitiated) {
                PlayerAnalyzer.reports(for: record)
            }.value
        }
    }
}

/// 1人分のアドバイス
private struct PlayerCard: View {
    let report: PlayerReport
    let setup: AnalysisSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("#\(report.number)")
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                if !report.name.isEmpty {
                    Text(report.name)
                        .font(.headline)
                }
                Spacer()
                Text(report.role)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(TeamSide.own.color.opacity(0.2))
                    .cornerRadius(6)
            }

            PlayerPositionMap(report: report, setup: setup)

            metrics

            ForEach(report.advice, id: \.self) { advice in
                VStack(alignment: .leading, spacing: 2) {
                    Label(advice.title, systemImage: advice.isPositive ? "hand.thumbsup" : "lightbulb")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(advice.isPositive ? .green : .orange)
                    Text(advice.detail)
                        .font(.subheadline)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var metrics: some View {
        let items: [(String, String)] = [
            ("追跡", "\(Int(report.observedTime)) 秒"),
            ("移動", report.distancePerMinute.map { "\(Int($0)) m/分" } ?? "-"),
            ("スプリント", "\(report.sprints) 回"),
            ("ボール関与", String(format: "%.1f 秒", report.ballTime)),
        ]
        return HStack {
            ForEach(items.indices, id: \.self) { index in
                let (title, value) = items[index]
                VStack(spacing: 2) {
                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// 選手のいた位置の分布
private struct PlayerPositionMap: View {
    let report: PlayerReport
    let setup: AnalysisSetup

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Canvas { context, size in
                PitchDiagramView.drawPitch(in: context, size: size, setup: setup)
                let scale = size.width / setup.pitchLength
                for point in report.positions {
                    let rect = CGRect(x: point.x * scale - 3, y: point.y * scale - 3, width: 6, height: 6)
                    context.fill(Path(ellipseIn: rect), with: .color(TeamSide.own.color.opacity(0.35)))
                }
                let average = CGPoint(x: report.averagePosition.x * scale, y: report.averagePosition.y * scale)
                let rect = CGRect(x: average.x - 7, y: average.y - 7, width: 14, height: 14)
                context.fill(Path(ellipseIn: rect), with: .color(TeamSide.own.color))
                context.stroke(Path(ellipseIn: rect), with: .color(.black), lineWidth: 1.5)
            }
            .aspectRatio(setup.pitchLength / setup.pitchWidth, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(setup.ownAttacksRight ? "大きな点は平均位置・攻撃方向 →" : "← 攻撃方向・大きな点は平均位置")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// 追跡した選手に背番号を割り当てる
struct NumberAssignmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AnalysisStore.self) private var store

    let record: SavedAnalysis
    let trackID: Int

    @State private var text: String
    @State private var errorMessage: String?

    init(record: SavedAnalysis, trackID: Int) {
        self.record = record
        self.trackID = trackID
        _text = State(initialValue: record.effectiveTrackNumbers[trackID].map(String.init) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("背番号", text: $text)
                        .keyboardType(.numberPad)
                } footer: {
                    Text("この追跡（ID\(trackID)）の選手に背番号を割り当てます。同じ選手の別の追跡にも割り当てると、選手別のアドバイスにまとめて反映されます。")
                }

                let roster = record.setup?.rosterEntries ?? []
                if !roster.isEmpty {
                    Section("登録した選手") {
                        ForEach(roster) { entry in
                            Button {
                                save(entry.number)
                            } label: {
                                Text(entry.name.isEmpty ? "#\(entry.number)" : "#\(entry.number) \(entry.name)")
                            }
                        }
                    }
                }

                if record.effectiveTrackNumbers[trackID] != nil {
                    Section {
                        Button("割り当てを解除", role: .destructive) {
                            save(0)
                        }
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("背番号の割り当て")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let number = Int(text), (0...99).contains(number) {
                            save(number)
                        }
                    }
                    .disabled(Int(text).map { !(0...99).contains($0) } ?? true)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save(_ number: Int) {
        do {
            try store.modify(record.id) { record in
                var overrides = record.numberOverrides ?? [:]
                overrides[trackID] = number
                record.numberOverrides = overrides
            }
            dismiss()
        } catch {
            errorMessage = "保存できませんでした: \(error.localizedDescription)"
        }
    }
}

/// シートに渡す追跡 ID
struct SelectedTrack: Identifiable {
    let id: Int
}
