//
//  DetectionModels.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import Foundation
import CoreGraphics
import SwiftUI

/// 検出されたオブジェクト
nonisolated struct Detection: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Float
    let boundingBox: CGRect
    let color: Color
    /// ユニフォームの色（player/goalkeeper のみ、解析パイプラインで後付けする）
    var uniformColor: RGBColor?
    /// チーム判定（0 or 1、player のみ）
    var team: Int?
    /// OCR で読み取れた背番号
    var jerseyNumber: Int?

    /// 信頼度を百分率で取得
    var confidencePercentage: Int {
        Int(confidence * 100)
    }
}

/// RGB カラー（Codable で保存するための色表現）
nonisolated struct RGBColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    /// 0〜1 に正規化された RGB の距離
    func distance(to other: RGBColor) -> Double {
        let dr = red - other.red
        let dg = green - other.green
        let db = blue - other.blue
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    /// CIE L*a*b*（D65 白色点）。人の見た目に近い色差でチームを分けるために使う
    var lab: (l: Double, a: Double, b: Double) {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = linear(red), g = linear(green), b = linear(blue)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883

        func f(_ t: Double) -> Double {
            t > 0.008856 ? pow(t, 1.0 / 3.0) : 7.787 * t + 16.0 / 116.0
        }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
}

/// RGB から日本語の色名を決める
nonisolated enum ColorNaming {
    private static let palette: [(name: String, color: RGBColor)] = [
        ("赤", RGBColor(red: 0.8, green: 0.1, blue: 0.1)),
        ("白", RGBColor(red: 0.95, green: 0.95, blue: 0.95)),
        ("青", RGBColor(red: 0.1, green: 0.2, blue: 0.8)),
        ("黄", RGBColor(red: 0.95, green: 0.9, blue: 0.1)),
        ("黒", RGBColor(red: 0.08, green: 0.08, blue: 0.08)),
        ("緑", RGBColor(red: 0.1, green: 0.6, blue: 0.2)),
        ("オレンジ", RGBColor(red: 0.95, green: 0.5, blue: 0.1)),
        ("水色", RGBColor(red: 0.3, green: 0.75, blue: 0.95)),
        ("紫", RGBColor(red: 0.5, green: 0.15, blue: 0.7)),
        ("ピンク", RGBColor(red: 0.95, green: 0.5, blue: 0.7)),
        ("灰", RGBColor(red: 0.55, green: 0.55, blue: 0.55)),
    ]

    /// 最も近い色名を返す
    static func japaneseName(for color: RGBColor) -> String {
        palette.min { color.distance(to: $0.color) < color.distance(to: $1.color) }?.name ?? "不明"
    }
}

/// サッカー検出モデルのクラスラベル（モデルの names と一致させる）
nonisolated enum SportsClass: String, CaseIterable {
    case ball = "ball"
    case player = "player"
    case referee = "referee"
    case goalkeeper = "goalkeeper"
    
    /// クラスごとの色
    var color: Color {
        switch self {
        case .ball: return .red
        case .player: return .blue
        case .referee: return .yellow
        case .goalkeeper: return .green
        }
    }
    
    /// 日本語名
    var japaneseName: String {
        switch self {
        case .ball: return "ボール"
        case .player: return "選手"
        case .referee: return "審判"
        case .goalkeeper: return "ゴールキーパー"
        }
    }
}
