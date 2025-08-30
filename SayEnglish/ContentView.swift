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
struct ChatMessage: Identifiable, Codable, Equatable {
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

// ✅ 기존 ChatSession 교체
struct ChatSession: Identifiable, Codable, Equatable {
    let id: UUID
    let startTime: Date
    var messages: [ChatMessage]
    var totalSeconds: Int? = 0   // ✅ 총 대화시간(초) 저장

    static func == (lhs: ChatSession, rhs: ChatSession) -> Bool {
        return lhs.id == rhs.id
    }
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
            dateComponents.timeZone = .current
            
            if type == .weekly {
                let weekday = Calendar.current.component(.weekday, from: time)
                if !weekdays.contains(weekday) {
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
    func stopSpeaking() {
            if synthesizer.isSpeaking {
                synthesizer.stopSpeaking(at: .immediate)
            }
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

    private func findPreferredVoice() -> AVSpeechSynthesisVoice? {
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
    private let serverURL = "http://85bc2d4a2282.ngrok-free.app"
    #else
    private let serverURL = "http://13.124.208.108:2479"
    #endif

    @Published var messages: [ChatMessage] = []
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    @Published var isChatActive: Bool = true
    
    // ✅ 추가: 현재 진행 중인 채팅 세션
    @Published var currentSession: ChatSession?

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

        // ✅ 추가: 새로운 채팅 세션 시작
        self.currentSession = ChatSession(id: UUID(), startTime: Date(), messages: [])

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
                
                let assistantMessage = ChatMessage(role: "assistant", text: response.assistant_text)
                await MainActor.run {
                    self.messages.append(assistantMessage)
                    self.currentSession?.messages.append(assistantMessage) // ✅ 추가: 세션에 메시지 저장
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
            self.currentSession?.messages.append(userMessage) // ✅ 추가: 세션에 메시지 저장
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
                
                let assistantMessage = ChatMessage(role: "assistant", text: response.assistant_text)
                await MainActor.run {
                    self.messages.append(assistantMessage)
                    self.currentSession?.messages.append(assistantMessage) // ✅ 추가: 세션에 메시지 저장
                    self.isLoading = false
                    self.audioController.speak(assistantMessage.text)
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

// MARK: - 4. Alarm & History Manager
// ✅ AlarmManager와 ChatHistoryManager를 하나로 합쳐서 관리 효율을 높입니다.
class ChatHistoryManager: ObservableObject {
    
    private let chatSessionsKey = "savedChatSessions"
    private let maxSessions = 5

    @Published var alarms: [Alarm] = []
    private let alarmsKey = "savedAlarms"
    
    @Published var chatSessions: [ChatSession] = []
    
    init() {
        loadAlarms()
        loadChatSessions()
    }
    
    // MARK: - Chat History Management
    
    // UserDefaults에서 채팅 기록 불러오기
    func loadChatSessions() {
        if let savedSessions = UserDefaults.standard.data(forKey: chatSessionsKey) {
            if let decodedSessions = try? JSONDecoder().decode([ChatSession].self, from: savedSessions) {
                self.chatSessions = decodedSessions.sorted(by: { $0.startTime > $1.startTime })
                return
            }
        }
        self.chatSessions = []
    }
    
    // 새로운 채팅 세션 저장 (5개 제한)
    func saveChatSession(_ session: ChatSession) {
        // 이미 존재하는 세션이 아닌지 확인
        if let index = chatSessions.firstIndex(where: { $0.id == session.id }) {
            chatSessions[index] = session
        } else {
            // 새로운 세션 추가
            chatSessions.insert(session, at: 0)
        }
        
        // 5개 초과 시 가장 오래된 것 삭제
        if chatSessions.count > maxSessions {
            chatSessions.removeLast()
        }
        
        saveChatSessions()
    }
    
    // UserDefaults에 채팅 기록 저장
    func saveChatSessions() {
        if let encoded = try? JSONEncoder().encode(chatSessions) {
            UserDefaults.standard.set(encoded, forKey: chatSessionsKey)
        }
    }
    
    // 특정 채팅 세션 삭제
    func deleteChatSession(id: UUID) {
        chatSessions.removeAll(where: { $0.id == id })
        saveChatSessions()
    }
    
    // MARK: - Alarm Management
    
    private func saveAlarms() {
        if let encoded = try? JSONEncoder().encode(alarms) {
            UserDefaults.standard.set(encoded, forKey: alarmsKey)
        }
    }
    
    private func loadAlarms() {
        if let savedAlarms = UserDefaults.standard.data(forKey: alarmsKey) {
            if let decodedAlarms = try? JSONDecoder().decode([Alarm].self, from: savedAlarms) {
                self.alarms = decodedAlarms
                return
            }
        }
        self.alarms = []
    }
    
    // ✅ 교체: ChatHistoryManager.addAlarm(alarm:) → Bool 반환
    func addAlarm(alarm: Alarm) -> Bool {
        // 최대 5개 제한
        guard alarms.count < 5 else {
            return false
        }

        var newAlarm = alarm
        if newAlarm.id.isEmpty {
            newAlarm.id = UUID().uuidString
        }
        alarms.append(newAlarm)
        scheduleNotification(for: newAlarm)
        saveAlarms()
        return true
    }

    
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
    
    func deleteAlarm(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        alarms.removeAll(where: { $0.id == id })
        saveAlarms()
    }
    
    private func identifiers(for alarm: Alarm) -> [String] {
        switch alarm.type {
        case .weekly:
            return alarm.weekdays.map { "\(alarm.id)_w\($0)" }
        default:
            return [alarm.id]
        }
    }
    
    private func scheduleNotification(for alarm: Alarm) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: identifiers(for: alarm))
        
        guard alarm.isActive else { return }
        
        let center = UNUserNotificationCenter.current()
        
        switch alarm.type {
        case .weekly:
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
                dc.weekday = wd
                let trigger = UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)
                let id = "\(alarm.id)_w\(wd)"
                let req = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
                center.add(req) { err in
                    if let err = err { print("주간 알람 스케줄 실패(\(wd)): \(err)") }
                }
            }
            
        case .daily, .interval:
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
// ✅ 기존 ChatView 전체 교체
struct ChatView: View {
    @StateObject private var viewModel = ChatViewModel()
    @Binding var showChatView: Bool
    @EnvironmentObject var historyManager: ChatHistoryManager

    // ✅ 타이머 상태
    @State private var elapsedSec = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private func fmt(_ sec: Int) -> String {
        let m = sec / 60, s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: {
                    // ✅ 나가기 전에 세션 저장 + 시간 기록
                    if let session = viewModel.currentSession, !session.messages.isEmpty {
                        viewModel.currentSession?.totalSeconds = elapsedSec
                        historyManager.saveChatSession(viewModel.currentSession!)
                    }
                    // ✅ 음성 즉시 중지
                    viewModel.audioController.stopSpeaking()
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

                // ✅ 우측 상단 타이머
                Text(fmt(elapsedSec))
                    .font(.footnote.monospacedDigit())
                    .foregroundColor(.secondary)
                    .padding(.trailing, 12)
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
            // ✅ 새 대화 시작 시 타이머 리셋
            elapsedSec = 0
            viewModel.startChat()
        }
        .onDisappear {
            // ✅ 화면 떠날 때도 TTS 중지만 (저장은 위 버튼에서 처리)
            viewModel.audioController.stopSpeaking()
        }
        // ✅ 1초마다 경과 시간 증가 (대화 중일 때만)
        .onReceive(timer) { _ in
            if viewModel.isChatActive {
                elapsedSec += 1
            }
        }
        // ✅ 재개 버튼으로 대화 재시작할 때 타이머 리셋
        .onChange(of: viewModel.isChatActive) { isActive in
            if isActive { elapsedSec = 0 }
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

// ✅ 대화 기록 재생(TTS)만 추가한 DetailedChatView
struct DetailedChatView: View {
    let session: ChatSession
    @Environment(\.dismiss) var dismiss
    
    // 로컬 TTS 전용 합성기 (ChatViewModel에 의존 X)
    @State private var synthesizer = AVSpeechSynthesizer()
    
    // 상세뷰 전용 보이스 선택
    private func preferredVoice() -> AVSpeechSynthesisVoice? {
        // premium → enhanced → 기본(en-US) 우선
        if let v = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language == "en-US" && $0.quality == .premium }) {
            return v
        }
        if let v = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language == "en-US" && $0.quality == .enhanced }) {
            return v
        }
        return AVSpeechSynthesisVoice(language: "en-US")
    }
    
    private func speak(_ text: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let u = AVSpeechUtterance(string: text)
        u.voice = preferredVoice()
        u.volume = 1.0
        synthesizer.speak(u)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: {
                    // ✅ 뒤로 가기 직전 중지(체감 즉시)
                                        if synthesizer.isSpeaking {
                                            synthesizer.stopSpeaking(at: .immediate)
                                        }
                    
                    dismiss() }) {
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
                    ForEach(session.messages) { message in
                        // ✅ 여기만 변경: 스피커 탭 시 TTS 재생
                        MessageView(message: message) {
                            if message.role == "assistant" {
                                speak(message.text)
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemGray6))
        }
        .navigationTitle(Text(session.startTime, format: .dateTime.hour().minute().day().month()))
        .navigationBarTitleDisplayMode(.inline)
        // ✅ 네비게이션 등 어떤 이유로든 화면이 사라질 때도 보장
                .onDisappear {
                    if synthesizer.isSpeaking {
                        synthesizer.stopSpeaking(at: .immediate)
                    }
                }
    }
}



// ✅ 세련된 메인 화면 (전체 교체)
// ✅ 세련 디자인 + 알람 5개 제한 팝업 포함 MainView (전체 교체)
struct MainView: View {
    @State private var selectedTab: AlarmType = .daily
    @State private var selectedTime = Date()
    @State private var selectedWeekdays: Set<Int> = []
    @State private var selectedInterval: Double = 30

    @EnvironmentObject var historyManager: ChatHistoryManager
    @Binding var showChatView: Bool

    // 요일 라벨
    private let weekdays = ["일","월","화","수","목","금","토"]

    // 자정 리셋용
    @State private var now = Date()
    private let minuteTicker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    // 알람 5개 초과 팝업
    @State private var showAlarmLimitAlert = false

    private func mmss(_ sec: Int) -> String {
        let m = sec / 60, s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }

    var body: some View {
        ZStack {
            // 배경 그라데이션
            LinearGradient(
                colors: [Color.purple.opacity(0.25), Color.indigo.opacity(0.25)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            NavigationView {
                ScrollView {
                    VStack(spacing: 18) {

                        // 상단 바 (타이틀 + 히스토리 아이콘)
                        HStack {
                            Text("English Bell")
                                .font(.largeTitle.bold())
                                .foregroundColor(.primary)

                            Spacer()

                            NavigationLink {
                                DailyHistoryView()
                            } label: {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.title3.weight(.semibold))
                                    .foregroundColor(.purple)
                                    .padding(8)
                                    .background(Color.white.opacity(0.55), in: Circle())
                            }
                            .accessibilityLabel("히스토리")
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 6)

                        // 카드 1: 탭 + 저장 (시간 피커와 완전 분리)
                        SectionCard {
                            HStack(spacing: 12) {
                                Picker("알람 유형", selection: $selectedTab) {
                                    Text(AlarmType.daily.rawValue).tag(AlarmType.daily)
                                    Text(AlarmType.weekly.rawValue).tag(AlarmType.weekly)
                                    Text(AlarmType.interval.rawValue).tag(AlarmType.interval)
                                }
                                .pickerStyle(.segmented)

                                Button {
                                    let newAlarm: Alarm
                                    if selectedTab == .interval {
                                        newAlarm = Alarm(id: "", type: .interval,
                                                         time: Date(), weekdays: [],
                                                         interval: Int(selectedInterval), isActive: true)
                                    } else {
                                        newAlarm = Alarm(id: "", type: selectedTab,
                                                         time: selectedTime, weekdays: selectedWeekdays,
                                                         interval: nil, isActive: true)
                                    }
                                    let ok = historyManager.addAlarm(alarm: newAlarm) // ← Bool 반환 버전 사용
                                    if !ok { showAlarmLimitAlert = true }
                                } label: {
                                    Text("저장").font(.headline)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }

                        // 카드 2: 상세 설정 (선택된 탭에 따라 UI 전환)
                        SectionCard(spacing: 14) {
                            if selectedTab == .daily || selectedTab == .weekly {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("시간 선택")
                                        .font(.headline)
                                    DatePicker("", selection: $selectedTime, displayedComponents: .hourAndMinute)
                                        .labelsHidden()
                                        .datePickerStyle(.wheel)
                                        .frame(height: 100)
                                }
                            }

                            if selectedTab == .weekly {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("요일 선택")
                                        .font(.headline)
                                    FlowWeekdays(labels: weekdays, selected: $selectedWeekdays)
                                }
                            }

                            if selectedTab == .interval {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("알람 주기")
                                            .font(.headline)
                                        Spacer()
                                        Text("\(Int(selectedInterval))분")
                                            .font(.headline.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    Slider(value: $selectedInterval, in: 5...60, step: 5)
                                        .tint(.purple)
                                }
                            }
                        }

                        // 대화하기 버튼 (그라데이션 프라이머리 버튼)
                        Button {
                            withAnimation { showChatView = true }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "waveform.circle.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                Text("대화하기")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundColor(.white)
                            .background(
                                LinearGradient(colors: [Color.purple, Color.indigo],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                            .cornerRadius(14)
                            .shadow(color: Color.indigo.opacity(0.25), radius: 12, x: 0, y: 8)
                        }
                        .padding(.horizontal, 16)

                        // 오늘 진행 (보라 그라데이션 프로그레스바)
                        let todaySeconds = historyManager.seconds(for: now)
                        let progress = min(Double(todaySeconds) / 3600.0, 1.0)

                        SectionCard {
                            VStack(spacing: 10) {
                                HStack {
                                    Text("오늘 대화")
                                        .font(.headline)
                                    Spacer()
                                    Text("\(mmss(todaySeconds)) / 60:00")
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                GradientProgressBar(progress: progress)
                                    .frame(height: 16)
                            }
                        }

                        // 알람/대화 기록 리스트 (글래스 카드)
                        SectionCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("내 알람 목록 (최대 5개)")
                                    .font(.headline)

                                if historyManager.alarms.isEmpty {
                                    Text("등록된 알람이 없습니다.")
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(historyManager.alarms) { alarm in
                                        HStack {
                                            Text(alarm.description)
                                                .font(.subheadline)
                                            Spacer()
                                            Toggle("", isOn: Binding(
                                                get: { alarm.isActive },
                                                set: { _ in historyManager.toggleAlarm(id: alarm.id) }
                                            ))
                                            .labelsHidden()
                                            .tint(.purple)

                                            Button {
                                                historyManager.deleteAlarm(id: alarm.id)
                                            } label: {
                                                Image(systemName: "trash.fill")
                                                    .foregroundColor(.red)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(.vertical, 6)

                                        Divider().opacity(0.15)
                                    }
                                }
                            }
                        }

                        SectionCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("대화 기록 (최대 5개)")
                                    .font(.headline)

                                if historyManager.chatSessions.isEmpty {
                                    Text("대화 기록이 없습니다.")
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(historyManager.chatSessions) { session in
                                        NavigationLink(destination: DetailedChatView(session: session)) {
                                            HStack {
                                                Text(session.startTime, format: .dateTime.hour().minute().day().month())
                                                    .font(.subheadline)
                                                Spacer()
                                                Text(mmss(session.totalSeconds ?? 0))
                                                    .font(.subheadline.monospacedDigit())
                                                    .foregroundStyle(.secondary)
                                            }
                                            .contentShape(Rectangle())
                                        }
                                        .padding(.vertical, 6)

                                        Divider().opacity(0.15)
                                    }
                                }
                            }
                        }

                        Spacer(minLength: 10)
                    }
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    historyManager.loadChatSessions()
                    now = Date()
                }
                .onReceive(minuteTicker) { _ in
                    now = Date()
                }
                .background(Color.clear)
                .navigationBarHidden(true)
            }
        }
        .alert("저장할 수 없어요", isPresented: $showAlarmLimitAlert) {
            Button("확인", role: .cancel) { }
        } message: {
            Text("알람은 최대 5개까지 저장할 수 있어요.")
        }
    }
}

//
// MARK: - Reusable UI (같은 파일에 붙여넣어 사용)
//

/// 글래스 카드
fileprivate struct SectionCard<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.35), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.07), radius: 12, x: 0, y: 6)
        .padding(.horizontal, 16)
    }
}

/// 요일 선택: 항상 1줄, 가로 스크롤
fileprivate struct FlowWeekdays: View {
    let labels: [String]            // ["일","월","화","수","목","금","토"]
    @Binding var selected: Set<Int> // 1~7

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(1..<8) { weekday in
                    let isOn = selected.contains(weekday)
                    Text(labels[weekday - 1])
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(isOn ? Color.purple : Color.white.opacity(0.6))
                        .foregroundColor(isOn ? .white : .primary)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.purple.opacity(0.5), lineWidth: isOn ? 0 : 1)
                        )
                        .cornerRadius(12)
                        .onTapGesture {
                            if isOn { selected.remove(weekday) } else { selected.insert(weekday) }
                        }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity)
    }
}


