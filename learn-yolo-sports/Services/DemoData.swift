//
//  DemoData.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/09.
//

import Foundation
import CoreGraphics
import SwiftUI

/// App Store 用スクリーンショットのためのデモデータ
///
/// 試合映像は権利の都合で同梱できないため、ピッチと選手を描いた画像と検出結果を生成する。
/// 毎回同じ画像になるよう、乱数は固定シードで生成する。
nonisolated enum DemoData {
    
    static let videoName = "demo_match.mp4"
    /// デモの解析結果の ID（保存先のディレクトリ名にもなる）
    static let id = UUID(uuidString: "D3A0D3A0-0000-4000-8000-000000000001")!
    
    private static let size = CGSize(width: 1280, height: 720)
    private static let frameCount = 12
    private static let framesPerSecond = 2
    
    /// デモの解析結果を作り、フレーム画像を directory に書き出す
    static func make(directory: URL) -> SavedAnalysis {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var random = SeededRandom(seed: 20261009)
        
        // 各選手の基準位置（正規化座標）。左が青チーム、右が白チーム
        let blueBase: [CGPoint] = [CGPoint(x: 0.22, y: 0.30), CGPoint(x: 0.20, y: 0.68), CGPoint(x: 0.33, y: 0.48), CGPoint(x: 0.42, y: 0.26), CGPoint(x: 0.45, y: 0.70), CGPoint(x: 0.55, y: 0.42), CGPoint(x: 0.60, y: 0.60)]
        let whiteBase: [CGPoint] = [CGPoint(x: 0.50, y: 0.33), CGPoint(x: 0.52, y: 0.55), CGPoint(x: 0.63, y: 0.30), CGPoint(x: 0.66, y: 0.72), CGPoint(x: 0.74, y: 0.46), CGPoint(x: 0.80, y: 0.30), CGPoint(x: 0.78, y: 0.64)]
        
        var frames: [SavedFrame] = []
        for index in 0..<frameCount {
            let t = Double(index) / Double(frameCount - 1)
            // ボールは中盤から右サイドへ運ばれる
            let ball = CGPoint(x: 0.46 + 0.28 * t, y: 0.50 - 0.16 * sin(t * .pi))
            
            func shifted(_ base: CGPoint, pull: CGFloat) -> CGPoint {
                CGPoint(
                    x: base.x + (ball.x - 0.5) * pull + CGFloat(random.next(in: -0.008...0.008)),
                    y: base.y + (ball.y - 0.5) * pull * 0.6 + CGFloat(random.next(in: -0.008...0.008))
                )
            }
            
            var figures: [Figure] = []
            figures += blueBase.map { Figure(kind: .bluePlayer, center: shifted($0, pull: 0.5)) }
            figures += whiteBase.map { Figure(kind: .whitePlayer, center: shifted($0, pull: 0.4)) }
            figures.append(Figure(kind: .goalkeeper, center: CGPoint(x: 0.92, y: 0.50 + (ball.y - 0.5) * 0.3)))
            figures.append(Figure(kind: .referee, center: CGPoint(x: ball.x - 0.08, y: 0.62)))
            figures.append(Figure(kind: .ball, center: ball))
            
            var imageFileName: String?
            if let image = render(figures) {
                let fileName = AnalysisStore.imageFileName(for: index)
                if (try? FrameImageIO.writeJPEG(image, to: directory.appending(path: fileName))) != nil {
                    imageFileName = fileName
                }
            }
            // 図形の並びは毎フレーム同じなので、並び順を追跡 ID として使う
            let detections = figures.enumerated().map { trackID, figure in
                let box = figure.boundingBox(in: size)
                return SavedDetection(
                    label: figure.kind.label,
                    confidence: Float(random.next(in: 0.72...0.96)),
                    boundingBox: CGRect(
                        x: box.minX / size.width,
                        y: box.minY / size.height,
                        width: box.width / size.width,
                        height: box.height / size.height
                    ),
                    team: figure.kind.team,
                    trackID: figure.kind == .ball ? nil : trackID
                )
            }
            
            frames.append(SavedFrame(
                frameNumber: index,
                timestamp: Double(index) / Double(framesPerSecond),
                imageFileName: imageFileName,
                detections: detections
            ))
        }
        
        var record = SavedAnalysis(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_791_500_000),
            videoName: videoName,
            framesPerSecond: framesPerSecond,
            imageWidth: Int(size.width),
            imageHeight: Int(size.height),
            processingDuration: 6.8,
            usedRealModel: true,
            frames: frames
        )
        record.advice = AnalysisAdvice(
            summary: "ボールは中盤から右サイドへ運ばれており、攻撃側が相手陣内へ押し込んでいる時間帯と読み取れます。ボール周辺には両チームの選手が集まり、局所的な密集が生じています。",
            observations: [
                "ボール位置は画面右側が半数を超え、右サイドからの攻撃が中心です",
                "ボール周辺の選手数が多く、ボール保持者への寄せが早い傾向があります",
                "選手の左右の散らばりは小さく、全体がコンパクトに保たれています",
            ],
            suggestions: [
                "逆サイドの選手が幅を取り、密集を避けるサイドチェンジを狙いましょう",
                "密集時は3人目の動きでパスコースを作ると前進しやすくなります",
                "守備側はボールサイドへ寄せつつ、逆サイドのスペースにも注意しましょう",
            ],
            generatedAt: record.createdAt
        )
        
        return record
    }
    
    // MARK: - Drawing
    
    private struct Figure {
        enum Kind {
            case bluePlayer, whitePlayer, goalkeeper, referee, ball
            
            var label: String {
                switch self {
                case .bluePlayer, .whitePlayer: return SportsClass.player.rawValue
                case .goalkeeper: return SportsClass.goalkeeper.rawValue
                case .referee: return SportsClass.referee.rawValue
                case .ball: return SportsClass.ball.rawValue
                }
            }
            
            var team: TeamSide? {
                switch self {
                case .bluePlayer: return .own
                case .whitePlayer, .goalkeeper: return .opponent
                case .referee, .ball: return nil
                }
            }
        }
        
        let kind: Kind
        /// 正規化座標
        let center: CGPoint
        
        func boundingBox(in size: CGSize) -> CGRect {
            let x = center.x * size.width
            let y = center.y * size.height
            if kind == .ball {
                return CGRect(x: x - 9, y: y - 9, width: 18, height: 18)
            }
            return CGRect(x: x - 16, y: y - 36, width: 32, height: 72)
        }
    }
    
    private static func render(_ figures: [Figure]) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        
        // 左上原点で描く
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        
        // 芝生（縞模様）
        let stripe = size.width / 10
        for i in 0..<10 {
            context.setFillColor(i.isMultiple(of: 2) ? rgb(0.20, 0.52, 0.24) : rgb(0.23, 0.57, 0.27))
            context.fill(CGRect(x: CGFloat(i) * stripe, y: 0, width: stripe, height: size.height))
        }
        
        // ライン
        context.setStrokeColor(rgb(0.95, 0.97, 0.95))
        context.setLineWidth(4)
        let field = CGRect(x: 40, y: 40, width: size.width - 80, height: size.height - 80)
        context.stroke(field)
        context.strokeLineSegments(between: [CGPoint(x: size.width / 2, y: 40), CGPoint(x: size.width / 2, y: size.height - 40)])
        context.strokeEllipse(in: CGRect(x: size.width / 2 - 90, y: size.height / 2 - 90, width: 180, height: 180))
        context.stroke(CGRect(x: 40, y: 200, width: 170, height: 320))
        context.stroke(CGRect(x: size.width - 210, y: 200, width: 170, height: 320))
        context.stroke(CGRect(x: 40, y: 290, width: 60, height: 140))
        context.stroke(CGRect(x: size.width - 100, y: 290, width: 60, height: 140))
        
        for figure in figures {
            let box = figure.boundingBox(in: size)
            switch figure.kind {
            case .ball:
                context.setFillColor(rgb(1, 1, 1))
                context.fillEllipse(in: box.insetBy(dx: 2, dy: 2))
                context.setFillColor(rgb(0.1, 0.1, 0.1))
                context.fillEllipse(in: box.insetBy(dx: 6, dy: 6))
            default:
                let shirt: CGColor
                switch figure.kind {
                case .bluePlayer: shirt = rgb(0.15, 0.35, 0.85)
                case .whitePlayer: shirt = rgb(0.96, 0.96, 0.96)
                case .goalkeeper: shirt = rgb(0.95, 0.55, 0.10)
                default: shirt = rgb(0.10, 0.10, 0.10)
                }
                // 脚
                context.setStrokeColor(rgb(0.85, 0.70, 0.55))
                context.setLineWidth(5)
                context.strokeLineSegments(between: [
                    CGPoint(x: box.midX - 6, y: box.minY + 48), CGPoint(x: box.midX - 8, y: box.maxY),
                    CGPoint(x: box.midX + 6, y: box.minY + 48), CGPoint(x: box.midX + 8, y: box.maxY),
                ])
                // 胴体
                context.setFillColor(shirt)
                context.fill(CGRect(x: box.minX + 4, y: box.minY + 16, width: box.width - 8, height: 26))
                // パンツ
                context.setFillColor(figure.kind == .whitePlayer ? rgb(0.75, 0.15, 0.15) : rgb(0.12, 0.12, 0.18))
                context.fill(CGRect(x: box.minX + 6, y: box.minY + 40, width: box.width - 12, height: 12))
                // 頭
                context.setFillColor(rgb(0.85, 0.70, 0.55))
                context.fillEllipse(in: CGRect(x: box.midX - 8, y: box.minY, width: 16, height: 16))
            }
        }
        
        return context.makeImage()
    }
    
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

/// 固定シードの擬似乱数（スクリーンショットを毎回同じにするため）
nonisolated private struct SeededRandom {
    private var state: UInt64
    
    init(seed: UInt64) {
        state = seed
    }
    
    mutating func next(in range: ClosedRange<Double>) -> Double {
        // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        let unit = Double(z >> 11) / Double(1 << 53)
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }
}
