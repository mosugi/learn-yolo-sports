//
//  CourtSetupView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI

/// コートの4点・自チームの色・攻撃方向などを指定する画面
struct CourtSetupView: View {
    @Environment(\.dismiss) private var dismiss

    let image: CGImage
    let onSave: (AnalysisSetup) -> Void

    @State private var format: MatchFormat
    @State private var pitchLength: Double
    @State private var pitchWidth: Double
    @State private var region: ReferenceRegion
    @State private var corners: [CGPoint]
    @State private var ownPoint: CGPoint?
    @State private var ownColor: LabColor?
    @State private var ownAttacksRight: Bool
    @State private var pixels: PixelImage?

    private static let coordinateSpaceName = "setupImage"

    init(image: CGImage, initialSetup: AnalysisSetup?, onSave: @escaping (AnalysisSetup) -> Void) {
        self.image = image
        self.onSave = onSave
        let format = initialSetup?.format ?? .elevenASide
        _format = State(initialValue: format)
        _pitchLength = State(initialValue: initialSetup?.pitchLength ?? format.defaultLength)
        _pitchWidth = State(initialValue: initialSetup?.pitchWidth ?? format.defaultWidth)
        _region = State(initialValue: initialSetup?.region ?? .fullPitch)
        _corners = State(initialValue: initialSetup?.imageCorners ?? [])
        _ownPoint = State(initialValue: initialSetup?.ownSamplePoint)
        _ownColor = State(initialValue: initialSetup?.ownColor)
        _ownAttacksRight = State(initialValue: initialSetup?.ownAttacksRight ?? true)
    }

    /// 入力中の設定（未完了なら nil）
    private var setup: AnalysisSetup? {
        guard corners.count == 4, let ownColor, let ownPoint else { return nil }
        return AnalysisSetup(
            format: format,
            pitchLength: pitchLength,
            pitchWidth: pitchWidth,
            region: region,
            imageCorners: corners,
            ownColor: ownColor,
            ownSamplePoint: ownPoint,
            ownAttacksRight: ownAttacksRight
        )
    }

