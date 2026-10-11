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

    /// 明るい色か（上に重ねる文字を黒にする判定に使う）
    var isLight: Bool {
        0.299 * red + 0.587 * green + 0.114 * blue > 0.6
    }

    /// 0〜1 に正規化された RGB の距離
    func distance(to other: RGBColor) -> Double {
        let dr = red - other.red
        let dg = green - other.green
        let db = blue - other.blue
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}

/// RGB から日本語の色名を決める
nonisolated enum ColorNaming {
    /// 色相（L*a*b* の a*b* 平面の角度）と明るさから、ユニフォームの色の呼び名を決める
    ///
    /// RGB の近さで決めると、日陰で暗く写った赤が「ピンク」や「紫」になりやすいため、色相を優先する。
    static func japaneseName(for color: RGBColor) -> String {
        let lab = LabColor(red: color.red, green: color.green, blue: color.blue)
        if lab.chroma < 15 {
            if lab.l >= 70 { return "白" }
            if lab.l <= 30 { return "黒" }
            return "灰"
        }
        let hue = (atan2(lab.b, lab.a) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        switch hue {
        case ..<55: return lab.l >= 75 && lab.chroma < 40 ? "ピンク" : "赤"
        case ..<75: return "オレンジ"
        case ..<105: return "黄"
        case ..<190: return "緑"
        case ..<250: return "水色"
        case ..<308: return "青"
        case ..<340: return "紫"
        default: return lab.l >= 70 ? "ピンク" : "赤"
        }
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
