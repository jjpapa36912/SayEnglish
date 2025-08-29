//
//  ContentView.swift
//  EnglishChatApp
//
//  Created by YourName on 2024/08/29.
//

import SwiftUI
import AVFoundation
import Speech
import UserNotifications

// MARK: - 1. Data Models (서버와 통신할 데이터 구조)
// FastAPI 서버의 Pydantic 모델과 동일한 구조로 Codable을 채택합니다.
struct ChatMessage: Identifiable, Codable {
    let id = UUID()
    let role: String
    let text: String
}

// /chat/start 엔드포인트 응답
struct StartResponse: Codable {
    let assistant_text: String
}

// /chat/reply 엔드포인트 요청
struct ReplyRequest: Codable {
    let history: [ChatMessage]
    let user_text: String
}

// /chat/reply 엔드포인트 응답
struct ReplyResponse: Codable {
    let assistant_text: String
}

// 알람 데이터 모델
struct Alarm: Identifiable, Codable, Equatable {
    var id: String
    var type: AlarmType
    var time: Date
    var weekdays: Set<Int> // 1(일요일) ~ 7(토요일)
    var interval: Int? // 주기 (분 단위)
    var isActive: Bool
    
    // 알람의 사용자 친화적인 설명
    var description: String {
        switch type {
        case .daily:
            return "매일 \(formattedTime)"
        case .weekly:
            let days = weekdays.sorted().map {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "ko_KR")
                return formatter.weekdaySymbols[$0 - 1]
            }.joined(separator: ", ")
            return "\(days) \(formattedTime)"
        case .interval:
            return "\(interval!)분마다"
        }
    }
    
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: time)
    }
    
    // UNNotificationRequest 생성
    func createNotificationRequest() -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "영어 대화 알람"
        content.body = "영어 대화할 시간입니다!"
        
        // 알람 소리: 사용자가 준비한 파일(conceptually)
        // 실제 사용 시 'alarm_sound.wav' 파일을 프로젝트에 추가해야 합니다.
        // 5가지 파일 중 랜덤하게 선택하는 로직을 위해 파일명을 배열로 관리합니다.
        let alarmSounds = ["eng_prompt_01.wav", "eng_prompt_02.wav", "eng_prompt_03.wav", "eng_prompt_04.wav", "eng_prompt_05.wav"]
        if let randomSound = alarmSounds.randomElement() {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(randomSound))
        } else {
            content.sound = .default
        }
        
        var trigger: UNNotificationTrigger?
        
        switch type {
        case .daily, .weekly:
            var dateComponents = Calendar.current.dateComponents([.hour, .minute, .timeZone], from: time)
            dateComponents.timeZone = .current // Explicitly set the timezone
            
            if type == .weekly {
                // 선택된 요일에만 알람 설정
                let weekday = Calendar.current.component(.weekday, from: time)
                if !weekdays.contains(weekday) {
                    // 선택된 요일이 아니므로 트리거를 설정하지 않음
                    return UNNotificationRequest(identifier: self.id, content: content, trigger: nil)
                }
            }
            
            trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        case .interval:
            if let interval = self.interval, interval > 0 {
                trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(interval * 60), repeats: true)
            }
        }
        
        return UNNotificationRequest(identifier: self.id, content: content, trigger: trigger)
    }
}

enum AlarmType: String, CaseIterable, Codable {
    case daily = "매일"
    case weekly = "요일별"
    case interval = "시간 주기"
}

// MARK: - 2. Audio Controller
// 음성 입력 및 출력을 관리하는 클래스
class AudioController: NSObject, ObservableObject, SFSpeechRecognizerDelegate, AVSpeechSynthesizerDelegate, SFSpeechRecognitionTaskDelegate {
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    private let synthesizer = AVSpeechSynthesizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    private var silenceTimer: Timer?
    private let silenceTimeout: TimeInterval = 2.5
    
    weak var viewModel: ChatViewModel?

    @Published var isRecognizing = false
    @Published var recognizedText = ""
    @Published var isSpeaking = false
    
    override init() {
        super.init()
        speechRecognizer.delegate = self
        synthesizer.delegate = self
        requestAuthorization()
    }
    
