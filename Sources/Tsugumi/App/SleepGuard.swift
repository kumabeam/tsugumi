import Foundation
import IOKit.pwr_mgt
import os

/// 録音中と文字起こし中に、Mac が放置でスリープしないようにする。蓋を閉じたときのスリープは止めない。
///
/// 宣言には期限を付け、動いている間は取り直し続ける。状態の見落としで放し忘れても
/// 期限が来れば macOS 側で消えるので、「ずっと寝なくなる」事故にならない。
/// アプリが終了したときは期限を待たずに消える。
@MainActor
final class SleepGuard {
    /// 一度の宣言が生きる長さ
    static let lifetime: TimeInterval = 10 * 60
    /// 取り直す間隔。期限より十分短くして、取り直しが遅れても切れ目ができないようにする
    static let renewal: TimeInterval = 5 * 60

    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?
    private var reason = ""
    private let log = Logger(subsystem: "io.github.kumabeam.tsugumi", category: "sleep")

    var isActive: Bool { timer != nil }

    /// 状態から「止めるべきか」を毎回渡す。すでにその状態なら何もしない。
    /// reason は pmset -g assertions に出る名前になるので ASCII で渡す（それ以外は空欄で表示される）
    func set(active: Bool, reason: String) {
        if active {
            guard timer == nil else { return }
            self.reason = reason
            renew()
            // 解除の直後に取り直しが走って、止めたはずの宣言が残らないよう timer を見る
            let timer = Timer(timeInterval: Self.renewal, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.timer != nil else { return }
                    self.renew()
                }
            }
            timer.tolerance = 30
            // メニューを開いたままでも取り直しが止まらないように
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            log.notice("スリープ防止を開始: \(reason, privacy: .public)")
        } else {
            guard timer != nil else { return }
            timer?.invalidate()
            timer = nil
            release()
            log.notice("スリープ防止を解除")
        }
    }

    /// 期限付きの宣言を新しく取り、古いものを放す。取り直すたびに期限が延びる
    private func renew() {
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey as String: kIOPMAssertionTypePreventUserIdleSystemSleep as String,
            kIOPMAssertionNameKey as String: "Tsugumi \(reason)",
            kIOPMAssertionTimeoutKey as String: Self.lifetime,
            kIOPMAssertionTimeoutActionKey as String: kIOPMAssertionTimeoutActionRelease as String,
        ]
        var created: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithProperties(properties as CFDictionary, &created)
        guard status == kIOReturnSuccess else {
            log.error("スリープ防止の宣言に失敗: \(status)")
            return
        }
        release()
        assertion = created
    }

    private func release() {
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
    }
}
