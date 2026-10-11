//
//  TrackReview.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/11.
//

import Foundation
import SwiftUI

/// ユーザーが目で確かめた、ある追跡 ID のあるフレームでの結果
nonisolated enum TrackReviewMark: String, Codable, CaseIterable, Hashable {
    /// 枠あり: 同じ選手で、チームも正しい
    case correct
    /// 枠あり: 同じ選手だが、チームの判定が違う
    case wrongTeam
    /// 枠あり: 別の人に乗り移っている
    case switched
    /// 枠なし: 画面外・隠れていて見えない（追跡が切れて正しい）
    case hidden
    /// 枠なし: 見えているのに追跡できていない
    case lost

    /// 追跡の枠があるフレームで選べる評価
    static let withBox: [TrackReviewMark] = [.correct, .wrongTeam, .switched]
    /// 追跡の枠がないフレームで選べる評価
    static let withoutBox: [TrackReviewMark] = [.hidden, .lost]

    var displayName: String {
        switch self {
        case .correct: return "正しい"
        case .wrongTeam: return "チーム違い"
        case .switched: return "別の人"
        case .hidden: return "見えない"
        case .lost: return "見失い"
        }
    }

    var systemImage: String {
        switch self {
        case .correct: return "checkmark.circle.fill"
        case .wrongTeam: return "tshirt.fill"
        case .switched: return "arrow.triangle.swap"
        case .hidden: return "eye.slash"
        case .lost: return "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .correct, .hidden: return .green
        case .wrongTeam: return .orange
        case .switched, .lost: return .red
        }
    }
}

/// 追跡の評価の集計
nonisolated struct TrackEvaluation: Hashable {
    var correct = 0
    var wrongTeam = 0
    var switched = 0
    var hidden = 0
    var lost = 0

    init<S: Sequence>(marks: S) where S.Element == TrackReviewMark {
        for mark in marks {
            switch mark {
            case .correct: correct += 1
            case .wrongTeam: wrongTeam += 1
            case .switched: switched += 1
            case .hidden: hidden += 1
            case .lost: lost += 1
            }
        }
    }

    /// 評価したフレーム数
    var reviewedCount: Int {
        correct + wrongTeam + switched + hidden + lost
    }

    /// 同じ選手を追えているべきフレームのうち、追えていた割合（チームの正誤は問わない）
    var trackingAccuracy: Double? {
        let total = correct + wrongTeam + switched + lost
        guard total > 0 else { return nil }
        return Double(correct + wrongTeam) / Double(total)
    }

    /// 同じ選手を追えていたフレームのうち、チームの判定が正しかった割合
    var teamAccuracy: Double? {
        let total = correct + wrongTeam
        guard total > 0 else { return nil }
        return Double(correct) / Double(total)
    }

    static func percent(_ value: Double?) -> String {
        value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }
}

extension SavedAnalysis {
    /// 評価済みの追跡 ID（評価の多い順）
    nonisolated var reviewedTrackIDs: [Int] {
        (trackReviews ?? [:])
            .filter { !$0.value.isEmpty }
            .sorted { $0.value.count > $1.value.count }
            .map(\.key)
    }

    /// 指定した追跡の評価の集計
    nonisolated func evaluation(of trackID: Int) -> TrackEvaluation {
        TrackEvaluation(marks: (trackReviews?[trackID] ?? [:]).values)
    }

    /// すべての追跡の評価の集計
    nonisolated var overallEvaluation: TrackEvaluation {
        TrackEvaluation(marks: (trackReviews ?? [:]).values.flatMap(\.values))
    }

    /// 指定した追跡 ID が写っているフレーム番号（画像のあるフレームのみ）
    nonisolated func frameNumbers(of trackID: Int) -> [Int] {
        framesWithImages
            .filter { frame in frame.detections.contains { $0.trackID == trackID } }
            .map(\.frameNumber)
    }
}