    deinit {
        silenceTimer?.invalidate()
    }
    
    func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            OperationQueue.main.addOperation {
                switch authStatus {
                case .authorized:
                    print("Speech recognition authorized.")
                default:
                    print("Speech recognition not authorized.")
                }
            }
        }
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            if granted {
                print("Microphone access granted.")
            } else {
                print("Microphone access not granted.")
            }
        }
    }
    
    func startRecognition() throws {
        guard let viewModel = viewModel, viewModel.isChatActive else { return }

        if let recognitionTask = recognitionTask {
            recognitionTask.cancel()
            self.recognitionTask = nil
        }
        
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: .duckOthers)
        try audioSession.overrideOutputAudioPort(.speaker)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
        let inputNode = audioEngine.inputNode
        
        inputNode.removeTap(onBus: 0)
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { fatalError("Unable to create a SFSpeechAudioBufferRecognitionRequest object") }
        recognitionRequest.shouldReportPartialResults = true

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest, delegate: self)
        
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
            self.recognitionRequest?.append(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        isRecognizing = true
        
        resetSilenceTimer()
    }
    
    func forceStopRecognition() {
        audioEngine.stop()
        recognitionRequest?.endAudio()
        isRecognizing = false
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    // AVSpeechUtterance에 사용할 현실적인 목소리를 찾는 함수
    private func findPreferredVoice() -> AVSpeechSynthesisVoice? {
        // 프리미엄/향상된 품질의 미국 영어 목소리를 찾습니다.
        let allVoices = AVSpeechSynthesisVoice.speechVoices()
        if let premiumVoice = allVoices.first(where: {
            $0.language == "en-US" && $0.quality == .premium
        }) {
            return premiumVoice
        }
        
        if let enhancedVoice = allVoices.first(where: {
            $0.language == "en-US" && $0.quality == .enhanced
        }) {
            return enhancedVoice
        }
        
        // 프리미엄/향상된 목소리가 없으면 기본 목소리를 사용합니다.
        return AVSpeechSynthesisVoice(language: "en-US")
    }
    
    func speak(_ text: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        
        forceStopRecognition()
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = findPreferredVoice()
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }
    
    // MARK: - SFSpeechRecognitionTaskDelegate
    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didChange state: SFSpeechRecognitionTaskState) {
    }
    
    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didStartSpeechAt: Date) {
        resetSilenceTimer()
    }
    
    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSpeech: SFSpeechRecognitionResult) {
    }
    
    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didHypothesizeTranscription transcription: SFTranscription) {
        self.recognizedText = transcription.formattedString
        resetSilenceTimer()
    }
    
    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
    }
    
    // MARK: - AVSpeechSynthesizerDelegate
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        self.isSpeaking = true
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        self.isSpeaking = false
        try? startRecognition()
    }
    
    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
            if let recognizedText = self?.recognizedText, !recognizedText.isEmpty {
                self?.viewModel?.sendRecognizedText(recognizedText)
                self?.recognizedText = ""
            }
        }
    }
}

// MARK: - 3. ViewModel (앱의 로직을 담당)
class ChatViewModel: ObservableObject {
    
    #if DEBUG
    private let serverURL = "http://85bc2d4a2282.ngrok-free.app"   // 디버그용
    #else
    private let serverURL = "http://13.124.208.108:2479"      // 릴리즈용(실제 서버 URL로 교체)
    #endif

    @Published var messages: [ChatMessage] = []
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    @Published var isChatActive: Bool = true

    private var history: [ChatMessage] {
        return messages.filter { $0.role != "system" }
    }
    
    @Published var audioController: AudioController
    
    init() {
        let controller = AudioController()
        self.audioController = controller
        controller.viewModel = self
    }

