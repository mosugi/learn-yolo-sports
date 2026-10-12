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
    @Environment(VideoAnalysisViewModel.self) private var viewModel
    let record: SavedAnalysis

    @State private var player = AVPlayer()
    @State private var currentTime: Double = 0
    /// 動画に重ねるもの（設定は保存する）
    @AppStorage("showPlayerBoxes") private var showPlayers = true
    @AppStorage("showTacticalAdvice") private var showAdvice = true
    @AppStorage("pauseAtAdvice") private var pauseAtAdvice = true
    @AppStorage("showBirdsEye") private var showBirdsEye = false
    /// 注目時点で一時停止して解説している場面
    @State private var adviceMoment: SceneSegment.ID?
    /// 解説した場面（同じ再生で何度も止めないため）
    @State private var shownMoments: Set<SceneSegment.ID> = []
    /// 解説中の矢印を描く割合（0 から 1 へアニメーションする）
    @State private var arrowProgress = 1.0
    /// コートの白線・ボール周辺の空いた場所を表示するか
    @AppStorage("showFieldLines") private var showFieldLines = true
    @AppStorage("showOpenSpaces") private var showOpenSpaces = true
    @State private var timeObserver: Any?
    /// マーカーを付け続ける選手の位置
    @State private var focusPath: PlayerFocusPath?

    // 動画ファイルがない古い記録向けのフレーム静止画表示
    @State private var selectedFrameIndex = 0
    @State private var legacyImage: CGImage?

    private static let adviceSectionID = "overallAdvice"

    private var videoURL: URL? { store.videoURL(for: record) }

    private var videoAspectRatio: CGFloat {
        guard record.imageWidth > 0, record.imageHeight > 0 else { return 16.0 / 9.0 }
        return CGFloat(record.imageWidth) / CGFloat(record.imageHeight)
    }

    private var focusedPlayer: PlayerIdentity? {
        focusPath.flatMap { path in record.players?.first { $0.id == path.playerID } }
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
                        sceneNavigator
                            .padding(.horizontal)
                        if let segment = adviceMomentSegment {
                            adviceMomentCard(segment)
                                .padding(.horizontal)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        if focusPath == nil, record.players?.isEmpty == false {
                            Label("選手の枠をタップすると、その選手を追いかけて動きのアドバイスを作成します", systemImage: "hand.tap")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                        }
                    } else {
                        legacyFrameBrowser
                    }

                    if showBirdsEye {
                        birdsEyeSection
                            .padding(.horizontal)
                    }

                    commentarySection
                    playersSection
                    // 選手を指定したときにだけ、その選手の指標とアドバイスを作る
                    if let focusedPlayer {
                        PlayerAdviceCard(record: record, player: focusedPlayer)
                            .id(focusedPlayer.id)
                            .padding(.horizontal)
                    }
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
        // バックグラウンドで作れなかった AI 解説を、表示したときに作る
        .task(id: record.id) {
            viewModel.generateMissingAdvice(for: record.id)
        }
        .onDisappear { teardownPlayer() }
    }

    // MARK: - Player

    private func playerSection(videoURL: URL) -> some View {
        GeometryReader { geo in
            ZStack {
                VideoPlayer(player: player)
                // 白線とスペースは、検出枠の表示とは別に切り替える
                if let frame = nearestFrame(to: currentTime) {
                    fieldOverlay(for: frame, size: geo.size)
                }
                if showPlayers, let frame = nearestFrame(to: currentTime) {
                    DetectionOverlayView(
                        detections: frame.detections,
                        teams: record.teams,
                        players: record.players,
                        displaySize: geo.size,
                        focusedPlayerID: focusPath?.playerID,
                        onSelectPlayer: toggleFocus(playerID:)
                    )
                }
                // 選んだ選手のマーカーは、枠の表示を消していても出す
                if let focusPath, let focusedPlayer {
                    PlayerFocusMarker(path: focusPath, label: focusedPlayer.label, displaySize: geo.size) {
                        let seconds = CMTimeGetSeconds(player.currentTime())
                        return seconds.isFinite ? seconds : 0
                    }
                }
                // 注目時点の前後では選択肢の矢印も重ねる（解説中は矢印が伸びていくように描く）
                if showAdvice, let segment = currentSegment, let tactics = segment.tactics,
                   adviceMoment == segment.id || abs(currentTime - tactics.timestamp) <= 1.0 {
                    TacticalArrowsView(
                        snapshot: tactics,
                        recommendedOptionID: segment.recommendedOptionID,
                        displaySize: geo.size,
                        progress: adviceMoment == segment.id ? arrowProgress : 1
                    )
                    .allowsHitTesting(false)
                }
            }
        }
        .aspectRatio(videoAspectRatio, contentMode: .fit)
        .background(Color.black)
        .overlay(alignment: .topTrailing) {
            Menu {
                Section("動画に重ねる") {
                    Toggle("選手（検出枠）", isOn: $showPlayers)
                    Toggle("コートの白線", isOn: $showFieldLines)
                    Toggle("空いたスペース（点線）", isOn: $showOpenSpaces)
                    Toggle("アドバイス（選択肢の矢印）", isOn: $showAdvice)
                }
                Section {
                    Toggle("注目場面で止めて解説", isOn: $pauseAtAdvice)
                    Toggle("俯瞰図", isOn: $showBirdsEye)
                }
            } label: {
                Image(systemName: showPlayers || showFieldLines || showOpenSpaces || showAdvice ? "eye.fill" : "eye.slash")
                    .padding(8)
                    .background(.black.opacity(0.5))
                    .foregroundStyle(.white)
                    .clipShape(Circle())
            }
            .padding(8)
        }
        .overlay(alignment: .topLeading) {
            focusBadge
        }
        .overlay(alignment: .leading) {
            sceneJumpButton(next: false)
        }
        .overlay(alignment: .trailing) {
            sceneJumpButton(next: true)
        }
    }

    /// マーカーを付けている選手と、解除ボタン
    @ViewBuilder
    private var focusBadge: some View {
        if let focusedPlayer {
            Button {
                focusPath = nil
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "scope")
                    Text("\(focusedPlayer.displayName(teams: record.teams)) を追跡中")
                    Image(systemName: "xmark.circle.fill")
                }
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.yellow, in: Capsule())
                .foregroundStyle(.black)
            }
            .padding(8)
            .accessibilityLabel("\(focusedPlayer.displayName(teams: record.teams)) の追跡を解除")
        }
    }

    /// 選手のマーカーを付ける・外す。今の場面に写っていなければ、次に写る場面へ移動する
    private func toggleFocus(playerID: Int) {
        guard let target = record.player(id: playerID) else { return }
        toggleFocus(target)
    }

    private func toggleFocus(_ target: PlayerIdentity) {
        if focusPath?.playerID == target.id {
            focusPath = nil
            return
        }
        let path = PlayerFocusPath(frames: record.frames, playerID: target.id)
        guard !path.isEmpty else { return }
        focusPath = path
        if path.box(at: currentTime) == nil, let time = path.nextAppearance(after: currentTime) {
            jump(to: time)
        }
    }

    private func setupPlayerIfNeeded() {
        guard let videoURL, player.currentItem == nil else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: videoURL))
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { time in
            let previous = currentTime
            currentTime = CMTimeGetSeconds(time)
            pauseAtAdviceMomentIfNeeded(from: previous, to: currentTime)
        }
    }

    // MARK: - Advice moment

    private var adviceMomentSegment: SceneSegment? {
        adviceMoment.flatMap { id in record.segments?.first { $0.id == id } }
    }

    /// 再生中に注目時点を通り過ぎたら、一時停止して矢印を伸ばしながら解説する
    private func pauseAtAdviceMomentIfNeeded(from previous: Double, to now: Double) {
        // シークで大きく飛んだときは止めない
        guard showAdvice, pauseAtAdvice, adviceMoment == nil, player.rate > 0,
              now > previous, now - previous < 2 else { return }
        guard let segment = record.segments?.first(where: { segment in
            guard let tactics = segment.tactics, !tactics.options.isEmpty else { return false }
            return tactics.timestamp > previous && tactics.timestamp <= now && !shownMoments.contains(segment.id)
        }), let tactics = segment.tactics else { return }

        player.pause()
        seek(to: tactics.timestamp)
        shownMoments.insert(segment.id)
        arrowProgress = 0
        withAnimation(.spring(duration: 0.4)) {
            adviceMoment = segment.id
        }
        withAnimation(.easeOut(duration: 1.4).delay(0.2)) {
            arrowProgress = 1
        }
    }

    private func replayAdviceAnimation() {
        arrowProgress = 0
        withAnimation(.easeOut(duration: 1.4)) {
            arrowProgress = 1
        }
    }

    private func resumeAfterAdvice() {
        withAnimation(.easeInOut(duration: 0.25)) {
            adviceMoment = nil
        }
        player.play()
    }

    /// 一時停止した注目時点の解説（おすすめの選択肢と理由）
    private func adviceMomentCard(_ segment: SceneSegment) -> some View {
        let tactics = segment.tactics
        let recommended = tactics?.options.first(where: { $0.id == segment.recommendedOptionID })
        let recommendedComment = recommended.flatMap { comment(for: $0, in: segment) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(.yellow)
                Text(segment.commentary?.headline ?? segment.title)
                    .font(.headline)
                Spacer()
                Text(DurationText.clock(tactics?.timestamp ?? segment.keyTime))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if let recommended {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(recommended.id)")
                        .font(.caption.bold())
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.yellow))
                        .foregroundStyle(.black)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("おすすめ: \(recommended.summary)")
                            .font(.subheadline.bold())
                        if let recommendedComment {
                            Text(recommendedComment)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let suggestion = segment.commentary?.suggestion {
                Label(suggestion, systemImage: "quote.bubble")
                    .font(.subheadline)
            }

            HStack {
                Button {
                    replayAdviceAnimation()
                } label: {
                    Label("もう一度", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button {
                    resumeAfterAdvice()
                } label: {
                    Label("続きを再生", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .font(.subheadline)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.yellow.opacity(0.6), lineWidth: 1.5))
        .cornerRadius(12)
    }

    /// 選択肢への AI の評価（選択肢と同じ順番で保存している）
    private func comment(for option: TacticalOption, in segment: SceneSegment) -> String? {
        guard let comments = segment.commentary?.optionComments,
              let index = segment.tactics?.options.firstIndex(where: { $0.id == option.id }),
              comments.indices.contains(index) else { return nil }
        return comments[index]
    }

    // MARK: - Scene navigation

    private var sortedSegments: [SceneSegment] {
        (record.segments ?? []).sorted { $0.startTime < $1.startTime }
    }

    /// シーンの始めに移動した直後でも前のシーンと取り違えないための余裕（秒）
    private static let sceneTimeTolerance = 0.25

    /// 再生位置のシーン（シーンの間にいるときは直前のシーン）
    ///
    /// シーンの終わりと次のシーンの始めが同じ時刻のことがあるため、始まりの時刻だけで決める。
    private var currentSceneIndex: Int? {
        sortedSegments.lastIndex(where: { $0.startTime <= currentTime + Self.sceneTimeTolerance })
    }

    /// 再生位置より後に始まる最初のシーン
    private var nextScene: SceneSegment? {
        sortedSegments.first { $0.startTime > currentTime + Self.sceneTimeTolerance }
    }

    /// シーンの始めから 3 秒以上たっていればそのシーンの始め、そうでなければ前のシーン
    private var previousScene: SceneSegment? {
        let segments = sortedSegments
        guard let index = currentSceneIndex else { return nil }
        if currentTime - segments[index].startTime > 3 || index == 0 {
            return segments[index]
        }
        return segments[index - 1]
    }

    /// 前後のシーンへ移動するボタン（動画の下）
    @ViewBuilder
    private var sceneNavigator: some View {
        let segments = sortedSegments
        if !segments.isEmpty {
            let index = currentSceneIndex
            HStack(spacing: 12) {
                Button {
                    jumpToPreviousScene()
                } label: {
                    Label("前のシーン", systemImage: "backward.end.fill")
                        .frame(height: 36)
                }
                .buttonStyle(.bordered)
                .disabled(previousScene == nil)

                VStack(spacing: 2) {
                    Text(index.map { "シーン \($0 + 1) / \(segments.count)" } ?? "シーン \(segments.count) 件")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if let index {
                        Label(segments[index].commentary?.headline ?? segments[index].title, systemImage: segments[index].kind.systemImage)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)

                Button {
                    jumpToNextScene()
                } label: {
                    Label("次のシーン", systemImage: "forward.end.fill")
                        .frame(height: 36)
                }
                .buttonStyle(.borderedProminent)
                .disabled(nextScene == nil)
            }
            .labelStyle(.iconOnly)
        }
    }

    /// 動画の左右に重ねる、前後のシーンへ移動するボタン（スクロールしても動画の上で押せるように）
    @ViewBuilder
    private func sceneJumpButton(next: Bool) -> some View {
        if !sortedSegments.isEmpty, next ? nextScene != nil : previousScene != nil {
            Button {
                if next { jumpToNextScene() } else { jumpToPreviousScene() }
            } label: {
                Image(systemName: next ? "forward.end.fill" : "backward.end.fill")
                    .font(.subheadline.bold())
                    .padding(10)
                    .background(.black.opacity(0.5), in: Circle())
                    .foregroundStyle(.white)
            }
            .padding(8)
            .accessibilityLabel(next ? "次のシーン" : "前のシーン")
        }
    }

    private func jumpToNextScene() {
        guard let nextScene else { return }
        jumpToScene(nextScene)
    }

    private func jumpToPreviousScene() {
        guard let previousScene else { return }
        jumpToScene(previousScene)
    }

    private func jumpToScene(_ segment: SceneSegment) {
        adviceMoment = nil
        // 移動したシーンでは、注目時点でもう一度止めて解説する
        shownMoments.remove(segment.id)
        if videoURL != nil {
            seek(to: segment.startTime)
            player.play()
        } else {
            jump(to: segment.keyTime)
        }
    }

    // MARK: - Bird's-eye view

    /// 表示中の場面を真上から見た図
    @ViewBuilder
    private var birdsEyeSection: some View {
        if let frame = nearestFrame(to: currentTime) {
            let lines = showFieldLines ? fieldLines(near: frame) : nil
            let segment = currentSegment
            let tactics = segment?.tactics.flatMap { tactics in
                showAdvice && (adviceMoment == segment?.id || abs(currentTime - tactics.timestamp) <= 1.0) ? tactics : nil
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("俯瞰図", systemImage: "square.grid.3x3.topleft.filled")
                    .font(.headline)
                BirdsEyeView(
                    frame: frame,
                    teams: record.teams,
                    players: record.players,
                    aspectRatio: Double(videoAspectRatio),
                    lines: lines?.lines ?? [],
                    lineShift: lines?.shift ?? .zero,
                    spaces: showOpenSpaces ? SpaceFinder.spaces(in: frame, aspectRatio: Double(videoAspectRatio)) : [],
                    tactics: tactics,
                    recommendedOptionID: segment?.recommendedOptionID,
                    focusedPlayerID: focusPath?.playerID
                )
                .frame(height: 220)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
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

    /// 白線とボール周辺の空いた場所
    @ViewBuilder
    private func fieldOverlay(for frame: SavedFrame, size: CGSize) -> some View {
        let lines = showFieldLines ? fieldLines(near: frame) : nil
        let spaces = showOpenSpaces ? SpaceFinder.spaces(in: frame, aspectRatio: Double(videoAspectRatio)) : []
        if lines != nil || !spaces.isEmpty {
            FieldOverlayView(lines: lines?.lines ?? [], lineShift: lines?.shift ?? .zero, spaces: spaces, displaySize: size)
        }
    }

    /// 表示中のフレームに最も近い、白線を求めたフレーム（1 秒ごと）の白線
    ///
    /// 間のフレームでは、カメラの動きの分だけ白線をずらして重ねる。
    /// 画面が切り替わった所をまたぐとずらしても合わないため、同じ場面のフレームだけを使う。
    private func fieldLines(near frame: SavedFrame) -> (lines: [FieldLine], shift: CGPoint)? {
        func crossesSceneCut(_ source: SavedFrame) -> Bool {
            let earlier = min(source.timestamp, frame.timestamp)
            let later = max(source.timestamp, frame.timestamp)
            // sceneCut は直前のフレームとの間で切り替わったことを表す
            return record.frames.contains { $0.timestamp > earlier && $0.timestamp <= later && $0.sceneCut == true }
        }
        guard let source = record.frames
            .filter({ $0.fieldLines?.isEmpty == false && abs($0.timestamp - frame.timestamp) <= 1.0 })
            .sorted(by: { abs($0.timestamp - frame.timestamp) < abs($1.timestamp - frame.timestamp) })
            .first(where: { !crossesSceneCut($0) }),
              let lines = source.fieldLines else { return nil }
        // 画面上の位置 + カメラの移動量 = 動画全体で共通の位置
        let from = source.cameraOffset ?? .zero
        let to = frame.cameraOffset ?? .zero
        return (lines, CGPoint(x: from.x - to.x, y: from.y - to.y))
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
                    if viewModel.retryingRecordID == record.id {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("AI解説を作成中...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(record.adviceUnavailableReason ?? "この場面のAI解説はまだありません")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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

    /// チームと識別した選手（タップするとその選手にマーカーを付け続ける）
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

                Text("背番号が読めた選手は #番号、読めなかった選手は登場順に A, B, C… で呼んでいます。タップするとその選手にマーカーを付け続け、動きへのアドバイスを作成します（もう一度タップで解除）。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                reidentifyMenu
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    /// 1チームの人数を指定して選手の識別だけをやり直す（検出はやり直さないためすぐ終わる）
    @ViewBuilder
    private var reidentifyMenu: some View {
        if viewModel.reidentifyingRecordID == record.id {
            HStack(spacing: 8) {
                ProgressView()
                Text("選手の識別をやり直しています...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Menu {
                ForEach(AnalysisSettings.playersPerTeamOptions, id: \.self) { count in
                    Button {
                        focusPath = nil
                        viewModel.reidentifyPlayers(recordID: record.id, playersPerTeam: count)
                    } label: {
                        if record.playersPerTeam == count {
                            Label(AnalysisSettings.label(forPlayersPerTeam: count), systemImage: "checkmark")
                        } else {
                            Text(AnalysisSettings.label(forPlayersPerTeam: count))
                        }
                    }
                }
            } label: {
                Label(
                    record.playersPerTeam.map { "\(AnalysisSettings.label(forPlayersPerTeam: $0))で識別済み・人数を変えて識別し直す" }
                        ?? "1チームの人数を指定して識別し直す",
                    systemImage: "person.2.badge.gearshape"
                )
                .font(.caption)
            }
        }
    }

    private func playerChips(_ players: [PlayerIdentity], color: Color) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(players) { player in
                    let isFocused = focusPath?.playerID == player.id
                    Button {
                        toggleFocus(player)
                    } label: {
                        HStack(spacing: 3) {
                            if isFocused {
                                Image(systemName: "scope")
                            }
                            Text(player.label)
                                .monospacedDigit()
                        }
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(isFocused ? Color.yellow : color.opacity(0.2)))
                        .overlay(Capsule().strokeBorder(isFocused ? Color.yellow : color, lineWidth: 1))
                        .foregroundStyle(isFocused ? Color.black : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isFocused ? .isSelected : [])
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
                        let frame = legacyFrames[selectedFrameIndex]
                        fieldOverlay(for: frame, size: geo.size)
                        DetectionOverlayView(
                            detections: frame.detections,
                            teams: record.teams,
                            players: record.players,
                            displaySize: geo.size,
                            focusedPlayerID: focusPath?.playerID,
                            onSelectPlayer: toggleFocus(playerID:)
                        )
                        if let focusPath, let focusedPlayer {
                            PlayerFocusMarker(path: focusPath, label: focusedPlayer.label, displaySize: geo.size) {
                                frame.timestamp
                            }
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .aspectRatio(videoAspectRatio, contentMode: .fit)
            .background(Color.black)
            .overlay(alignment: .topLeading) {
                focusBadge
            }

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
