//
//  SayEnglish.swift
//  SayEnglish
//
//  Created by 김동준 on 8/27/25.
//

import SwiftUI
import UserNotifications
import AVFoundation

// MARK: - App
@main
struct SayEnglishApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { WindowGroup { ContentView() } }
}

// MARK: - AppDelegate (포그라운드에서도 알림 표시 + 탭 시 TTS)
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private let tts = AVSpeechSynthesizer()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions opts: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.speak("Great! Let's practice two quick phrases.")
        }
        completionHandler()
    }

    private func speak(_ text: String) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        u.volume = 1.0
        tts.speak(u)
    }
}

// MARK: - Model
enum AlarmKind: Equatable {
    case daily(time: Date)                                  // 매일 특정 시각
    case weekly(time: Date, weekdays: Set<Int>)             // 요일별(일=1 ... 토=7)
    case interval(minutes: Int)                             // N분마다
}

struct CustomAlarm: Identifiable, Equatable {
    let id: UUID
    var kind: AlarmKind
    var enabled: Bool

    init(id: UUID = UUID(), kind: AlarmKind, enabled: Bool = true) {
        self.id = id; self.kind = kind; self.enabled = enabled
    }

    var label: String {
        switch kind {
        case .daily(let t):
            return "매일 \(Self.hmString(t))"
        case .weekly(let t, let wds):
            let names = ["일","월","화","수","목","금","토"]
            let list = wds.sorted().map { names[$0-1] }.joined(separator: "·")
            return "매주 \(list) \(Self.hmString(t))"
        case .interval(let m):
            return "매 \(m)분"
        }
    }

    static func hmString(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = .init(identifier: "ko_KR"); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

// MARK: - NotiManager
@MainActor
final class NotiManager: ObservableObject {
    enum RepeatMode: String, CaseIterable, Identifiable { case daily = "매일", weekly = "요일별"; var id: String { rawValue } }

    // 상단 입력값
    @Published var repeatMode: RepeatMode = .daily
    @Published var fixedTime: Date = Calendar.current.date(bySettingHour: 20, minute: 30, second: 0, of: Date())!
    @Published var weekdaySelections: Set<Int> = [2,3,4,5,6] // 월~금

    // 주기 입력값
    @Published var intervalMinutes: Int = 30

    // 사용자 알람 목록 (최대 5개)
    @Published var alarms: [CustomAlarm] = []

    // 사운드 풀(랜덤)
    private let soundFiles = ["eng_prompt_01.wav","eng_prompt_02.wav","eng_prompt_03.wav","eng_prompt_04.wav","eng_prompt_05.wav"]

    // 권한
    private func ensureAuth() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .authorized { return true }
        do {
            let ok = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            return ok
        } catch { return false }
    }

    // MARK: - 저장 버튼 동작
    func saveFixedAsAlarm() async {
        guard alarms.count < 5 else { return }
        switch repeatMode {
        case .daily:
            let a = CustomAlarm(kind: .daily(time: fixedTime))
            alarms.append(a)
            await schedule(a)
        case .weekly:
            guard !weekdaySelections.isEmpty else { return }
            let a = CustomAlarm(kind: .weekly(time: fixedTime, weekdays: weekdaySelections))
            alarms.append(a)
            await schedule(a)
        }
    }

    func saveIntervalAsAlarm() async {
        guard alarms.count < 5 else { return }
        let mins = max(1, intervalMinutes)
        let a = CustomAlarm(kind: .interval(minutes: mins))
        alarms.append(a)
        await schedule(a)
    }

    // MARK: - 목록 토글 & 삭제
    func toggle(_ alarm: CustomAlarm, isOn: Bool) async {
        if let idx = alarms.firstIndex(of: alarm) {
            alarms[idx].enabled = isOn
        }
        if isOn { await schedule(alarm) } else { await cancel(alarm) }
    }

    func delete(_ alarm: CustomAlarm) async {
        await cancel(alarm)
        alarms.removeAll { $0.id == alarm.id }
    }

    // MARK: - 스케줄/취소
    private func schedule(_ alarm: CustomAlarm) async {
        guard await ensureAuth(), alarm.enabled else { return }
        switch alarm.kind {
        case .daily(let t):
            let comps = Calendar.current.dateComponents([.hour, .minute], from: t)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
            try? await addRequest(idPrefix: "alarm-\(alarm.id)-daily", trigger: trigger)

        case .weekly(let t, let wds):
            let hm = Calendar.current.dateComponents([.hour, .minute], from: t)
            for wd in wds {
                var dc = DateComponents(); dc.weekday = wd; dc.hour = hm.hour; dc.minute = hm.minute
                let trigger = UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)
                try? await addRequest(idPrefix: "alarm-\(alarm.id)-weekly-\(wd)", trigger: trigger)
            }

        case .interval(let minutes):
            let secs = max(60, minutes * 60)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(secs), repeats: true)
            try? await addRequest(idPrefix: "alarm-\(alarm.id)-interval", trigger: trigger)
        }
    }

    private func cancel(_ alarm: CustomAlarm) async {
        let center = UNUserNotificationCenter.current()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            center.getPendingNotificationRequests { reqs in
                let ids = reqs.map(\.identifier).filter { $0.hasPrefix("alarm-\(alarm.id)") }
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
                cont.resume()
            }
        }
    }

    private func addRequest(idPrefix: String, trigger: UNNotificationTrigger) async throws {
        let content = UNMutableNotificationContent()
        content.title = "Let’s practice English 🇺🇸"
        content.body  = "Tap to continue the conversation"
        if let name = soundFiles.randomElement() {
            content.sound = UNNotificationSound(named: .init(name))
        } else {
            content.sound = .default
        }
        let id = idPrefix // 고유 식별자
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}