    func startChat() {
        guard messages.isEmpty else { return }

        Task {
            await MainActor.run {
                self.isLoading = true
                self.errorMessage = nil
            }
            
            do {
                let url = URL(string: "\(serverURL)/chat/start")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                
                let body = ["prompt": "Hello! Would you like to practice some interesting expressions with me?"]
                request.httpBody = try JSONEncoder().encode(body)

                let (data, _) = try await URLSession.shared.data(for: request)
                let response = try JSONDecoder().decode(StartResponse.self, from: data)
                
                await MainActor.run {
                    self.messages.append(ChatMessage(role: "assistant", text: response.assistant_text))
                    self.isLoading = false
                    self.audioController.speak(response.assistant_text)
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.errorMessage = "Failed to start chat: \(error.localizedDescription)"
                }
            }
        }
    }
    
    func sendRecognizedText(_ text: String) {
        guard !text.isEmpty && !isLoading && isChatActive else { return }
        
        let userMessage = ChatMessage(role: "user", text: text)
        
        DispatchQueue.main.async {
            self.messages.append(userMessage)
            self.isLoading = true
            self.errorMessage = nil
        }
        
        Task {
            do {
                let url = URL(string: "\(serverURL)/chat/reply")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                
                let replyRequest = ReplyRequest(history: history, user_text: userMessage.text)
                request.httpBody = try JSONEncoder().encode(replyRequest)

                let (data, _) = try await URLSession.shared.data(for: request)
                let response = try JSONDecoder().decode(ReplyResponse.self, from: data)
                
                await MainActor.run {
                    self.messages.append(ChatMessage(role: "assistant", text: response.assistant_text))
                    self.isLoading = false
                    self.audioController.speak(response.assistant_text)
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.errorMessage = "Failed to get AI response: \(error.localizedDescription)"
                }
            }
        }
    }
    
    func endChat() {
        self.isChatActive = false
        audioController.forceStopRecognition()
        self.messages.append(ChatMessage(role: "system", text: "대화가 종료되었습니다."))
    }
    
    func resumeChat() {
        self.isChatActive = true
        self.messages = []
        self.startChat()
    }
}

// MARK: - 4. Alarm Manager
class AlarmManager: ObservableObject {
    @Published var alarms: [Alarm] = []
    
    private let alarmsKey = "savedAlarms"
    
    init() {
        loadAlarms()
    }
    
    // UserDefaults에 알람 저장
    private func saveAlarms() {
        if let encoded = try? JSONEncoder().encode(alarms) {
            UserDefaults.standard.set(encoded, forKey: alarmsKey)
        }
    }
    
    // UserDefaults에서 알람 불러오기
    private func loadAlarms() {
        if let savedAlarms = UserDefaults.standard.data(forKey: alarmsKey) {
            if let decodedAlarms = try? JSONDecoder().decode([Alarm].self, from: savedAlarms) {
                self.alarms = decodedAlarms
                return
            }
        }
        self.alarms = []
    }
    
    // 알람 추가
    func addAlarm(alarm: Alarm) {
        // 최대 5개 알람 제한
        guard alarms.count < 5 else { return }
        
        var newAlarm = alarm
        // id가 비어있을 경우에만 새로운 id 생성
        if newAlarm.id.isEmpty {
            newAlarm.id = UUID().uuidString
        }
        alarms.append(newAlarm)
        scheduleNotification(for: newAlarm)
        saveAlarms()
    }
    
