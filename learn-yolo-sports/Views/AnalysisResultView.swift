//
//  AnalysisResultView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI
import AVKit
import UIKit

/// 解析結果の表示（解析直後と履歴の両方で使う）
///
/// 動画の再生に合わせて、そのシーンのAI解説カードが自動で切り替わる。
/// タイムラインやチャプターをタップすると、そのシーンへシークして再生する。
struct AnalysisResultView: View {
    @Environment(AnalysisStore.self) private var store
    let record: SavedAnalysis

    @State private var player = AVPlayer()
    @State private var currentTime: Double = 0
    @State private var showOverlay = true
    @State private var timeObserver: Any?

    // 動画ファイルがない古い記録向けのフレーム静止画表示
    @State private var selectedFrameIndex = 0
    @State private var legacyImage: CGImage?

    private static let adviceSectionID = "overallAdvice"

    private var videoURL: URL? { store.videoURL(for: record) }

    private var videoAspectRatio: CGFloat {
        guard record.imageWidth > 0, record.imageHeight > 0 else { return 16.0 / 9.0 }
        return CGFloat(record.imageWidth) / CGFloat(record.imageHeight)
    }

    private var currentSegment: SceneSegment? {
        record.segments?.first { $0.contains(currentTime) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    if !record.usedRealModel {
                        Label("モックモードの結果のため、検出・AI解説は参考になりません", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.horizontal)
                    }

                    if let videoURL {
                        playerSection(videoURL: videoURL)
                        if let duration = record.videoDuration, duration > 0 {
                            timelineBar(duration: duration)
                                .padding(.horizontal)
                        }
                    } else {
                        legacyFrameBrowser
                    }

                    commentarySection
                    playersSection
                    chapterListSection
                    overallAdviceSection
                        .id(Self.adviceSectionID)
                    statisticsSection
                }
                .padding(.vertical, 12)
            }
            .task {
                // スクリーンショット用: 総評までスクロールした状態にする
                if LaunchOptions.showsAdvice {
                    proxy.scrollTo(Self.adviceSectionID, anchor: .top)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                AnalysisShareMenu(record: record)
            }
        }
        .onAppear { setupPlayerIfNeeded() }
        .onDisappear { teardownPlayer() }
    }

    // MARK: - Player

    private func playerSection(videoURL: URL) -> some View {
        GeometryReader { geo in
            ZStack {
                VideoPlayer(player: player)
                if showOverlay, let frame = nearestFrame(to: currentTime) {
                    DetectionOverlayView(detections: frame.detections, teams: record.teams, players: record.players, displaySize: geo.size)
                        .allowsHitTesting(false)
                }
                // 注目時点の前後では選択肢の矢印も重ねる
                if showOverlay, let segment = currentSegment, let tactics = segment.tactics,
                   abs(currentTime - tactics.timestamp) <= 1.0 {
                    TacticalArrowsView(snapshot: tactics, recommendedOptionID: segment.recommendedOptionID, displaySize: geo.size)
                        .allowsHitTesting(false)
                }
            }
        }
        .aspectRatio(videoAspectRatio, contentMode: .fit)
        .background(Color.black)
        .overlay(alignment: .topTrailing) {
            Button {
                showOverlay.toggle()
            } label: {
                Image(systemName: showOverlay ? "eye.fill" : "eye.slash")
                    .padding(8)
                    .background(.black.opacity(0.5))
                    .foregroundStyle(.white)
                    .clipShape(Circle())
            }
            .padding(8)
        }
    }

    private func setupPlayerIfNeeded() {
        guard let videoURL, player.currentItem == nil else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: videoURL))
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { time in
            currentTime = CMTimeGetSeconds(time)
        }
    }

    private func teardownPlayer() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player.pause()
    }

    private func seek(to time: Double) {
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        currentTime = time
    }

    private func nearestFrame(to time: Double) -> SavedFrame? {
        record.frames.min { abs($0.timestamp - time) < abs($1.timestamp - time) }
    }

    // MARK: - Timeline

    private func timelineBar(duration: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.systemGray4)).frame(height: 6)

                if let segments = record.segments {
                    ForEach(segments) { segment in
                        Group {
                            Capsule()
                                .fill(Color.accentColor.opacity(0.3))
                                .frame(width: max(2, geo.size.width * CGFloat((segment.endTime - segment.startTime) / duration)), height: 6)
                                .offset(x: geo.size.width * CGFloat(segment.startTime / duration))
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 8, height: 8)
                                .offset(x: geo.size.width * CGFloat(segment.keyTime / duration) - 4, y: -1)
                        }
                    }
                }

                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                    .offset(x: geo.size.width * CGFloat(min(1, max(0, currentTime / duration))) - 5, y: -2)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onEnded { value in
                    let fraction = max(0, min(1, value.location.x / geo.size.width))
                    seek(to: fraction * duration)
                }
            )
        }
        .frame(height: 20)
    }

    // MARK: - Commentary

    @ViewBuilder
    private var commentarySection: some View {
        if let segment = currentSegment {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: segment.kind.systemImage)
                    Text(segment.commentary?.headline ?? segment.title)
                        .font(.headline)
                    Spacer()
                    Text(timeRangeText(segment))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let commentary = segment.commentary {
                    Text(commentary.commentary)
                    Label(commentary.suggestion, systemImage: "lightbulb")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(record.adviceUnavailableReason ?? "この場面のAI解説はまだありません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let tactics = segment.tactics, !tactics.options.isEmpty {
                    Divider()
                    TacticalBoardView(record: record, segment: segment, snapshot: tactics)
                    Button {
                        jump(to: tactics.timestamp)
                    } label: {
                        Label("この局面を動画で見る", systemImage: "play.rectangle")
                            .font(.caption)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    // MARK: - Players

    /// チームと識別した選手（タップするとその選手が最初に写った場面へ移動する）
    @ViewBuilder
    private var playersSection: some View {
        if let teams = record.teams, !teams.isEmpty {
            let players = (record.players ?? []).sorted(by: PlayerIdentity.sortOrder)
            VStack(alignment: .leading, spacing: 10) {
                Text("選手")
                    .font(.headline)

                ForEach(teams) { team in
                    let members = players.filter { $0.team == team.id }
                    // 白いユニフォームなど明るい色は、背景に溶けないよう灰色で縁取る
                    let outline = team.color.isLight ? Color.gray : team.color.color
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(team.color.color)
                                .overlay(Circle().strokeBorder(outline, lineWidth: 1))
                                .frame(width: 12, height: 12)
                            Text(team.name).font(.subheadline.bold())
                            Text("\(members.count)人").font(.caption).foregroundStyle(.secondary)
                        }
                        if !members.isEmpty {
                            playerChips(members, color: outline)
                        }
                    }
                }

                let goalkeepers = players.filter(\.isGoalkeeper)
                if !goalkeepers.isEmpty {
                    playerChips(goalkeepers, color: .green)
                }

                Text("背番号が読めた選手は #番号、読めなかった選手は登場順に A, B, C… で呼んでいます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    private func playerChips(_ players: [PlayerIdentity], color: Color) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(players) { player in
                    Button {
                        jump(to: player.firstSeen)
                    } label: {
                        Text(player.label)
                            .font(.caption.bold())
                            .monospacedDigit()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(color.opacity(0.2)))
                            .overlay(Capsule().strokeBorder(color, lineWidth: 1))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 指定した時刻へ移動する（動画がない記録は、近いフレームの静止画を表示する）
    private func jump(to time: Double) {
        if videoURL != nil {
            seek(to: time)
            player.pause()
        } else if let index = legacyFrames.indices.min(by: { abs(legacyFrames[$0].timestamp - time) < abs(legacyFrames[$1].timestamp - time) }) {
            selectedFrameIndex = index
        }
    }

    // MARK: - Chapters

    @ViewBuilder
    private var chapterListSection: some View {
        if let segments = record.segments, !segments.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("チャプター")
                    .font(.headline)
                    .padding(.horizontal)

                VStack(spacing: 8) {
                    ForEach(segments) { segment in
                        Button {
                            if videoURL != nil {
                                seek(to: segment.keyTime)
                                player.play()
                            } else {
                                jump(to: segment.keyTime)
                            }
                        } label: {
                            HStack {
                                Image(systemName: segment.kind.systemImage)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(segment.commentary?.headline ?? segment.title)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    Text(timeRangeText(segment))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if segment.id == currentSegment?.id {
                                    Image(systemName: "play.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .background(Color(.systemBackground))
                            .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func timeRangeText(_ segment: SceneSegment) -> String {
        "\(formatTime(segment.startTime))〜\(formatTime(segment.endTime))"
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Overall Advice

    @ViewBuilder
    private var overallAdviceSection: some View {
        if let advice = record.advice {
            VStack(alignment: .leading, spacing: 10) {
                Text("総評").font(.headline)
                Text(advice.summary)

                if !advice.observations.isEmpty {
                    bulletList(title: "観察ポイント", items: advice.observations)
                }
                if !advice.suggestions.isEmpty {
                    bulletList(title: "改善提案", items: advice.suggestions)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        } else if let reason = record.adviceUnavailableReason {
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
    }

    private func bulletList(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).fontWeight(.semibold)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("・")
                    Text(item)
                }
                .font(.subheadline)
            }
        }
    }

    // MARK: - Statistics

    private var statisticsSection: some View {
        HStack(spacing: 20) {
            StatView(title: "総検出数", value: "\(record.totalDetections)", icon: "scope")
            StatView(title: "平均", value: String(format: "%.1f", record.averageDetectionsPerFrame), icon: "chart.bar")
            StatView(title: "処理時間", value: String(format: "%.0fs", record.processingDuration), icon: "clock")
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    // MARK: - Legacy Frame Browser（動画ファイルがない記録向け）

    /// 画像を保存したフレーム
    private var legacyFrames: [SavedFrame] {
        record.framesWithImages
    }

    private var legacyFrameBrowser: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    if let legacyImage {
                        Image(uiImage: UIImage(cgImage: legacyImage))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView()
                    }
                    if legacyFrames.indices.contains(selectedFrameIndex) {
                        DetectionOverlayView(
                            detections: legacyFrames[selectedFrameIndex].detections,
                            teams: record.teams,
                            players: record.players,
                            displaySize: geo.size
                        )
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .aspectRatio(videoAspectRatio, contentMode: .fit)
            .background(Color.black)

            if legacyFrames.count > 1 {
                Slider(
                    value: Binding(
                        get: { Double(selectedFrameIndex) },
                        set: { selectedFrameIndex = Int($0) }
                    ),
                    in: 0...Double(legacyFrames.count - 1),
                    step: 1
                )
                .padding()
            }
        }
        .onChange(of: selectedFrameIndex) { _, _ in loadLegacyImage() }
        .task { loadLegacyImage() }
    }

    private func loadLegacyImage() {
        guard legacyFrames.indices.contains(selectedFrameIndex) else { return }
        let frame = legacyFrames[selectedFrameIndex]
        // 表示中のフレームの時刻に合わせて、シーンの解説も切り替える
        currentTime = frame.timestamp
        Task {
            legacyImage = await store.loadFrameImage(for: record, frameNumber: frame.frameNumber)
        }
    }
}

// MARK: - Share Menu

/// 解析結果を LLM などへ共有するメニュー
struct AnalysisShareMenu: View {
    @Environment(AnalysisStore.self) private var store
    let record: SavedAnalysis

    // record は再生中の0.5秒ごとの更新で body が再評価されるたびに作り直されるため、
    // 重い markdown 生成は .task(id:) に移し、record.id が変わらない限り再計算しない
    @State private var report: String?

    var body: some View {
        Menu {
            if let report {
                ShareLink(
                    item: report,
                    subject: Text("サッカー動画の解析結果"),
                    preview: SharePreview("解析結果（LLM向けテキスト）")
                ) {
                    Label("LLM向けテキストを共有", systemImage: "text.bubble")
                }

                Button {
                    UIPasteboard.general.string = report
                } label: {
                    Label("LLM向けテキストをコピー", systemImage: "doc.on.doc")
                }
            } else {
                Text("準備中...")
            }

            let jsonURL = store.jsonURL(for: record)
            if FileManager.default.fileExists(atPath: jsonURL.path(percentEncoded: false)) {
                ShareLink(item: jsonURL, preview: SharePreview("analysis.json")) {
                    Label("JSONを共有", systemImage: "curlybraces")
                }
            }
        } label: {
            Label("共有", systemImage: "square.and.arrow.up")
        }
        .task(id: record.id) {
            if report == nil {
                report = AnalysisReport.markdown(for: record)
            }
        }
    }
}

// MARK: - Stat View

struct StatView: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)

            Text(value)
                .font(.title3)
                .fontWeight(.bold)

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
