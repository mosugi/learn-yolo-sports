//
//  DetectionOverlayView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI

/// フレーム画像に検出結果とコートのラインを重ねて表示するビュー
///
/// 画像は縦横比を保って枠に収め、検出枠も同じ位置に合わせる。
struct AnnotatedFrameView: View {
    let image: CGImage
    let detections: [SavedDetection]
    /// コートのライン（正規化座標の線分）
    var courtLines: [(CGPoint, CGPoint)] = []
    /// ラベルを表示するか（小さな表示では省く）
    var showsLabels = true
    /// 追跡 ID ごとの背番号
    var trackNumbers: [Int: Int] = [:]
    /// 強調表示する追跡 ID（他の枠は薄く表示する）
    var focusedTrackID: Int? = nil
    /// 枠をタップしたとき
    var onTapDetection: ((SavedDetection) -> Void)? = nil

    var body: some View {
        GeometryReader { geometry in
            let imageSize = CGSize(width: image.width, height: image.height)
            let fit = ImageFit.rect(imageSize: imageSize, in: geometry.size)

            ZStack(alignment: .topLeading) {
                Image(uiImage: UIImage(cgImage: image))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)

                // コートのライン
                Path { path in
                    for (start, end) in courtLines {
                        path.move(to: point(start, in: fit))
                        path.addLine(to: point(end, in: fit))
                    }
                }
                .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))

                ForEach(Array(detections.enumerated()), id: \.offset) { _, detection in
                    let box = rect(detection.boundingBox, in: fit)
                    let color = detection.displayColor
                    let isFocused = focusedTrackID != nil && detection.trackID == focusedTrackID
                    let isDimmed = focusedTrackID != nil && !isFocused

                    if isFocused {
                        // 追跡中の選手は白い縁取りで目立たせる
                        Rectangle()
                            .strokeBorder(Color.white, lineWidth: 5)
                            .frame(width: max(box.width, 2) + 6, height: max(box.height, 2) + 6)
                            .position(x: box.midX, y: box.midY)
                    }

                    Rectangle()
                        .strokeBorder(
                            color,
                            style: StrokeStyle(
                                lineWidth: isFocused ? 3 : (detection.isExcluded ? 1 : 2),
                                dash: detection.isExcluded ? [3, 3] : []
                            )
                        )
                        .frame(width: max(box.width, 2), height: max(box.height, 2))
                        .position(x: box.midX, y: box.midY)
                        .opacity(isDimmed ? 0.3 : 1)

                    if showsLabels && !detection.isExcluded && !isDimmed {
                        Text(label(for: detection))
                            .font(.system(size: isFocused ? 11 : 9, weight: .bold))
                            .padding(.horizontal, 3)
                            .background(color)
                            .foregroundStyle(.black)
                            .cornerRadius(3)
                            .fixedSize()
                            .position(x: box.midX, y: max(6, box.minY - 7))
                    }
                }

                if let onTapDetection {
                    // 小さな枠もタップしやすいよう、最も近い枠を選ぶ
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            if let detection = nearestDetection(to: location, in: fit) {
                                onTapDetection(detection)
                            }
                        }
                }
            }
        }
        .clipped()
    }

    /// タップした位置に最も近い、追跡 ID のある枠（離れすぎている場合は nil）
    private func nearestDetection(to location: CGPoint, in fit: CGRect) -> SavedDetection? {
        detections
            .filter { $0.trackID != nil && !$0.isExcluded }
            .map { detection -> (SavedDetection, CGFloat) in
                let box = rect(detection.boundingBox, in: fit)
                let dx = max(box.minX - location.x, 0, location.x - box.maxX)
                let dy = max(box.minY - location.y, 0, location.y - box.maxY)
                return (detection, hypot(dx, dy))
            }
            .filter { $0.1 <= 24 }
            .min { $0.1 < $1.1 }
            .map { $0.0 }
    }

    private func label(for detection: SavedDetection) -> String {
        detection.label(trackNumbers: trackNumbers)
    }

    private func point(_ normalized: CGPoint, in fit: CGRect) -> CGPoint {
        CGPoint(x: fit.minX + normalized.x * fit.width, y: fit.minY + normalized.y * fit.height)
    }

    private func rect(_ normalized: CGRect, in fit: CGRect) -> CGRect {
        CGRect(
            x: fit.minX + normalized.minX * fit.width,
            y: fit.minY + normalized.minY * fit.height,
            width: normalized.width * fit.width,
            height: normalized.height * fit.height
        )
    }
}

