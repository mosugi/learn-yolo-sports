//
//  ContinuedProcessingSession.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import BackgroundTasks
import Foundation

/// ユーザーが開始した解析を、アプリがバックグラウンドに移っても継続させるためのセッション
///
/// iOS 26 の BGContinuedProcessingTask を使う。解析処理そのものは呼び出し側の Task で動いており、
/// このクラスはシステムへの実行継続の要求と進捗報告だけを担当する。
/// 申請が通らない環境（シミュレーター等）でも、フォアグラウンドでは解析はそのまま進む。
@MainActor
final class ContinuedProcessingSession {

    /// Info.plist の BGTaskSchedulerPermittedIdentifiers に登録したワイルドカードと一致させる
    private static let identifierPrefix = (Bundle.main.bundleIdentifier ?? "com.mosugi.learn-yolo-sports") + ".analysis."

    private let identifier = identifierPrefix + UUID().uuidString
    private var task: BGContinuedProcessingTask?
    private var title = ""
    private var latestProgress: Double = 0
    private var finishedSuccess: Bool?
    private let onExpire: () -> Void

    /// - Parameter onExpire: システムまたはユーザーがバックグラウンド処理を打ち切ったときに呼ばれる
    init(onExpire: @escaping () -> Void) {
        self.onExpire = onExpire
    }

    /// システムにバックグラウンド継続を申請する
    func begin(title: String, subtitle: String) {
        self.title = title
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: .main
        ) { [weak self] task in
            // using: .main を指定しているのでメインスレッドで呼ばれる
            MainActor.assumeIsolated {
                guard let self, let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.attach(task)
            }
        }

        guard registered else {
            print("⚠️ BGTask の登録に失敗しました: \(identifier)")
            return
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: title,
            subtitle: subtitle
        )
        // すぐに実行できない場合はキューに積まず失敗させる（解析自体はフォアグラウンドで進む）
        request.strategy = .fail

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("⚠️ バックグラウンド継続を申請できませんでした: \(error)")
        }
    }

    /// 進捗を報告する
    /// - Parameters:
    ///   - fraction: 0.0〜1.0
    ///   - subtitle: システム UI に表示する補足
    func update(fraction: Double, subtitle: String) {
        latestProgress = fraction
        guard let task else { return }
        task.progress.completedUnitCount = Int64(fraction * Double(task.progress.totalUnitCount))
        task.updateTitle(title, subtitle: subtitle)
    }

    /// 解析終了を報告する
    func finish(success: Bool) {
        finishedSuccess = success
        if let task {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: success)
            self.task = nil
        } else {
            // まだ起動していない申請は取り消す
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
    }

    private func attach(_ task: BGContinuedProcessingTask) {
        // 起動前に解析が終わっていた場合はすぐに完了させる
        if let finishedSuccess {
            task.setTaskCompleted(success: finishedSuccess)
            return
        }

        self.task = task
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = Int64(latestProgress * 1000)
        task.expirationHandler = { [weak self] in
            // 解析をキャンセルし、その終了処理の finish(success: false) で完了を報告する
            Task { @MainActor in
                self?.onExpire()
            }
        }
    }
}
