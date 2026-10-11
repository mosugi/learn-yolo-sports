//
//  PlayerAdviceCard.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/11.
//

import SwiftUI

/// 指定した選手の動きの指標と、AI のアドバイス
///
/// 解析時には生成せず、選手が指定されたときに初めて指標を計算して生成する（解析を長くしないため）。
/// 生成したアドバイスは解析結果に保存し、次回からはすぐに表示する。
struct PlayerAdviceCard: View {
    @Environment(AnalysisStore.self) private var store
    let record: SavedAnalysis
    let player: PlayerIdentity

    @State private var metrics: PlayerMetrics?
    @State private var isGenerating = false
    @State private var errorMessage: String?

    private var advice: PlayerAdvice? {
        record.playerAdvice?.first { $0.playerID == player.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(player.displayName(teams: record.teams)) の動き", systemImage: "figure.run")
                .font(.headline)

            if let metrics {
                metricsGrid(metrics)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }

            Divider()

            if let advice {
                adviceContent(advice)
            } else if isGenerating {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("アドバイスを作成中...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if let message = errorMessage ?? IntelligenceAdvisor.unavailableReason {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if IntelligenceAdvisor.unavailableReason == nil {
                    Button("もう一度作成") {
                        Task { await generate() }
                    }
                    .font(.caption)
                }
            }

            Text("距離と速さは、写っている選手の身長を\(String(format: "%.1f", PlayerMetrics.assumedHeight))mと仮定した目安です。カメラに写っていない間の動きは含みません。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .task {
            await load()
        }
    }

    // MARK: - Content

    private func metricsGrid(_ metrics: PlayerMetrics) -> some View {
        HStack(spacing: 8) {
            metricTile("写っていた時間", value: "\(Int(metrics.visibleDuration.rounded()))秒")
            metricTile("移動距離", value: "\(Int(PlayerMetrics.meters(metrics.distance).rounded()))m")
            metricTile(
                "最高速度",
                value: metrics.topSpeed.map { String(format: "%.0fkm/h", PlayerMetrics.kilometersPerHour($0)) } ?? "-"
            )
            metricTile("ボール付近", value: metrics.nearBallRatio.map(PlayerMetrics.percent) ?? "-")
        }
    }

    private func metricTile(_ title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func adviceContent(_ advice: PlayerAdvice) -> some View {
        Text(advice.summary)

        bulletList(title: "良い点", systemImage: "hand.thumbsup", items: advice.strengths)
        bulletList(title: "次に意識すること", systemImage: "lightbulb", items: advice.improvements)

        if IntelligenceAdvisor.unavailableReason == nil {
            Button {
                Task { await generate() }
            } label: {
                if isGenerating {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text("作成中...")
                    }
                } else {
                    Label("作り直す", systemImage: "arrow.clockwise")
                }
            }
            .font(.caption)
            .disabled(isGenerating)
        }
    }

    private func bulletList(title: String, systemImage: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .fontWeight(.semibold)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("・")
                    Text(item)
                }
                .font(.subheadline)
            }
        }
    }

    // MARK: - Generation

    /// 指標を計算し、アドバイスがまだなければ生成する
    private func load() async {
        if metrics == nil {
            let record = record
            let player = player
            metrics = await Task.detached(priority: .userInitiated) {
                PlayerMetrics(record: record, player: player)
            }.value
        }
        guard advice == nil, IntelligenceAdvisor.unavailableReason == nil else { return }
        await generate()
    }

    private func generate() async {
        guard !isGenerating, let metrics else { return }
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        do {
            let generated = try await IntelligenceAdvisor.playerAdvice(metrics: metrics, usedRealModel: record.usedRealModel)
            try Task.checkCancellation()
            // 生成中に他の選手のアドバイスが保存されていても消さないよう、最新の記録に書き足す
            guard var latest = store.record(for: record.id) else { return }
            var list = latest.playerAdvice ?? []
            list.removeAll { $0.playerID == generated.playerID }
            list.append(generated)
            latest.playerAdvice = list
            try store.update(latest)
        } catch is CancellationError {
            // 選手の指定を外した・画面を閉じた
        } catch {
            errorMessage = IntelligenceAdvisor.errorMessage(for: error)
        }
    }
}
