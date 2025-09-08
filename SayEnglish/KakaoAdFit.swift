// AdFitVerboseBanner.swift
import SwiftUI
import AdFitSDK
import OSLog
import UIKit

// 외부로 전달할 이벤트 (UI에서 높이 접었다/폈다 등)
enum AdFitEvent {
    case begin(attempt: Int)
    case willLoad
    case success(elapsedMs: Int)
    case fail(error: Error, attempt: Int)
    case timeout(sec: Int, attempt: Int)
    case retryScheduled(afterSec: Int, nextAttempt: Int)
    case disposed
}

private let adfitLog = Logger(subsystem: "com.yourcompany.englishbell", category: "AdFitVerbose")

// MARK: - SwiftUI Wrapper (성공 전엔 높이 0으로 접힘)
// ✅ 래퍼: 명시적 init 추가 (호출부와 1:1 매칭)
struct AdFitVerboseBannerView: UIViewRepresentable {
    typealias UIViewType = AdFitVerboseHostView

    let clientId: String
    let adUnitSize: String
    let timeoutSec: Int
    let maxRetries: Int
    let onEvent: ((AdFitEvent) -> Void)?

    init(clientId: String,
         adUnitSize: String = "320x50",
         timeoutSec: Int = 8,
         maxRetries: Int = 2,
         onEvent: ((AdFitEvent) -> Void)? = nil) {
        self.clientId = clientId
        self.adUnitSize = adUnitSize
        self.timeoutSec = timeoutSec
        self.maxRetries = maxRetries
        self.onEvent = onEvent
    }

    func makeUIView(context: Context) -> AdFitVerboseHostView {
        let v = AdFitVerboseHostView(
            clientId: clientId,
            adUnitSize: adUnitSize,
            timeoutSec: timeoutSec,
            maxRetries: maxRetries
        )
        v.onEvent = onEvent   // ✅ 트레일링 클로저 연결
        return v
    }

    func updateUIView(_ uiView: AdFitVerboseHostView, context: Context) { }
}


// MARK: - Host UIView (모든 로그를 여기서 촘촘히)
final class AdFitVerboseHostView: UIView, AdFitBannerAdViewDelegate {
    // MARK: Configuration
    private let clientId: String
    private let adUnitSize: String
    private let timeoutSec: Int
    private let maxRetries: Int

    // MARK: State
    private var banner: AdFitBannerAdView?
    private var attempt: Int = 0
    private var didLoadOnce = false
    private var watchdog: DispatchWorkItem?
    private var loadStartAt: Date?
    private let logTag: String = String(UUID().uuidString.prefix(6)) // ← 기존 tag → logTag

    var onEvent: ((AdFitEvent) -> Void)?

    init(clientId: String, adUnitSize: String, timeoutSec: Int, maxRetries: Int) {
        self.clientId = clientId
        self.adUnitSize = adUnitSize
        self.timeoutSec = timeoutSec
        self.maxRetries = maxRetries
        super.init(frame: .zero)
        log("INIT")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        log("DEINIT")
        onEvent?(.disposed)
    }

    // MARK: Lifecycle Logs
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        log("willMove(toWindow: \(newWindow != nil ? "non-nil" : "nil"))")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        log("didMoveToWindow (window: \(window != nil ? "non-nil" : "nil"))")