// MARK: - UI
struct ContentView: View {
    @StateObject private var vm = NotiManager()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {

                // 상단: 반복 스케줄 (저장 버튼으로 목록에 추가)
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("반복 스케줄").font(.headline)
                        Picker("", selection: $vm.repeatMode) {
                            Text("매일").tag(NotiManager.RepeatMode.daily)
                            Text("요일별").tag(NotiManager.RepeatMode.weekly)
                        }
                        .pickerStyle(.segmented)

                        DatePicker("시간", selection: $vm.fixedTime, displayedComponents: .hourAndMinute)

                        if vm.repeatMode == .weekly {
                            WeekdayChips(selection: $vm.weekdaySelections)
                        }

                        Button {
                            Task { await vm.saveFixedAsAlarm() }
                        } label: {
                            Label("저장", systemImage: "square.and.arrow.down.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.alarms.count >= 5 || (vm.repeatMode == .weekly && vm.weekdaySelections.isEmpty))
                    }
                }

                // 중간: 주기 알림 (저장 버튼으로 목록에 추가)
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("주기 알림").font(.headline)
                        Stepper(value: $vm.intervalMinutes, in: 1...360, step: 1) {
                            Text("주기: \(vm.intervalMinutes)분")
                        }
                        Button {
                            Task { await vm.saveIntervalAsAlarm() }
                        } label: {
                            Label("저장", systemImage: "square.and.arrow.down.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.alarms.count >= 5)
                    }
                }

                // TTS 버튼 (주기 알림 바로 아래)
                Card {
                    Button {
                        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
                        try? AVAudioSession.sharedInstance().setActive(true)
                        let tts = AVSpeechSynthesizer()
                        let u = AVSpeechUtterance(string: "Hey! Want to practice three useful phrases today?")
                        u.voice = AVSpeechSynthesisVoice(language: "en-US")
                        tts.speak(u)
                    } label: {
                        HStack {
                            Image(systemName: "waveform.circle.fill")
                            Text("TTS로 말걸기")
                        }
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                }

                // 사용자 알람 목록 (맨 아래, 최대 5개)
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("사용자 알람 (최대 5개)").font(.headline)
                            Spacer()
                            Text("\(vm.alarms.count)/5").foregroundColor(.secondary)
                        }

                        if vm.alarms.isEmpty {
                            Text("위에서 저장을 눌러 알람을 추가하세요.")
                                .foregroundColor(.secondary)
                        } else {
                            VStack(spacing: 10) {
                                ForEach(vm.alarms) { alarm in
                                    AlarmRow(
                                        alarm: alarm,
                                        onToggle: { isOn in Task { await vm.toggle(alarm, isOn: isOn) } },
                                        onDelete: { Task { await vm.delete(alarm) } }
                                    )
                                }
                            }
                        }
                    }
                }

            }
            .padding(16)
        }
        .background(LinearGradient(colors: [Color(.systemGray6), .white], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .navigationTitle("English Poke")
    }
}

// MARK: - Subviews
struct Card<Content: View>: View {
    let content: () -> Content
    init(@ViewBuilder _ content: @escaping () -> Content) { self.content = content }
    var body: some View {
        VStack { content() }
            .padding(16)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 6)
    }
}

struct WeekdayChips: View {
    @Binding var selection: Set<Int>
    private let labels = ["일","월","화","수","목","금","토"] // 1~7
    var body: some View {
        HStack(spacing: 8) {
            ForEach(1...7, id: \.self) { wd in
                let isOn = selection.contains(wd)
                Text(labels[wd - 1])
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(isOn ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.12))
                    .foregroundColor(isOn ? .accentColor : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onTapGesture {
                        if isOn { selection.remove(wd) } else { selection.insert(wd) }
                    }
            }
        }
    }
}

struct AlarmRow: View {
    let alarm: CustomAlarm
    var onToggle: (Bool) -> Void
    var onDelete: () -> Void

    @State private var isOn: Bool

    init(alarm: CustomAlarm, onToggle: @escaping (Bool) -> Void, onDelete: @escaping () -> Void) {
        self.alarm = alarm
        self.onToggle = onToggle
        self.onDelete = onDelete
        _isOn = State(initialValue: alarm.enabled)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isOn ? "bell.fill" : "bell.slash")
                .foregroundColor(isOn ? .accentColor : .secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(alarm.label).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.footnote).foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .onChange(of: isOn) { on in onToggle(on) }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash.fill")
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var subtitle: String {
        switch alarm.kind {
        case .daily(let t):
            return "반복 · 매일 \(CustomAlarm.hmString(t))"
        case .weekly(_, let wds):
            let names = ["일","월","화","수","목","금","토"]
            return "반복 · \(wds.sorted().map { names[$0-1] }.joined(separator: "·"))"
        case .interval(let m):
            return "반복 · \(m)분 간격"
        }
    }
}