//
// MARK: - Reusable UI
//

///// 글래스 카드
//fileprivate struct SectionCard<Content: View>: View {
//    var spacing: CGFloat = 12
//    @ViewBuilder var content: () -> Content
//
//    var body: some View {
//        VStack(alignment: .leading, spacing: spacing) {
//            content()
//        }
//        .padding(16)
//        .background(
//            RoundedRectangle(cornerRadius: 18)
//                .fill(.thinMaterial)
//                .overlay(
//                    RoundedRectangle(cornerRadius: 18)
//                        .stroke(Color.white.opacity(0.35), lineWidth: 1)
//                )
//        )
//        .shadow(color: Color.black.opacity(0.07), radius: 12, x: 0, y: 6)
//        .padding(.horizontal, 16)
//    }
//}
//
//// ✅ 교체: FlowWeekdays (LazyVGrid 사용, 자동 줄바꿈 + 올바른 높이 계산)
//// ✅ 교체: FlowWeekdays (항상 1줄, 가로 스크롤)
//fileprivate struct FlowWeekdays: View {
//    let labels: [String]            // ["일","월","화","수","목","금","토"]
//    @Binding var selected: Set<Int> // 1~7
//
//    var body: some View {
//        ScrollView(.horizontal, showsIndicators: false) {
//            HStack(spacing: 8) {
//                ForEach(1..<8) { weekday in
//                    let isOn = selected.contains(weekday)
//                    Text(labels[weekday - 1])
//                        .font(.subheadline.weight(.semibold))
//                        .padding(.horizontal, 12)
//                        .padding(.vertical, 8)
//                        .background(isOn ? Color.purple : Color.white.opacity(0.6))
//                        .foregroundColor(isOn ? .white : .primary)
//                        .overlay(
//                            RoundedRectangle(cornerRadius: 12)
//                                .stroke(Color.purple.opacity(0.5), lineWidth: isOn ? 0 : 1)
//                        )
//                        .cornerRadius(12)
//                        .onTapGesture {
//                            if isOn { selected.remove(weekday) } else { selected.insert(weekday) }
//                        }
//                }
//            }
//            .padding(.vertical, 2) // 스크롤 영역에 약간 여유
//        }
//        .frame(maxWidth: .infinity) // 부모 폭 채우기
//    }
//}