        // window에 올라온 시점 1회만 로드
        guard window != nil, !didLoadOnce else {
            if didLoadOnce { log("SKIP load: already loaded once") }
            return
        }
        startLoadOrRetry()
        didLoadOnce = true
    }

    private func startLoadOrRetry() {
        guard let rootVC = findViewController() else {
            log("rootVC = nil → 1프레임 뒤 재시도")
            DispatchQueue.main.async { [weak self] in self?.startLoadOrRetry() }
            return
        }

        attempt += 1
        let parts = adUnitSize.split(separator: "x").compactMap { Double($0) }
        let width = CGFloat(parts.count == 2 ? parts[0] : 320)
        let height = CGFloat(parts.count == 2 ? parts[1] : 50)

        // 기존 배너 정리
        banner?.removeFromSuperview()
        banner = nil

        // 배너 생성
        let ad = AdFitBannerAdView(clientId: clientId, adUnitSize: adUnitSize)
        ad.rootViewController = rootVC
        ad.delegate = self
        ad.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ad)

        // 처음엔 "접힌 상태": 높이 제약은 성공 시점에 켭니다.
        NSLayoutConstraint.activate([
            ad.centerXAnchor.constraint(equalTo: centerXAnchor),
            ad.topAnchor.constraint(equalTo: topAnchor),
            bottomAnchor.constraint(equalTo: ad.bottomAnchor)
        ])

        onEvent?(.begin(attempt: attempt))
        log("BEGIN attempt=\(attempt) clientId=\(clientId) size=\(adUnitSize) rootVC=\(String(describing: rootVC))")

        // 타임아웃 워치독
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.log("⏰ TIMEOUT \(self.timeoutSec)s (attempt \(self.attempt))")
            self.onEvent?(.timeout(sec: self.timeoutSec, attempt: self.attempt))
            self.maybeRetry()
        }
        watchdog?.cancel()
        watchdog = task
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeoutSec), execute: task)

        // 로드 호출
        loadStartAt = Date()
        adfitLog.info("[AdFit][#\(self.logTag)] loadAd()")
        print("🟢 [AdFit][#\(self.logTag)][BEGIN] loadAd start - attempt=\(attempt) clientId=\(clientId) size=\(adUnitSize)")
        if let d = ad.delegate as AnyObject? {
            print("[AdFit][#\(logTag)] delegate attached: \(type(of: d))")
        } else {
            print("[AdFit][#\(logTag)] delegate is NIL ❌")
        }
            ad.loadAd()

        banner = ad
    }

    private func maybeRetry() {
        guard attempt <= maxRetries else {
            log("RETRY limit reached (max=\(maxRetries)) → stop")
            return
        }
        let backoff = min(2 * attempt, 6)  // 2, 4, 6초…
        log("RETRY scheduled after \(backoff)s (nextAttempt \(attempt + 1))")
        onEvent?(.retryScheduled(afterSec: backoff, nextAttempt: attempt + 1))
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(backoff)) { [weak self] in
            self?.startLoadOrRetry()
        }
    }

    // MARK: - Delegate (광고 이벤트 상세 로그)
    func adViewWillLoad(_ adView: AdFitBannerAdView) {
        log("📡 WILL_LOAD")
        onEvent?(.willLoad)
    }

    func adViewDidReceiveAd(_ adView: AdFitBannerAdView) {
        watchdog?.cancel()
        let elapsed = Int((Date().timeIntervalSince(loadStartAt ?? Date())) * 1000)
        log("✅ SUCCESS elapsed=\(elapsed)ms")
        onEvent?(.success(elapsedMs: elapsed))

        // 성공 시 높이 확정
        if let h = Double(adUnitSize.split(separator: "x").last ?? "50") {
            adView.heightAnchor.constraint(equalToConstant: CGFloat(h)).isActive = true
        }
        if let w = Double(adUnitSize.split(separator: "x").first ?? "320") {
            adView.widthAnchor.constraint(equalToConstant: CGFloat(w)).isActive = true
        }
    }

    func adView(_ adView: AdFitBannerAdView, didFailToReceiveAdWithError error: Error) {
        watchdog?.cancel()
        log("❌ FAIL \(error.localizedDescription) (attempt \(attempt))")
        onEvent?(.fail(error: error, attempt: attempt))
        maybeRetry()
    }

    // (SDK가 지원하면) 노출/클릭도 찍기
    func adViewWillExpose(_ adView: AdFitBannerAdView) {
        log("👀 IMPRESSION willExpose")
    }
    func adViewDidClick(_ adView: AdFitBannerAdView) {
        log("🖱️ CLICK")
    }
    

    // MARK: Helpers
    private func findViewController() -> UIViewController? {
        sequence(first: self.next, next: { $0?.next }).first { $0 is UIViewController } as? UIViewController
    }

    private func log(_ msg: String) {
        adfitLog.info("[AdFit][#\(self.logTag)] \(msg)")
        print("[AdFit][#\(self.logTag)] \(msg)")
    }
}