    private var geometry: CourtGeometry? {
        guard corners.count == 4 else { return nil }
        // 色が未指定でも形だけ確認できるよう、仮の色で組み立てる
        let draft = AnalysisSetup(
            format: format,
            pitchLength: pitchLength,
            pitchWidth: pitchWidth,
            region: region,
            imageCorners: corners,
            ownColor: LabColor(l: 0, a: 0, b: 0),
            ownSamplePoint: .zero,
            ownAttacksRight: ownAttacksRight
        )
        return CourtGeometry(setup: draft)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    instruction
                    imageArea
                    editButtons
                    Divider()
                    courtSettings
                    teamSettings
                }
                .padding()
            }
            .navigationTitle("コート・チームの設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let setup {
                            onSave(setup)
                            dismiss()
                        }
                    }
                    .disabled(setup == nil || geometry == nil)
                }
            }
            .task {
                let image = image
                pixels = await Task.detached { PixelImage(image: image) }.value
            }
        }
    }

    // MARK: - Sections

    private var instruction: some View {
        VStack(alignment: .leading, spacing: 4) {
            if corners.count < 4 {
                Text("\(corners.count + 1). 「\(region.cornerNames[corners.count])」をタップ")
                    .font(.headline)
                Text("画面上の左奥 → 右奥 → 右手前 → 左手前 の順です。全体が写っていない場合は下の「基準」を半分にしてください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if ownColor == nil {
                Text("5. 自チームの選手のユニフォーム（胴体）をタップ")
                    .font(.headline)
                Text("点はドラッグで微調整できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if geometry == nil {
                Text("4点からコートの形を求められません。順番と位置を確認してください。")
                    .font(.headline)
                    .foregroundStyle(.red)
            } else {
                Text("設定が完了しました")
                    .font(.headline)
                Text("点線のコートが実際のラインと重なっているか確認してください。点はドラッグで微調整できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var imageArea: some View {
        Image(uiImage: UIImage(cgImage: image))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let size = proxy.size
                    ZStack {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { location in
                                handleTap(CGPoint(x: location.x / size.width, y: location.y / size.height))
                            }

                        // 指定した基準の長方形と、推定したコート全体
                        Path { path in
                            guard corners.count >= 2 else { return }
                            path.move(to: point(corners[0], size))
                            for corner in corners.dropFirst() {
                                path.addLine(to: point(corner, size))
                            }
                            if corners.count == 4 { path.closeSubpath() }
                        }
                        .stroke(Color.yellow, lineWidth: 2)
                        .allowsHitTesting(false)

                        if let geometry {
                            Path { path in
                                for (start, end) in geometry.imageLineSegments() {
                                    path.move(to: point(start, size))
                                    path.addLine(to: point(end, size))
                                }
                            }
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                            .allowsHitTesting(false)
                        }

                        ForEach(Array(corners.enumerated()), id: \.offset) { index, corner in
                            marker(text: "\(index + 1)", color: .yellow)
                                .position(point(corner, size))
                                .gesture(dragGesture(size: size) { corners[index] = $0 })
                        }

                        if let ownPoint {
                            marker(text: "自", color: TeamSide.own.color)
                                .position(point(ownPoint, size))
                                .gesture(dragGesture(size: size) { moved in
                                    self.ownPoint = moved
                                    sampleOwnColor(at: moved)
                                })
                        }
                    }
                    .coordinateSpace(.named(Self.coordinateSpaceName))
                }
            }
            .cornerRadius(8)
    }

    private var editButtons: some View {
        HStack {
            Button {
                if ownPoint != nil {
                    ownPoint = nil
                    ownColor = nil
                } else if !corners.isEmpty {
                    corners.removeLast()
                }
            } label: {
                Label("1つ戻す", systemImage: "arrow.uturn.backward")
            }
            .disabled(corners.isEmpty && ownPoint == nil)

            Spacer()

            if let ownColor {
                HStack(spacing: 6) {
                    Text("自チームの色")
                        .font(.caption)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(red: ownColor.rgb.red, green: ownColor.rgb.green, blue: ownColor.rgb.blue))
                        .frame(width: 28, height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary))
                }
            }

            Spacer()

            Button(role: .destructive) {
                corners = []
                ownPoint = nil
                ownColor = nil
            } label: {
                Label("やり直す", systemImage: "trash")
            }
            .disabled(corners.isEmpty && ownPoint == nil)
        }
        .font(.subheadline)
    }

    private var courtSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("コート")
                .font(.headline)

            Picker("形式", selection: $format) {
                ForEach(MatchFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: format) { _, newValue in
                pitchLength = newValue.defaultLength
                pitchWidth = newValue.defaultWidth
            }

            Stepper("長さ: \(Int(pitchLength)) m", value: $pitchLength, in: 20...120, step: 1)
            Stepper("幅: \(Int(pitchWidth)) m", value: $pitchWidth, in: 10...90, step: 1)

            Picker("基準（タップする4点）", selection: $region) {
                ForEach(ReferenceRegion.allCases) { region in
                    Text(region.displayName).tag(region)
                }
            }
            .pickerStyle(.segmented)

            Text("寸法は実際のコートに合わせると、距離の精度が上がります。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var teamSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自チーム")
                .font(.headline)

            Picker("攻撃方向", selection: $ownAttacksRight) {
                Text("← 画面左へ攻める").tag(false)
                Text("画面右へ攻める →").tag(true)
            }
            .pickerStyle(.segmented)

            Text("解析する区間で自チームが攻めるゴールの向きです。前半と後半で入れ替わる場合は、区間ごとに解析してください。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func marker(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.black)
            .frame(width: 22, height: 22)
            .background(Circle().fill(color))
            .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 1))
            .contentShape(Circle().inset(by: -10))
    }

    private func dragGesture(size: CGSize, onMove: @escaping (CGPoint) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                onMove(CGPoint(
                    x: min(1, max(0, value.location.x / size.width)),
                    y: min(1, max(0, value.location.y / size.height))
                ))
            }
    }

    private func point(_ normalized: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: normalized.x * size.width, y: normalized.y * size.height)
    }

    private func handleTap(_ location: CGPoint) {
        if corners.count < 4 {
            corners.append(location)
        } else if ownPoint == nil {
            ownPoint = location
            sampleOwnColor(at: location)
        }
    }

    private func sampleOwnColor(at location: CGPoint) {
        let pixels = pixels ?? PixelImage(image: image)
        // タップ位置のまわりの小さな範囲（芝は除く）
        let rect = CGRect(x: location.x - 0.01, y: location.y - 0.02, width: 0.02, height: 0.04)
        ownColor = pixels?.meanColor(in: rect, samplesPerSide: 8)
        if ownColor == nil {
            // 芝ばかりだった場合は点を置かない
            ownPoint = nil
        }
    }
}