    // 알람 활성화/비활성화
    func toggleAlarm(id: String) {
        if let index = alarms.firstIndex(where: { $0.id == id }) {
            alarms[index].isActive.toggle()
            if alarms[index].isActive {
                scheduleNotification(for: alarms[index])
            } else {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [alarms[index].id])
            }
            saveAlarms()
        }
    }
    
    // 알람 삭제
    func deleteAlarm(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        alarms.removeAll(where: { $0.id == id })
        saveAlarms()
    }
    
    // 알람 스케줄링
    // AlarmManager 안에 헬퍼 추가
    private func identifiers(for alarm: Alarm) -> [String] {
        switch alarm.type {
        case .weekly:
            return alarm.weekdays.map { "\(alarm.id)_w\($0)" }
        default:
            return [alarm.id]
        }
    }
   


    // AlarmManager 안의 함수 교체
    private func scheduleNotification(for alarm: Alarm) {
        // 기존 동일 ID 예약 제거 (weekly인 경우 관련 ID 전체 제거)
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: identifiers(for: alarm))

        guard alarm.isActive else { return }

        let center = UNUserNotificationCenter.current()

        switch alarm.type {
        case .weekly:
            // ✅ 선택된 요일마다 개별 트리거 생성
            let content = UNMutableNotificationContent()
            content.title = "영어 대화 알람"
            content.body = "영어 대화할 시간입니다!"

            let alarmSounds = ["eng_prompt_01.wav","eng_prompt_02.wav","eng_prompt_03.wav","eng_prompt_04.wav","eng_prompt_05.wav"]
            if let s = alarmSounds.randomElement() {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(s))
            } else {
                content.sound = .default
            }

            let hm = Calendar.current.dateComponents([.hour, .minute], from: alarm.time)

            for wd in alarm.weekdays {
                var dc = hm
                dc.weekday = wd // ✅ 요일 고정
                let trigger = UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)
                let id = "\(alarm.id)_w\(wd)" // ✅ 요일별 고유 ID
                let req = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
                center.add(req) { err in
                    if let err = err { print("주간 알람 스케줄 실패(\(wd)): \(err)") }
                }
            }

        case .daily, .interval:
            // 기존 로직 재사용
            let request = alarm.createNotificationRequest()
            if request.trigger != nil {
                center.add(request) { error in
                    if let error = error {
                        print("알림 스케줄링 실패: \(error.localizedDescription)")
                    } else {
                        print("알람 스케줄링 성공: \(alarm.id)")
                    }
                }
            }
        }
    }

}

// MARK: - 5. Views (UI 컴포넌트)
// 기존 대화 화면
struct ChatView: View {
    @StateObject private var viewModel = ChatViewModel()
    @Binding var showChatView: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: {
                    withAnimation {
                        showChatView = false
                        viewModel.endChat()
                    }
                }) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(.blue)
                }
                .padding(.horizontal)
                
                Spacer()
                Text("English Tutor")
                    .font(.headline)
                Spacer()
            }
            .padding(.top)
            .padding(.bottom, 5)

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    ForEach(viewModel.messages) { message in
                        MessageView(message: message) {
                            if message.role == "assistant" {
                                viewModel.audioController.speak(message.text)
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemGray6))
            
            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .padding()
                }
            
            if viewModel.isLoading {
                ProgressView()
                    .padding()
            }
            
            AudioControlView(viewModel: viewModel)
                .padding()
                .background(Color(.systemBackground))
        }
        .onAppear {
            viewModel.startChat()
        }
    }
}

struct MessageView: View {
    let message: ChatMessage
    let action: () -> Void
    
    var isUser: Bool { message.role == "user" }
    
    var body: some View {
        HStack {
            if isUser {
                Spacer()
            } else {
                Button(action: action) {
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundColor(.blue)
                    }
                }
            
            Text(message.text)
                .padding(10)
                .background(message.role == "user" ? Color.blue : Color(.systemGray4))
                .foregroundColor(message.role == "user" ? .white : .black)
                .cornerRadius(12)
                .frame(maxWidth: 300, alignment: message.role == "user" ? .trailing : .leading)
            
            if !isUser {
                Spacer()
            }
        }
    }
}

struct AudioControlView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        if viewModel.isChatActive {
            HStack {
                Spacer()
                if viewModel.audioController.isRecognizing {
                    Text("Listening...")
                        .foregroundColor(.gray)
                } else if !viewModel.audioController.recognizedText.isEmpty {
                    Text(viewModel.audioController.recognizedText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundColor(.black)
                } else {
                    Text("말씀해주세요...")
                        .foregroundColor(.gray)
                }
                Spacer()

                Button(action: {
                    viewModel.endChat()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.red)
                }
            }
        } else {
            HStack {
                Spacer()
                Button(action: {
                    viewModel.resumeChat()
                }) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.green)
                }
                Text("재개")
                    .foregroundColor(.green)
                Spacer()
            }
        }
    }
}

// 새로운 메인 알람 화면
struct MainAlarmView: View {
    @State private var selectedTab: AlarmType = .daily
    @State private var selectedTime = Date()
    @State private var selectedWeekdays: Set<Int> = []
    @State private var selectedInterval: Double = 30 // 분 단위
    
