//
//  MatchCommentaryView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/12.
//

import SwiftUI

/// 試合の解説（AI が試合の流れを伝える文章、ボール保持率、実況の出来事）
///
/// 改善の提案ではなく、何が起きたかを伝える。AI の文章は表示したときに作り、解析結果に保存する。
struct MatchCommentaryView: View {
    @Environment(AnalysisStore.self) private var store
    let record: SavedAnalysis
    let playByPlay: MatchPlayByPlay
    /// 再生位置（いまの出来事を強調する）
    let currentTime: Double
    /// 出来事をタップしたときに、その時刻へ移動する
    let onSelect: (Double) -> Void

    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var showsAllEvents = false

    private static let collapsedEventCount = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("試合の解説", systemImage: "mic.fill")
                .font(.headline)

            reportContent

            if !playByPlay.possession.isEmpty, let teams = record.teams, !teams.isEmpty {
                possessionBar(teams: teams)
            }

            if !playByPlay.events.isEmpty {
                Divider()
                eventList
            }

            Text("ボールに最も近い選手を持ち主とみなして記録した、試合の流れの目安です。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        // 得点を記録・取り消すと解説が消えるため、そのときにも作り直す
        .task(id: "\(record.id)-\(record.matchReport?.generatedAt.timeIntervalSince1970 ?? 0)") {
            guard record.matchReport == nil, IntelligenceAdvisor.unavailableReason == nil else { return }
            await generate()
        }
    }

    // MARK: - Report

    @ViewBuilder
    private var reportContent: some View {
        if let report = record.matchReport {
            VStack(alignment: .leading, spacing: 8) {
                Text(report.headline)
                    .font(.title3.bold())
                Text(report.story)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if !report.highlights.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("見どころ", systemImage: "star")
                            .font(.subheadline.weight(.semibold))
                        ForEach(Array(report.highlights.enumerated()), id: \.offset) { _, highlight in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("・")
                                Text(highlight)
                            }
                            .font(.subheadline)
                        }
                    }
                }
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
        } else if isGenerating {
            HStack(spacing: 8) {
                ProgressView()
                Text("試合の解説を作成中...")
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
    }

    private func generate() async {
        guard !isGenerating else { return }
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        do {
            let report = try await IntelligenceAdvisor.matchReport(for: record, playByPlay: playByPlay)
            try Task.checkCancellation()
            // 生成中に他の内容が保存されていても消さないよう、最新の記録に書き足す
            guard var latest = store.record(for: record.id) else { return }
            latest.matchReport = report
            try store.update(latest)
        } catch is CancellationError {
            // 画面を閉じた
        } catch {
            errorMessage = IntelligenceAdvisor.errorMessage(for: error)
        }
    }

    // MARK: - Possession

    private func possessionBar(teams: [TeamInfo]) -> some View {
        let shares = teams.map { team in TeamShare(team: team, share: playByPlay.possession[team.id] ?? 0) }
        return VStack(alignment: .leading, spacing: 6) {
            Text("ボール保持率")
                .font(.caption)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(shares) { item in
                        Rectangle()
                            .fill(item.team.color.color)
                            .frame(width: max(0, geo.size.width * item.share - 2))
                    }
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            HStack {
                ForEach(shares) { item in
                    HStack(spacing: 4) {
                        Circle().fill(item.team.color.color).frame(width: 8, height: 8)
                        Text("\(item.team.name) \(Int((item.share * 100).rounded()))%")
                            .font(.caption)
                            .monospacedDigit()
                    }
                    if item.team.id != shares.last?.team.id { Spacer() }
                }
            }
        }
    }

    private struct TeamShare: Identifiable {
        let team: TeamInfo
        let share: Double
        var id: Int { team.id }
    }

    // MARK: - Events

    private var eventList: some View {
        let current = playByPlay.latestEvent(at: currentTime, within: 6)
        let events = showsAllEvents ? playByPlay.events : Array(eventsAroundCurrent(current))
        return VStack(alignment: .leading, spacing: 6) {
            Text("実況")
                .font(.subheadline.weight(.semibold))
            ForEach(events) { event in
                Button {
                    onSelect(event.time)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(DurationText.clock(event.time))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .leading)
                        Image(systemName: event.systemImage)
                            .font(.caption)
                            .foregroundStyle(record.team(id: event.team)?.color.color ?? .secondary)
                            .frame(width: 16)
                        Text(event.text)
                            .font(.subheadline)
                            .fontWeight(event.id == current?.id ? .bold : .regular)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if playByPlay.events.count > Self.collapsedEventCount {
                Button(showsAllEvents ? "閉じる" : "すべての出来事（\(playByPlay.events.count)件）") {
                    withAnimation { showsAllEvents.toggle() }
                }
                .font(.caption)
            }
        }
    }

    /// 再生位置の前後の出来事（再生に合わせて実況が流れるように）
    private func eventsAroundCurrent(_ current: PlayEvent?) -> ArraySlice<PlayEvent> {
        let events = playByPlay.events
        let count = Self.collapsedEventCount
        guard events.count > count else { return events[...] }
        let anchor = current?.id ?? (events.lastIndex { $0.time <= currentTime } ?? 0)
        let start = min(max(0, anchor - count / 2), events.count - count)
        return events[start..<(start + count)]
    }
}
