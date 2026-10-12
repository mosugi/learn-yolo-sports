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
    /// 直前にシーンの移動で移った時刻（移動直後の再生位置のずれを吸収する）
    @State private var sceneJumpTarget: Double?
    /// 動画に重ねるもの（設定は保存する）
    @AppStorage("showPlayerBoxes") private var showPlayers = true
    @AppStorage("showTacticalAdvice") private var showAdvice = true
    @AppStorage("pauseAtAdvice") private var pauseAtAdvice = true
    @AppStorage("showBirdsEye") private var showBirdsEye = false
    /// 注目時点で止めて、書き込みながら解説している流れ
    @State private var telestration: TelestrationScript?
    @State private var telestrationStepIndex = 0
    /// 書き込みの進み具合（0 から 1 へアニメーションする）
    @State private var telestrationProgress = 1.0
    /// 実際の選択を見せるため、ゆっくり再生している
    @State private var telestrationIsPlaying = false
    /// 書き込みを自動で次の手順へ進める
    @State private var telestrationAutoAdvance = true
    @State private var telestrationTask: Task<Void, Never>?
    /// 解説した場面（同じ再生で何度も止めないため）
    @State private var shownMoments: Set<SceneSegment.ID> = []
    /// ダイジェスト再生中のシーン（nil はダイジェストではない）
    @State private var digestSegmentID: SceneSegment.ID?
    /// 試合の流れ（実況の出来事・ボール保持率）
    @State private var playByPlay: MatchPlayByPlay?
    /// 動画の上に実況の一言を出す
    @AppStorage("showPlayByPlay") private var showPlayByPlay = true
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
                        digestBar
                            .padding(.horizontal)
                        if let telestration {
                            telestrationCard(telestration)
                                .padding(.horizontal)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        } else if let segment = currentSegment, segment.tactics?.options.isEmpty == false {
                            Button {
                                startTelestration(for: segment)
                            } label: {
                                Label("このシーンを書き込みで解説", systemImage: "pencil.and.scribble")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .padding(.horizontal)
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

                    if let playByPlay {
                        MatchCommentaryView(record: record, playByPlay: playByPlay, currentTime: currentTime) { time in
                            jump(to: time)
                        }
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
        // 実況の出来事は保存せず、表示するときに解析結果から求める（選手の識別をやり直すと変わる）
        .task(id: playByPlayKey) {
            let record = record
            playByPlay = await Task.detached(priority: .userInitiated) {
                MatchPlayByPlay(record: record)
            }.value
        }
        .onDisappear { teardownPlayer() }
    }

    /// 実況の出来事を求め直す目安（選手の識別・シーンが変わったとき）
    private var playByPlayKey: String {
        "\(record.id)-\(record.trackingVersion ?? 0)-\(record.players?.count ?? 0)-\(record.segments?.count ?? 0)-\(record.teams?.count ?? 0)"
    }

    // MARK: - Player

    private func playerSection(videoURL: URL) -> some View {
        GeometryReader { geo in
            ZStack {
                VideoPlayer(player: player)
                if let telestration {
                    // 書き込み中は他の表示を消し、書き込みだけにする
                    telestrationLayer(telestration, size: geo.size)
                } else {
                    playbackOverlays(size: geo.size)
                }
            }
        }
        .aspectRatio(videoAspectRatio, contentMode: .fit)
        .background(Color.black)
        .overlay(alignment: .topTrailing) {
            overlayMenu
        }
        .overlay(alignment: .topLeading) {
            if telestration == nil {
                focusBadge
            }
        }
        .overlay(alignment: .leading) {
            sceneJumpButton(next: false)
        }
        .overlay(alignment: .trailing) {
            sceneJumpButton(next: true)
        }
    }

    /// 通常の再生中に重ねる表示（白線・スペース・検出枠・選手のマーカー・選択肢の矢印）
    private func playbackOverlays(size: CGSize) -> some View {
        ZStack {
            // 白線とスペースは、検出枠の表示とは別に切り替える
            if let frame = nearestFrame(to: currentTime) {
                fieldOverlay(for: frame, size: size)
            }
            if showPlayers, let frame = nearestFrame(to: currentTime) {
                DetectionOverlayView(
                    detections: frame.detections,
                    teams: record.teams,
                    players: record.players,
                    displaySize: size,
                    focusedPlayerID: focusPath?.playerID,
                    onSelectPlayer: toggleFocus(playerID:)
                )
            }
            // 選んだ選手のマーカーは、枠の表示を消していても出す
            if let focusPath, let focusedPlayer {
                PlayerFocusMarker(path: focusPath, label: focusedPlayer.label, displaySize: size) {
                    let seconds = CMTimeGetSeconds(player.currentTime())
                    return seconds.isFinite ? seconds : 0
                }
            }
            // 実況の一言（直前の出来事）
            if showPlayByPlay, let event = playByPlay?.latestEvent(at: currentTime) {
                playByPlayCaption(event)
            }
            // 注目時点の前後では選択肢の矢印も重ねる
            if showAdvice, let segment = currentSegment, let tactics = segment.tactics,
               abs(currentTime - tactics.timestamp) <= 1.0 {
                TacticalArrowsView(
                    snapshot: tactics,
                    recommendedOptionID: segment.recommendedOptionID,
                    displaySize: size
                )
                .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// 動画に重ねる内容を選ぶメニュー
    private var overlayMenu: some View {
        Menu {
            Section("動画に重ねる") {
                Toggle("選手（検出枠）", isOn: $showPlayers)
                Toggle("コートの白線", isOn: $showFieldLines)
                Toggle("空いたスペース（点線）", isOn: $showOpenSpaces)
                Toggle("アドバイス（選択肢の矢印）", isOn: $showAdvice)
                Toggle("実況の一言", isOn: $showPlayByPlay)
            }
            Section {
                Toggle("注目場面で止めて書き込み解説", isOn: $pauseAtAdvice)
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

    /// 動画の上に出す実況の一言
    private func playByPlayCaption(_ event: PlayEvent) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "mic.fill")
                .foregroundStyle(record.team(id: event.team)?.color.color ?? .white)
            Text(event.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.caption.bold())
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.6), in: Capsule())
        .id(event.id)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.25), value: event.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 8)
        .padding(.horizontal, 56)
        .allowsHitTesting(false)
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
            advanceDigestIfNeeded()
        }
    }

    // MARK: - Telestration

    private var currentTelestrationStep: TelestrationStep? {
        guard let telestration, telestration.steps.indices.contains(telestrationStepIndex) else { return nil }
        return telestration.steps[telestrationStepIndex]
    }

    /// 再生中に注目時点を通り過ぎたら、止めて書き込みながら解説する
    private func pauseAtAdviceMomentIfNeeded(from previous: Double, to now: Double) {
        // シークで大きく飛んだときや、解説中（実際の選択の再生中）は止めない
        // ダイジェストでは設定にかかわらず、各シーンで止めて解説する
        guard (showAdvice && pauseAtAdvice) || digestSegmentID != nil, telestration == nil, player.rate > 0,
              now > previous, now - previous < 2 else { return }
        guard let segment = record.segments?.first(where: { segment in
            guard let tactics = segment.tactics, !tactics.options.isEmpty else { return false }
            return tactics.timestamp > previous && tactics.timestamp <= now && !shownMoments.contains(segment.id)
        }) else { return }
        startTelestration(for: segment)
    }

    private func startTelestration(for segment: SceneSegment) {
        shownMoments.insert(segment.id)
        guard let script = Telestrator.script(for: segment, in: record) else { return }
        player.pause()
        telestrationAutoAdvance = true
        withAnimation(.spring(duration: 0.4)) {
            telestration = script
        }
        showTelestrationStep(0)
    }

    /// 手順を表示する（実際の選択はゆっくり再生してから止める）
    private func showTelestrationStep(_ index: Int) {
        guard let telestration, telestration.steps.indices.contains(index) else { return }
        telestrationTask?.cancel()
        let step = telestration.steps[index]
        telestrationStepIndex = index
        telestrationProgress = 0
        telestrationIsPlaying = false

        telestrationTask = Task {
            if let playback = step.playback {
                preciseSeek(to: playback.lowerBound)
                telestrationIsPlaying = true
                player.playImmediately(atRate: Telestrator.playbackRate)
                let duration = (playback.upperBound - playback.lowerBound) / Double(Telestrator.playbackRate)
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                telestrationIsPlaying = false
            }
            player.pause()
            preciseSeek(to: step.time)
            withAnimation(.easeOut(duration: 1.6)) {
                telestrationProgress = 1
            }
            guard telestrationAutoAdvance else { return }
            try? await Task.sleep(for: .seconds(1.6 + step.hold))
            guard !Task.isCancelled else { return }
            advanceTelestration()
        }
    }

    private func advanceTelestration() {
        guard let telestration else { return }
        if telestrationStepIndex + 1 < telestration.steps.count {
            showTelestrationStep(telestrationStepIndex + 1)
        } else {
            finishTelestration(resume: true)
        }
    }

    /// 自動で進めるのを止める・再開する
    private func toggleTelestrationAutoAdvance() {
        telestrationAutoAdvance.toggle()
        guard telestrationAutoAdvance, !telestrationIsPlaying, let step = currentTelestrationStep else {
            if !telestrationAutoAdvance, !telestrationIsPlaying {
                telestrationTask?.cancel()
            }
            return
        }
        telestrationTask?.cancel()
        telestrationTask = Task {
            try? await Task.sleep(for: .seconds(step.hold / 2))
            guard !Task.isCancelled else { return }
            advanceTelestration()
        }
    }

    /// 解説を終える（resume なら、実際の選択のあとから続きを再生する）
    private func finishTelestration(resume: Bool) {
        guard telestration != nil || telestrationTask != nil else { return }
        telestrationTask?.cancel()
        telestrationTask = nil
        telestrationIsPlaying = false
        let resumeTime = telestration?.resumeTime
        withAnimation(.easeInOut(duration: 0.25)) {
            telestration = nil
        }
        player.pause()
        if resume, let resumeTime {
            preciseSeek(to: resumeTime)
            player.play()
        }
    }

    /// 書き込みを動画に重ねる
    @ViewBuilder
    private func telestrationLayer(_ script: TelestrationScript, size: CGSize) -> some View {
        if let step = currentTelestrationStep {
            ZStack {
                if telestrationIsPlaying {
                    TelestrationFollowView(
                        follows: step.follows,
                        paths: Dictionary(uniqueKeysWithValues: Set(step.follows.map(\.playerID)).map { id in
                            (id, PlayerFocusPath(frames: record.frames, playerID: id))
                        }),
                        displaySize: size,
                        projection: { time in
                            nearestFrame(to: time).flatMap { GroundProjection(detections: $0.detections, aspectRatio: Double(videoAspectRatio)) }
                        },
                        currentTime: {
                            let seconds = CMTimeGetSeconds(player.currentTime())
                            return seconds.isFinite ? seconds : 0
                        }
                    )
                } else {
                    TelestrationOverlay(
                        step: step,
                        projection: record.frames.first { $0.frameNumber == step.frameNumber }.flatMap {
                            GroundProjection(detections: $0.detections, aspectRatio: Double(videoAspectRatio))
                        },
                        displaySize: size,
                        progress: telestrationProgress
                    )
                }

                // 放送の字幕のように、いまの手順の一言を下に出す
                Text(step.caption)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 10)
                    .padding(.horizontal, 44)
                    .id(step.id)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            .frame(width: size.width, height: size.height)
        }
    }

    /// 書き込み解説の手順と操作
    private func telestrationCard(_ script: TelestrationScript) -> some View {
        let step = currentTelestrationStep
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(Array(script.steps.enumerated()), id: \.element.id) { index, item in
                    Button {
                        showTelestrationStep(index)
                    } label: {
                        Text(item.kind.title)
                            .font(.caption2.bold())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity)
                            .background(
                                Capsule().fill(index == telestrationStepIndex ? Color.yellow : (index < telestrationStepIndex ? Color(.systemGray3) : Color(.systemGray5)))
                            )
                            .foregroundStyle(index == telestrationStepIndex ? Color.black : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let step {
                Text(step.caption)
                    .font(.headline)
                if telestrationIsPlaying {
                    Label("実際のプレーをゆっくり再生しています", systemImage: "slowmo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Button {
                    showTelestrationStep(max(0, telestrationStepIndex - 1))
                } label: {
                    Label("前へ", systemImage: "chevron.backward")
                }
                .disabled(telestrationStepIndex == 0)

                Button {
                    toggleTelestrationAutoAdvance()
                } label: {
                    Label(telestrationAutoAdvance ? "一時停止" : "自動で進む", systemImage: telestrationAutoAdvance ? "pause.fill" : "play.fill")
                }

                Button {
                    advanceTelestration()
                } label: {
                    Label("次へ", systemImage: "chevron.forward")
                }

                Spacer()

                Button {
                    finishTelestration(resume: true)
                } label: {
                    Label("終了", systemImage: "xmark")
                }
                .buttonStyle(.borderedProminent)
            }
            .buttonStyle(.bordered)
            .labelStyle(.iconOnly)
            .font(.subheadline)

            Text("AI が解析結果から自動で書き込んでいます。遠近は写っている選手の大きさからの推定です。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.yellow.opacity(0.6), lineWidth: 1.5))
        .cornerRadius(12)
    }

    // MARK: - Scene navigation

    private var sortedSegments: [SceneSegment] {
        (record.segments ?? []).sorted { $0.startTime < $1.startTime }
    }

    /// シーンの始めに移動した直後、再生位置が少し手前と報告されても移動先のシーンとみなす余裕（秒）
    private static let sceneTimeTolerance = 0.25

    /// シーンの移動に使う再生位置
    ///
    /// シーンへ移動した直後は、再生位置が移動先の少し手前と報告されることがあるため、移動先の時刻とみなす。
    /// それ以外のとき（再生中にシーンの境目に近づいたときなど）は再生位置そのままにして、次のシーンを飛ばさないようにする。
    private var navigationTime: Double {
        if let sceneJumpTarget, currentTime < sceneJumpTarget, sceneJumpTarget - currentTime <= Self.sceneTimeTolerance {
            return sceneJumpTarget
        }
        return currentTime
    }

    /// 再生位置のシーン（シーンの間にいるときは直前のシーン）
    ///
    /// シーンの終わりと次のシーンの始めが同じ時刻のことがあるため、始まりの時刻だけで決める。
    private var currentSceneIndex: Int? {
        let time = navigationTime
        return sortedSegments.lastIndex(where: { $0.startTime <= time })
    }

    /// 再生位置より後に始まる最初のシーン
    private var nextScene: SceneSegment? {
        let time = navigationTime
        return sortedSegments.first { $0.startTime > time }
    }

    /// シーンの始めから 3 秒以上たっていればそのシーンの始め、そうでなければ前のシーン
    private var previousScene: SceneSegment? {
        let segments = sortedSegments
        guard let index = currentSceneIndex else { return nil }
        if navigationTime - segments[index].startTime > 3 || index == 0 {
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
                        .labelStyle(.iconOnly)
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
                        .labelStyle(.iconOnly)
                        .frame(height: 36)
                }
                .buttonStyle(.borderedProminent)
                .disabled(nextScene == nil)
            }
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
        finishTelestration(resume: false)
        if digestSegmentID != nil {
            digestSegmentID = segment.id
        }
        // 移動したシーンでは、注目時点でもう一度止めて解説する
        shownMoments.remove(segment.id)
        if videoURL != nil {
            seek(to: segment.startTime)
            sceneJumpTarget = segment.startTime
            player.play()
        } else {
            jump(to: segment.keyTime)
        }
    }

    // MARK: - Digest

    /// ダイジェストの開始ボタンと、再生中の進み具合
    @ViewBuilder
    private var digestBar: some View {
        let segments = sortedSegments
        if videoURL != nil, !segments.isEmpty {
            if let digestSegmentID, let index = segments.firstIndex(where: { $0.id == digestSegmentID }) {
                HStack(spacing: 8) {
                    Image(systemName: "play.square.stack.fill")
                        .foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ダイジェスト \(index + 1) / \(segments.count)")
                            .font(.caption.bold())
                            .monospacedDigit()
                        Text(segments[index].commentary?.headline ?? segments[index].title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        endDigest()
                    } label: {
                        Label("ダイジェストを終える", systemImage: "stop.fill")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(10)
                .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            } else {
                Button {
                    startDigest()
                } label: {
                    Label("ダイジェストを再生（重要シーン \(segments.count) 件）", systemImage: "play.square.stack")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    /// 重要シーンだけを順に再生し、各シーンで止めて書き込み解説する
    private func startDigest() {
        guard let first = sortedSegments.first else { return }
        finishTelestration(resume: false)
        focusPath = nil
        // 一度解説したシーンでも、ダイジェストではもう一度止める
        shownMoments = []
        digestSegmentID = first.id
        seek(to: first.startTime)
        sceneJumpTarget = first.startTime
        player.play()
    }

    private func endDigest() {
        digestSegmentID = nil
        finishTelestration(resume: false)
        player.pause()
    }

    /// ダイジェスト中に今のシーンを見終えたら、次のシーンの始めへ移る
    private func advanceDigestIfNeeded() {
        guard let digestSegmentID, telestration == nil, player.rate > 0,
              let segment = record.segments?.first(where: { $0.id == digestSegmentID }),
              currentTime >= segment.endTime else { return }
        guard let next = sortedSegments.first(where: { $0.startTime > segment.startTime }) else {
            endDigest()
            return
        }
        self.digestSegmentID = next.id
        seek(to: next.startTime)
        sceneJumpTarget = next.startTime
        player.play()
    }

    // MARK: - Bird's-eye view

    /// 表示中の場面を真上から見た図
    @ViewBuilder
    private var birdsEyeSection: some View {
        if let frame = nearestFrame(to: currentTime) {
            let lines = showFieldLines ? fieldLines(near: frame) : nil
            let segment = currentSegment
            let tactics = segment?.tactics.flatMap { tactics in
                showAdvice && (telestration?.segmentID == segment?.id || abs(currentTime - tactics.timestamp) <= 1.0) ? tactics : nil
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
        telestrationTask?.cancel()
        telestrationTask = nil
        player.pause()
    }

    private func seek(to time: Double) {
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        currentTime = time
        sceneJumpTarget = nil
    }

    /// 書き込みの位置が場面とずれないよう、指定した時刻ちょうどに移動する
    private func preciseSeek(to time: Double) {
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
        sceneJumpTarget = nil
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