/// 가변 줄바꿈 HStack (태그 레이아웃)
fileprivate struct FlexibleWrapHStack<Content: View>: View {
    var spacing: CGFloat = 8
    var runSpacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        var width = CGFloat.zero
        var height = CGFloat.zero
        return GeometryReader { g in
            ZStack(alignment: .topLeading) {
                content()
                    .alignmentGuide(.leading) { d in
                        if (abs(width - d.width) > g.size.width) {
                            width = 0
                            height -= (d.height + runSpacing)
                        }
                        let result = width
                        width -= (d.width + spacing)
                        return result
                    }
                    .alignmentGuide(.top) { _ in
                        let result = height
                        return result
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 0)
    }
}




// ✅ 추가: 보라 그라데이션 프로그레스바
struct GradientProgressBar: View {
    let progress: Double // 0.0 ~ 1.0

    var body: some View {
        GeometryReader { geo in
            let width = max(0, min(1, progress)) * geo.size.width
            ZStack(alignment: .leading) {
                // 트랙
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    )
                // 채워진 부분
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [Color.purple, Color.indigo],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: width)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.white.opacity(0.2))
                    )
            }
        }
        .frame(height: 16)
    }
}

// ✅ ChatHistoryManager에 유틸 추가
extension ChatHistoryManager {
    /// 해당 날짜(현지 기준) 누적 초
    func seconds(for date: Date) -> Int {
        let cal = Calendar.current
        return chatSessions.reduce(0) { acc, s in
            cal.isDate(s.startTime, inSameDayAs: date) ? acc + (s.totalSeconds ?? 0) : acc
        }
    }