/// 保存済みのフレームを読み込んで、検出結果を重ねて表示する
struct SavedFrameView: View {
    @Environment(AnalysisStore.self) private var store
    let record: SavedAnalysis
    let frame: SavedFrame
    var showsLabels = true
    var focusedTrackID: Int? = nil
    var onTapDetection: ((SavedDetection) -> Void)? = nil

    @State private var image: CGImage?
    @State private var didLoad = false

    var body: some View {
        ZStack {
            Color.black
            if let image {
                AnnotatedFrameView(
                    image: image,
                    detections: frame.detections,
                    courtLines: record.setup.flatMap { CourtGeometry(setup: $0) }?.imageLineSegments() ?? [],
                    showsLabels: showsLabels,
                    trackNumbers: record.effectiveTrackNumbers,
                    focusedTrackID: focusedTrackID,
                    onTapDetection: onTapDetection
                )
            } else if didLoad {
                ContentUnavailableView("画像なし", systemImage: "photo")
                    .foregroundStyle(.white)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .task(id: frame.id) {
            didLoad = false
            image = await store.image(for: frame, in: record)
            didLoad = true
        }
    }
}

/// 検出結果リスト表示
struct DetectionListView: View {
    let detections: [SavedDetection]
    var trackNumbers: [Int: Int] = [:]
    /// 追跡 ID のある人をタップしたとき（追跡の評価と背番号の割り当てに使う）
    var onSelectPlayer: ((SavedDetection) -> Void)? = nil

    var body: some View {
        LazyVStack(spacing: 8) {
            ForEach(Array(detections.enumerated()), id: \.offset) { _, detection in
                row(detection)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if detection.trackID != nil, !detection.isExcluded {
                            onSelectPlayer?(detection)
                        }
                    }
            }
        }
        .padding()
    }

    private func row(_ detection: SavedDetection) -> some View {
        HStack {
            Circle()
                .fill(detection.displayColor)
                .frame(width: 12, height: 12)

            Text(detection.label(trackNumbers: trackNumbers))
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(detection.isExcluded ? .secondary : .primary)

            if let position = detection.pitchPosition, !detection.isExcluded {
                Text(String(format: "(%.0f, %.0f) m", Double(position.x), Double(position.y)))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if detection.trackID != nil, !detection.isExcluded, onSelectPlayer != nil {
                Image(systemName: "scope")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("\(detection.confidencePercentage)%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(detection.displayColor.opacity(0.2))
                .cornerRadius(8)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

#Preview("List") {
    DetectionListView(detections: [
        SavedDetection(label: "player", confidence: 0.92, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.05, height: 0.15), pitchPosition: CGPoint(x: 30, y: 20), inCourt: true, team: .own, trackID: 3),
        SavedDetection(label: "player", confidence: 0.81, boundingBox: CGRect(x: 0.3, y: 0.2, width: 0.05, height: 0.15), pitchPosition: CGPoint(x: 40, y: 25), inCourt: true, team: .opponent, trackID: 5),
        SavedDetection(label: "ball", confidence: 0.85, boundingBox: CGRect(x: 0.5, y: 0.5, width: 0.01, height: 0.01)),
        SavedDetection(label: "player", confidence: 0.6, boundingBox: CGRect(x: 0.8, y: 0.1, width: 0.02, height: 0.05), inCourt: false),
    ])
}
