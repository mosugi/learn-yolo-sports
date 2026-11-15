//
//  AppearanceExtractor.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/11.
//

import Foundation
import CoreGraphics
import Vision

/// 選手の全身の見た目の特徴（画像の特徴ベクトル）を求める
///
/// 同じチームの選手はユニフォームが同じでも、髪型・肌・靴・ソックス・体格などで見た目が少しずつ違う。
/// 画面外に出て戻った選手を同じ人に結ぶときに、位置のつながりと合わせて使う。
/// 顔は小さく写り後ろ向きのことも多いため使わない。
nonisolated enum AppearanceExtractor {
    /// 特徴を求める最小の選手の高さ（ピクセル）。これより小さいと見た目の違いが出ない
    static let minimumHeight: CGFloat = 32
    /// 何枚おきの保存画像を使うか（処理時間を抑えるため）
    static let keyFrameStride = 2

    /// [フレームの番号（frames の添字）: [検出の番号: 単位長さの特徴ベクトル]]
    typealias Features = [Int: [Int: [Float]]]

    /// 保存済みの画像（1 秒ごと）から、選手・GK の見た目の特徴を求める
    /// - Parameter imageURL: フレームの保存画像の場所
    static func features(frames: [SavedFrame], imageURL: (SavedFrame) -> URL?) -> Features {
        var result: Features = [:]
        let keyFrames = frames.indices.filter { frames[$0].imageFileName != nil }
        for (order, frameIndex) in keyFrames.enumerated() where order % keyFrameStride == 0 {
            let frame = frames[frameIndex]
            guard let url = imageURL(frame), let image = FrameImageIO.readImage(at: url) else { continue }
            let found = features(in: image, detections: frame.detections)
            if !found.isEmpty {
                result[frameIndex] = found
            }
        }
        return result
    }

    /// 1 枚の画像に写る選手・GK の見た目の特徴
    static func features(in image: CGImage, detections: [SavedDetection]) -> [Int: [Float]] {
        let imageHeight = CGFloat(image.height)
        var requests: [(index: Int, request: VNGenerateImageFeaturePrintRequest)] = []
        for (index, detection) in detections.enumerated() {
            guard !detection.isExcluded,
                  detection.label == SportsClass.player.rawValue || detection.label == SportsClass.goalkeeper.rawValue,
                  detection.boundingBox.height * imageHeight >= minimumHeight else { continue }
            let request = VNGenerateImageFeaturePrintRequest()
            request.imageCropAndScaleOption = .scaleFit
            // Vision の座標は左下原点
            let box = detection.boundingBox
            request.regionOfInterest = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            requests.append((index, request))
        }
        guard !requests.isEmpty else { return [:] }

        let handler = VNImageRequestHandler(cgImage: image)
        try? handler.perform(requests.map(\.request))

        var result: [Int: [Float]] = [:]
        for (index, request) in requests {
            guard let observation = request.results?.first,
                  observation.elementType == .float else { continue }
            let vector = observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            if let normalized = normalized(vector) {
                result[index] = normalized
            }
        }
        return result
    }

    /// 単位長さにする（長さが 0 なら nil）
    static func normalized(_ vector: [Float]) -> [Float]? {
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard length > 0 else { return nil }
        return vector.map { $0 / length }
    }

    /// 2 つの単位ベクトルの距離（0〜2。小さいほど似ている）
    static func distance(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var sum: Float = 0
        for index in a.indices {
            let d = a[index] - b[index]
            sum += d * d
        }
        return Double(sum.squareRoot())
    }
}
