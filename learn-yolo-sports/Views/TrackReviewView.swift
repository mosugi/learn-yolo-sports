//
//  TrackReviewView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/11.
//

import SwiftUI

/// 1人の選手（追跡 ID）を追いかけて、フレームごとに追跡の正誤を記録するパネル
///
/// 正誤を付けると次のフレームへ進むので、ボタンを押していくだけで評価できる。
struct TrackReviewPanel: View {
    @Environment(AnalysisStore.self) private var store

    let record: SavedAnalysis
    let trackID: Int
    /// 表示中のフレーム
    let frame: SavedFrame
    /// 指定したフレーム番号へ移動する
    let onJump: (Int) -> Void
    let onClose: () -> Void

    @State private var errorMessage: String?
    @State private var showingResetConfirmation = false

    private var frames: [SavedFrame] {
        record.framesWithImages
    }

    private var marks: [Int: TrackReviewMark] {
        record.trackReviews?[trackID] ?? [:]
    }

    private var detection: SavedDetection? {
        frame.detections.first { $0.trackID == trackID }
    }

    var body: some View {
        let appearances = record.frameNumbers(of: trackID)

        VStack(alignment: .leading, spacing: 14) {
            header(appearances: appearances)

            TrackTimeline(frames: frames, trackID: trackID, marks: marks, currentFrameNumber: frame.frameNumber, onJump: onJump)
                .frame(height: 28)

            markButtons

            navigation(appearances: appearances)

            Divider()

            summary(record.evaluation(of: trackID), title: "この選手の評価")

            if record.reviewedTrackIDs.count > 1 {
                summary(record.overallEvaluation, title: "評価した \(record.reviewedTrackIDs.count) 人の合計")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !marks.isEmpty {
                Button("この選手の評価をリセット", role: .destructive) {
                    showingResetConfirmation = true
                }
                .font(.caption)
                .confirmationDialog("評価をリセットしますか？", isPresented: $showingResetConfirmation, titleVisibility: .visible) {
                    Button("リセット", role: .destructive) { reset() }
                    Button("キャンセル", role: .cancel) {}
                }
            }
        }
        .padding()
    }

    // MARK: - Sections

    private func header(appearances: [Int]) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Label("追跡を評価中", systemImage: "scope")
                    .font(.headline)
                Text(trackLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("枠があるフレーム \(appearances.count) / \(frames.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("評価を終える")
        }
    }

    private var trackLabel: String {
        var sample = detection
        if sample == nil {
            for savedFrame in record.frames {
                if let match = savedFrame.detections.first(where: { $0.trackID == trackID }) {
                    sample = match
                    break
                }
            }
        }
        return sample?.label(trackNumbers: record.effectiveTrackNumbers) ?? "ID\(trackID)"
    }

    @ViewBuilder
    private var markButtons: some View {
        let options = detection == nil ? TrackReviewMark.withoutBox : TrackReviewMark.withBox
        VStack(alignment: .leading, spacing: 6) {
            Text(detection == nil
                 ? "このフレームには枠がありません。選手は見えていますか？"
                 : "白枠の人は、追いかけている選手ですか？")
                .font(.subheadline)

            HStack(spacing: 8) {
                ForEach(options, id: \.self) { mark in
                    let isSelected = marks[frame.frameNumber] == mark
                    Button {
                        setMark(isSelected ? nil : mark)
                    } label: {
                        Label(mark.displayName, systemImage: mark.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(isSelected ? mark.color : mark.color.opacity(0.15))
                            .foregroundStyle(isSelected ? .white : mark.color)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(detection == nil
                 ? "見えない: 画面外や他の人の陰に隠れている。見失い: 見えているのに枠がない"
                 : "チーム違い: 同じ選手だがチームの判定が違う。別の人: 追跡が他の人に乗り移っている")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func navigation(appearances: [Int]) -> some View {
        let current = frame.frameNumber
        let previousAppearance = appearances.last { $0 < current }
        let nextAppearance = appearances.first { $0 > current }
        let nextUnreviewed = frames.first { $0.frameNumber > current && marks[$0.frameNumber] == nil }?.frameNumber

        return HStack {
            Button {
                if let previousAppearance { onJump(previousAppearance) }
            } label: {
                Label("前に映る", systemImage: "backward.end")
            }
            .disabled(previousAppearance == nil)

            Spacer()

            Button {
                if let nextUnreviewed { onJump(nextUnreviewed) }
            } label: {
                Label("未評価へ", systemImage: "forward")
            }
            .disabled(nextUnreviewed == nil)

            Spacer()

            Button {
                if let nextAppearance { onJump(nextAppearance) }
            } label: {
                Label("次に映る", systemImage: "forward.end")
            }
            .disabled(nextAppearance == nil)
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
    }

    private func summary(_ evaluation: TrackEvaluation, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title)（\(evaluation.reviewedCount) フレーム）")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 12) {
                StatView(title: "追跡の正解率", value: TrackEvaluation.percent(evaluation.trackingAccuracy), icon: "scope")
                StatView(title: "チームの正解率", value: TrackEvaluation.percent(evaluation.teamAccuracy), icon: "tshirt")
                StatView(title: "乗り移り", value: "\(evaluation.switched)", icon: "arrow.triangle.swap")
                StatView(title: "見失い", value: "\(evaluation.lost)", icon: "questionmark.circle")
            }
        }
    }

    // MARK: - Actions

    /// 評価を記録し、次の未評価のフレームへ進む（取り消しのときは進まない）
    private func setMark(_ mark: TrackReviewMark?) {
        let frameNumber = frame.frameNumber
        do {
            try store.modify(record.id) { record in
                var reviews = record.trackReviews ?? [:]
                var trackMarks = reviews[trackID] ?? [:]
                trackMarks[frameNumber] = mark
                reviews[trackID] = trackMarks.isEmpty ? nil : trackMarks
                record.trackReviews = reviews
            }
            errorMessage = nil
        } catch {
            errorMessage = "保存できませんでした: \(error.localizedDescription)"
            return
        }

        // 評価済みのフレームに進んで上書きしないよう、未評価のフレームへ進む
        if mark != nil, let next = frames.first(where: { $0.frameNumber > frameNumber && marks[$0.frameNumber] == nil }) {
            onJump(next.frameNumber)
        }
    }

    private func reset() {
        do {
            try store.modify(record.id) { record in
                record.trackReviews?[trackID] = nil
            }
        } catch {
            errorMessage = "リセットできませんでした: \(error.localizedDescription)"
        }
    }
}

/// フレームごとの、枠の有無と評価を並べた帯
///
/// 灰色は枠あり・未評価、空白は枠なし・未評価、色は評価済み。タップしたフレームへ移動する。
struct TrackTimeline: View {
    let frames: [SavedFrame]
    let trackID: Int
    let marks: [Int: TrackReviewMark]
    let currentFrameNumber: Int
    let onJump: (Int) -> Void

    var body: some View {
        let hasBox = frames.map { frame in frame.detections.contains { $0.trackID == trackID } }

        GeometryReader { geometry in
            let count = max(1, frames.count)
            let cellWidth = geometry.size.width / CGFloat(count)

            Canvas { context, size in
                for (index, frame) in frames.enumerated() {
                    let rect = CGRect(x: CGFloat(index) * cellWidth, y: 4, width: max(1, cellWidth), height: size.height - 8)
                    let color: Color
                    if let mark = marks[frame.frameNumber] {
                        color = mark.color
                    } else if hasBox[index] {
                        color = .gray.opacity(0.6)
                    } else {
                        color = .gray.opacity(0.12)
                    }
                    context.fill(Path(rect), with: .color(color))

                    if frame.frameNumber == currentFrameNumber {
                        let marker = CGRect(x: rect.midX - 1.5, y: 0, width: 3, height: size.height)
                        context.fill(Path(marker), with: .color(.primary))
                    }
                }
            }
            .contentShape(Rectangle())
            // ドラッグは親の ScrollView のスクロールに任せ、タップだけを受け取る
            .onTapGesture { location in
                let index = Int(location.x / cellWidth)
                if frames.indices.contains(index) {
                    onJump(frames[index].frameNumber)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("フレームごとの評価")
    }
}