    @StateObject private var alarmManager = AlarmManager()
    
    @Binding var showChatView: Bool
    
    // 요일 선택
    let weekdays = ["일", "월", "화", "수", "목", "금", "토"]
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // 상단 컨트롤 영역
                VStack(spacing: 15) {
                    HStack {
                        // 매일/요일별 탭
                        Picker("알람 유형", selection: $selectedTab) {
                            Text(AlarmType.daily.rawValue).tag(AlarmType.daily)
                            Text(AlarmType.weekly.rawValue).tag(AlarmType.weekly)
                            Text(AlarmType.interval.rawValue).tag(AlarmType.interval)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: .infinity)
                        
                        // 알람 저장 버튼
                        Button("저장") {
                            let newAlarm: Alarm
                            if selectedTab == .interval {
                                newAlarm = Alarm(id: "", type: .interval, time: Date(), weekdays: [], interval: Int(selectedInterval), isActive: true)
                            } else {
                                newAlarm = Alarm(id: "", type: selectedTab, time: selectedTime, weekdays: selectedWeekdays, interval: nil, isActive: true)
                            }
                            alarmManager.addAlarm(alarm: newAlarm)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 10) {
                        if selectedTab == .daily || selectedTab == .weekly {
                            DatePicker("시간 선택", selection: $selectedTime, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .datePickerStyle(.wheel)
                                .frame(height: 100)
                        }
                        
                        if selectedTab == .weekly {
                            HStack(spacing: 10) {
                                ForEach(1..<8) { weekday in
                                    Text(weekdays[weekday - 1])
                                        .frame(width: 30, height: 30)
                                        .background(selectedWeekdays.contains(weekday) ? Color.blue : Color(.systemGray5))
                                        .foregroundColor(selectedWeekdays.contains(weekday) ? .white : .black)
                                        .cornerRadius(15)
                                        .onTapGesture {
                                            if selectedWeekdays.contains(weekday) {
                                                selectedWeekdays.remove(weekday)
                                            } else {
                                                selectedWeekdays.insert(weekday)
                                            }
                                        }
                                }
                            }
                        }
                        
                        if selectedTab == .interval {
                            VStack(alignment: .leading) {
                                Text("알람 주기 (\(Int(selectedInterval))분)")
                                    .font(.headline)
                                Slider(value: $selectedInterval, in: 5...60, step: 5)
                                    .tint(.green)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(15)
                
                // 대화하기 버튼
                Button("대화하기") {
                    withAnimation {
                        showChatView = true
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(15)
                
                // 알람 목록
                List {
                    Section(header: Text("내 알람 목록 (최대 5개)").font(.headline)) {
                        ForEach(alarmManager.alarms) { alarm in
                            HStack {
                                Text(alarm.description)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { alarm.isActive },
                                    set: { _ in alarmManager.toggleAlarm(id: alarm.id) }
                                ))
                                .labelsHidden()
                                .tint(.green)
                                
                                Button {
                                    alarmManager.deleteAlarm(id: alarm.id)
                                } label: {
                                    Image(systemName: "trash.fill")
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .frame(maxHeight: 250)
            }
            .padding()
            .navigationTitle("설정")
            
        }
        .navigationViewStyle(.stack)             // ✅ 이 줄 추가 (iPad에서도 단일 화면)

    }
}

// MARK: - 6. App Entry Point
@main
struct EnglishChatAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - AppDelegate for UNUserNotificationCenterDelegate
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        requestNotificationPermission()
        return true
    }

    // 알림 권한 요청
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("Notification permission granted.")
            } else {
                print("Notification permission denied.")
            }
        }
    }

    // Foreground에서 알림이 올 때 표시
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // 알림이 foreground에 있을 때 배너, 소리, 뱃지 표시
        completionHandler([.banner, .sound, .badge])
    }
}

struct ContentView: View {
    @State private var showChatView = false
    
    var body: some View {
        if showChatView {
            ChatView(showChatView: $showChatView)
        } else {
            MainAlarmView(showChatView: $showChatView)
        }
    }
}
