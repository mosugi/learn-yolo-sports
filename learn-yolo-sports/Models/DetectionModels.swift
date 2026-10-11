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

extension TeamSide {
    /// 表示色（ユニフォームの色に関係なく固定）
    var color: Color {
        switch self {
        case .own: return .cyan
        case .opponent: return .orange
        }
    }
}

extension SavedDetection {
    /// 表示色（チームが分かればチームの色、コート外は灰色）
    var displayColor: Color {
        if isExcluded { return .gray }
        if let team { return team.color }
        return SportsClass(rawValue: label)?.color ?? .gray
    }
    
    /// 表示名（例: 自チーム GK、相手 選手）
    var displayName: String {
        let className = SportsClass(rawValue: label)?.japaneseName ?? label
        if isExcluded { return "\(className)（コート外）" }
        guard let team else { return className }
        return label == SportsClass.goalkeeper.rawValue ? "\(team.displayName) GK" : "\(team.displayName) \(className)"
    }
    
    var confidencePercentage: Int {
        Int(confidence * 100)
    }

    /// 背番号（分かれば）または追跡 ID を含む表示名（例: 自チーム 選手 #10）
    func label(trackNumbers: [Int: Int]) -> String {
        guard let trackID, !isExcluded else { return displayName }
        if let number = trackNumbers[trackID] {
            return "\(displayName) #\(number)"
        }
        return "\(displayName) ID\(trackID)"
    }
}

/// 画像を縦横比を保って枠に収めたときの表示位置
nonisolated enum ImageFit {
    static func rect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}