    /// 날짜별 누적 초 목록 (최신 날짜 우선)
    func dailyTotals() -> [(date: Date, seconds: Int)] {
        let cal = Calendar.current
        var bucket: [Date: Int] = [:] // key = startOfDay
        for s in chatSessions {
            let day = cal.startOfDay(for: s.startTime)
            bucket[day, default: 0] += (s.totalSeconds ?? 0)
        }
        return bucket
            .map { ($0.key, $0.value) }
            .sorted { $0.0 > $1.0 }
    }
}

// ✅ 새로 추가: DailyHistoryView
// ✅ 기존 DailyHistoryView 전체 교체(보라 그라데이션 + 카드형 셀)
struct DailyHistoryView: View {
    @EnvironmentObject var historyManager: ChatHistoryManager
    @Environment(\.dismiss) var dismiss

    // 최근 N일 필터 (원하면 7/30일 토글)
    @State private var dayWindow: Int = 30

    private func mmss(_ sec: Int) -> String {
        let m = sec / 60, s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }

    private var filteredTotals: [(date: Date, seconds: Int)] {
        let all = historyManager.dailyTotals()
        guard dayWindow > 0 else { return all }
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -dayWindow + 1, to: cal.startOfDay(for: Date())) ?? Date.distantPast
        return all.filter { $0.date >= cutoff }
    }

    var body: some View {
        ZStack {
            // ✅ 배경 보라 그라데이션
            LinearGradient(
                colors: [Color.purple.opacity(0.9), Color.indigo.opacity(0.9)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // 상단 커스텀 바
                HStack(spacing: 12) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.title3.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.white.opacity(0.15), in: Circle())
                    }

                    Spacer()

                    Text("히스토리")
                        .font(.headline)
                        .foregroundColor(.white)

                    Spacer()

                    // 오른쪽 여백 정렬용
                    Color.clear.frame(width: 36, height: 36)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // 기간 선택 (선택사항)
                HStack(spacing: 8) {
                    ForEach([7, 14, 30], id: \.self) { d in
                        Button {
                            dayWindow = d
                        } label: {
                            Text("\(d)일")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(dayWindow == d ? .purple : .white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.white.opacity(dayWindow == d ? 0.95 : 0.18))
                                )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

                // 내용 카드 리스트
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(filteredTotals, id: \.date) { (day, seconds) in
                            let progress = min(Double(seconds) / 3600.0, 1.0)

                            // 카드 셀
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(day, format: .dateTime.year().month().day())
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Text("\(mmss(seconds)) / 60:00")
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundColor(.secondary)
                                }

                                GradientProgressBar(progress: progress)
                                    .frame(height: 16)
                            }
                            .padding(16)
                            .background(
                                // 유리 카드 느낌
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(.thinMaterial)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16)
                                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                                    )
                            )
                            .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 6)
                            .padding(.horizontal, 16)
                        }

                        // 빈 상태 안내
                        if filteredTotals.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.system(size: 42))
                                    .foregroundColor(.white.opacity(0.8))
                                Text("아직 대화 기록이 없어요")
                                    .foregroundColor(.white.opacity(0.95))
                                Text("오늘부터 60분 목표를 채워보세요!")
                                    .foregroundColor(.white.opacity(0.8))
                                    .font(.subheadline)
                            }
                            .padding(.top, 40)
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
    }
}


// MARK: - 6. App Entry Point
@main
struct EnglishChatAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    // ✅ 추가: 앱 전체에서 공유할 ChatHistoryManager
    @StateObject private var historyManager = ChatHistoryManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(historyManager) // ✅ 추가: 환경 객체로 주입
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
        completionHandler([.banner, .sound, .badge])
    }
}

struct ContentView: View {
    @State private var showChatView = false
    
    var body: some View {
        if showChatView {
            ChatView(showChatView: $showChatView)
        } else {
            MainView(showChatView: $showChatView)
        }
    }
}
