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
import GoogleMobileAds

enum ChatLevel: String, Codable, CaseIterable {
    case beginner, intermediate, advanced
    
    var emoji: String {
        switch self {
        case .beginner: return "🟢"
        case .intermediate: return "🟡"
        case .advanced: return "🔴"
        }
    }
    var title: String {
        switch self {
        case .beginner: return "Beginner"
        case .intermediate: return "Intermediate"
        case .advanced: return "Advanced"
        }
    }
    var subtitle: String {
        switch self {
        case .beginner: return "기초적인 일상 표현부터 차근차근"
        case .intermediate: return "실제 대화에 가까운 문장 훈련"
        case .advanced: return "상황별 심화 대화로 실전 감각 키우기"
        }
    }
    /// /chat/start에 보낼 프롬프트
    var seedPrompt: String {
            switch self {
            case .beginner: return "Let's practice basic daily English expressions step-by-step. Keep responses short, slow, and simple."
            case .intermediate: return "Let's practice real-life English dialogue. Give natural, moderately long replies and follow-up questions."
            case .advanced: return "Let's practice advanced scenario-based conversation. Give nuanced, challenging prompts and push fluency."
            }
        }
}

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
// ✅ 요청 DTO에 level 추가
struct StartRequest: Codable {
    let prompt: String?
    let level: String
    init(prompt: String?, level: ChatLevel) {
        self.prompt = prompt
        self.level = level.rawValue
    }
}
// /chat/reply 엔드포인트 요청
struct ReplyRequest: Codable {
    let history: [ChatMessage]
    let user_text: String
    let level: String
    init(history: [ChatMessage], user_text: String, level: ChatLevel) {
        self.history = history
        self.user_text = user_text
        self.level = level.rawValue
    }
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
        guard !synthesizer.isSpeaking else { return } // TTS 중이면 무시

        recognitionTask?.cancel()
        recognitionTask = nil

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .voiceChat, // ✅ 에코 캔슬링
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setPreferredSampleRate(44100)                // ✅ STT와 잘 맞음
        try session.setPreferredIOBufferDuration(0.005)          // ✅ 지연 축소
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // 필요 시: on-device만 쓰고 싶다면
        // req.requiresOnDeviceRecognition = true

        recognitionRequest = req
        recognitionTask = speechRecognizer.recognitionTask(with: req, delegate: self)

        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in
            self.recognitionRequest?.append(buf)
        }

        audioEngine.prepare()
        try audioEngine.start()

        isRecognizing = true
        resetSilenceTimer()

        // ✅ 재시작 워밍업 기간 설정 (아래 3)에서 사용할 플래그)
        warmupUntil = Date().addingTimeInterval(0.35)
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
    private var warmupUntil: Date? = nil

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask,
                               didHypothesizeTranscription t: SFTranscription) {
        // ✅ 재시작 워밍업 시간 동안은 파셜 무시
        if let until = warmupUntil, Date() < until { return }
        self.recognizedText = t.formattedString
        resetSilenceTimer()
    }

    // MARK: - SFSpeechRecognitionTaskDelegate
    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didChange state: SFSpeechRecognitionTaskState) {
    }
    
    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didStartSpeechAt: Date) {
        resetSilenceTimer()
    }
    
    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSpeech: SFSpeechRecognitionResult) {
    }
    
    
    
    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        self.isSpeaking = false
        // ✅ 0.3~0.4초 뒤에 STT 재개
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            try? self.startRecognition()
        }
    }

    
    // MARK: - AVSpeechSynthesizerDelegate
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        self.isSpeaking = true
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
    private let serverURL = "http://fe18a029cc8f.ngrok-free.app"
    #else
    private let serverURL = "http://13.124.208.108:6490"
    #endif

    @Published var messages: [ChatMessage] = []
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    @Published var isChatActive: Bool = true
    @StateObject private var bannerCtrl = BannerAdController()   // ⬅️ 추가
    @Published var currentLevel: ChatLevel = .beginner   // ⬅️ 추가
    @Published var dailySentence: String = ""
    @Published var translation: String = ""   // ✅ 추가
    @Published var isDailyMode: Bool = false       // 오늘의 문장 대화 모드 여부



    // ✅ @Binding var selectedLevel: ChatLevel?       // ⬅️ 추가
    @State private var showLevelSelect = false   // ⬅️ 추가추가: 현재 진행 중인 채팅 세션
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
    
    func startChatWithDailySentence() {
        Task {
            await fetchDailySentence()
            guard !dailySentence.isEmpty else { return }

            self.isDailyMode = true
            self.currentSession = ChatSession(id: UUID(), startTime: Date(), messages: [])

            do {
                let url = URL(string: "\(serverURL)/chat/start_daily")!
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let body: [String: Any] = ["sentence": dailySentence, "level": currentLevel.rawValue]
                req.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (data, _) = try await URLSession.shared.data(for: req)
                let res = try JSONDecoder().decode(StartResponse.self, from: data)

                let msg = ChatMessage(role: "assistant", text: res.assistant_text)
                await MainActor.run {
                    self.messages.append(msg)
                    self.currentSession?.messages.append(msg)
                    self.audioController.speak(res.assistant_text)
                }
            } catch {
                print("❌ Failed to start daily chat: \(error)")
            }
        }
    }

    // ✅ ChatViewModel 내부에 DTO 추가
    private struct DailyReplyReqDTO: Codable {
        let history: [[String: String]]
        let user_text: String
        let sentence: String
        let level: String
    }

    private struct DailyReplyResDTO: Codable {
        let assistant_text: String
    }
    @MainActor
    func fetchDailySentence() async {
        do {
            guard let url = URL(string: "\(serverURL)/daily_sentence") else { return }
            let (data, _) = try await URLSession.shared.data(from: url)
            struct DailySentenceResponse: Codable { let date: String; let sentence: String; let translation: String }
            let decoded = try JSONDecoder().decode(DailySentenceResponse.self, from: data)
            self.dailySentence = decoded.sentence
        } catch {
            print("❌ Failed to fetch daily sentence: \(error)")
        }
    }

    // ✅ 오늘의 문장 학습용 reply
    func sendDailyReply(userText: String, sentence: String) {
        // 먼저 사용자 발화 UI에 반영
        let userMsg = ChatMessage(role: "user", text: userText)
        DispatchQueue.main.async {
            self.messages.append(userMsg)
            self.currentSession?.messages.append(userMsg)
            self.isLoading = true
            self.errorMessage = nil
        }

        Task {
            do {
                // 1) 히스토리 -> 서버 스키마([[String:String]])로 변환
                let historyPayload: [[String: String]] = self.messages
                    .filter { $0.role != "system" }
                    .map { ["role": $0.role, "text": $0.text] }

                // 2) 바디를 명시적 DTO로 생성 → 타입 모호성 제거
                let payload = DailyReplyReqDTO(
                    history: historyPayload,
                    user_text: userText,
                    sentence: sentence,
                    level: self.currentLevel.rawValue
                )
                let bodyData = try JSONEncoder().encode(payload)

                // 3) 요청
                guard let url = URL(string: "\(serverURL)/chat/daily_reply") else { return }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = bodyData

                let (data, _) = try await URLSession.shared.data(for: req)

                // 4) 응답 디코딩
                let res = try JSONDecoder().decode(DailyReplyResDTO.self, from: data)

                // 5) 어시스턴트 메시지 반영 + TTS
                let assistant = ChatMessage(role: "assistant", text: res.assistant_text)
                await MainActor.run {
                    self.messages.append(assistant)
                    self.currentSession?.messages.append(assistant)
                    self.isLoading = false
                    self.audioController.speak(assistant.text)
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.errorMessage = "Failed daily reply: \(error.localizedDescription)"
                }
                print("❌ Failed to send daily reply: \(error)")
            }
        }
    }

    // MARK: - 레벨 기반 시작
    func startChat(level: ChatLevel) {
        guard messages.isEmpty else { return }
        self.currentLevel = level
        self.currentSession = ChatSession(id: UUID(), startTime: Date(), messages: [])

        Task {
            await MainActor.run {
                self.isLoading = true
                self.errorMessage = nil
            }
            do {
                let url = URL(string: "\(serverURL)/chat/start")!
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let body = StartRequest(prompt: level.seedPrompt, level: level)
                req.httpBody = try JSONEncoder().encode(body)

                print("➡️ /chat/start\n\(req.curlString)")

                let t0 = Date()
                let (data, resp) = try await URLSession.shared.data(for: req)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)

                guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                print("⬅️ /chat/start [\(http.statusCode)] \(ms)ms CT=\(http.value(forHTTPHeaderField: "Content-Type") ?? "-") bytes=\(data.count)")
                if http.statusCode != 200 {
                    print("⛔️ RAW BODY:\n\(NetLog.prettyJSON(data))")
                    throw NSError(domain: "HTTP", code: http.statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
                }

                do {
                    let res = try JSONDecoder().decode(StartResponse.self, from: data)
                    print("✅ Decoded StartResponse: \(res.assistant_text)")
                    let msg = ChatMessage(role: "assistant", text: res.assistant_text)
                    await MainActor.run {
                        self.messages.append(msg)
                        self.currentSession?.messages.append(msg)
                        self.isLoading = false
                        self.audioController.speak(res.assistant_text)
                    }
                } catch {
                    print("❌ Decode StartResponse failed: \(NetLog.decodeErrorDescription(error, data: data))")
                    print("📦 RAW JSON:\n\(NetLog.prettyJSON(data))")
                    throw error
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.errorMessage = "Failed to start chat: \(error.localizedDescription)"
                }
            }
        }
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

        if isDailyMode {
            sendDailyReply(userText: text)   // ✅ 오늘의 문장 학습 흐름
            return
        }

        // ⬇️ 기존 일반 대화 흐름 (그대로 유지)
        let userMessage = ChatMessage(role: "user", text: text)
        DispatchQueue.main.async {
            self.messages.append(userMessage)
            self.currentSession?.messages.append(userMessage)
            self.isLoading = true
            self.errorMessage = nil
        }
        Task {
            do {
                let url = URL(string: "\(serverURL)/chat/reply")!
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let payload = ReplyRequest(history: history, user_text: userMessage.text, level: currentLevel)
                req.httpBody = try JSONEncoder().encode(payload)

                let (data, _) = try await URLSession.shared.data(for: req)
                let res = try JSONDecoder().decode(ReplyResponse.self, from: data)

                let assistant = ChatMessage(role: "assistant", text: res.assistant_text)
                await MainActor.run {
                    self.messages.append(assistant)
                    self.currentSession?.messages.append(assistant)
                    self.isLoading = false
                    self.audioController.speak(assistant.text)
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.errorMessage = "Failed to get AI response: \(error.localizedDescription)"
                }
            }
        }
    }

    private func sendDailyReply(userText: String) {
        let userMessage = ChatMessage(role: "user", text: userText)
        DispatchQueue.main.async {
            self.messages.append(userMessage)
            self.currentSession?.messages.append(userMessage)
            self.isLoading = true
            self.errorMessage = nil
        }

        Task {
            do {
                let url = URL(string: "\(serverURL)/chat/daily_reply")!
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")

                // 서버에 history를 Msg 배열 형식으로 넘김
                let msgHist = self.history.map { ["role": $0.role, "text": $0.text] }
                let body: [String: Any] = [
                    "history": msgHist,
                    "user_text": userText,
                    "sentence": self.dailySentence,
                    "level": self.currentLevel.rawValue
                ]
                req.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (data, _) = try await URLSession.shared.data(for: req)
                struct DailyReplyRes: Codable { let assistant_text: String }
                let res = try JSONDecoder().decode(DailyReplyRes.self, from: data)

                let assistant = ChatMessage(role: "assistant", text: res.assistant_text)
                await MainActor.run {
                    self.messages.append(assistant)
                    self.currentSession?.messages.append(assistant)
                    self.isLoading = false
                    self.audioController.speak(assistant.text)
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.errorMessage = "Failed daily reply: \(error.localizedDescription)"
                }
            }
        }
    }

    
    func endChat() {
        self.isChatActive = false
        self.isDailyMode = false           // ✅ 모드 리셋
        audioController.forceStopRecognition()
        self.messages.append(ChatMessage(role: "system", text: "대화가 종료되었습니다."))
    }

    
    func resumeChat() {
            // ✅ 기존 메시지 유지하고 대화만 다시 활성화
            self.isChatActive = true

            // ✅ 음성 인식 재시작 (새 /chat/start 호출 X)
            try? self.audioController.startRecognition()
        }
}



// MARK: - 5. Views (UI 컴포넌트)
// ✅ ChatView 전체 교체
struct ChatView: View {
    @StateObject private var viewModel = ChatViewModel()
    @Binding var showChatView: Bool
    @EnvironmentObject var historyManager: ChatHistoryManager
    @StateObject private var bannerCtrl = BannerAdController()   // ⬅️ 추가
    let mode: ChatMode               // ✅ level or dailySentence
    var onExit: (() -> Void)? = nil            // ⬅️ 추가




    // 타이머 상태
    @State private var elapsedSec = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private func fmt(_ sec: Int) -> String {
        let m = sec / 60, s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 상단 바
            HStack {
                //뒤로가기 버튼
                Button(action: {
                    // 나가기 전: 세션 저장(총 대화시간 포함) + 음성 중지
                    if var session = viewModel.currentSession, !session.messages.isEmpty {
                        session.totalSeconds = elapsedSec
                        viewModel.currentSession = session
                        historyManager.saveChatSession(session)
                    }
                    viewModel.audioController.stopSpeaking()
                    onExit?()                                  // ⬅️ 추가

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

                // 우측 상단 타이머 표시
                Text(fmt(elapsedSec))
                    .font(.footnote.monospacedDigit())
                    .foregroundColor(.secondary)
                    .padding(.trailing, 12)
            }
            .padding(.top)
            .padding(.bottom, 5)

            
            
            // ⬇️ 배너
            BannerAdView(controller: bannerCtrl)
                .frame(height: 50)
                .padding(.bottom, 6)
            // 메시지 리스트
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

            // 에러/로딩
            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .padding()
            }
            if viewModel.isLoading {
                ProgressView()
                    .padding()
            }

            // 하단 컨트롤 (X = 일시정지 / 재개)
            AudioControlView(viewModel: viewModel)
                .padding()
                .background(Color(.systemBackground))
        }
        // ChatView 안 onAppear 수정
        .onAppear {
            if viewModel.messages.isEmpty {
                switch mode {
                case .level(let lvl):
                    viewModel.startChat(level: lvl)
                case .dailySentence:
                    viewModel.startChatWithDailySentence()
                }
            } else {
                try? viewModel.audioController.startRecognition()
            }
        }


        .onDisappear {
            // 다른 화면으로 나갈 때는 TTS만 즉시 중지
            viewModel.audioController.stopSpeaking()
        }
        // 1초마다 경과시간 증가(대화 활성 상태에서만)
        .onReceive(timer) { _ in
            if viewModel.isChatActive {
                elapsedSec += 1
            }
        }
        // ❌ 재개 시 타이머를 리셋하는 코드(예: onChange에서 elapsedSec=0)는 두지 않습니다.
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
    @StateObject private var bannerCtrl = BannerAdController()   // ⬅️ 추가

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
            // ⬇️ 배너
                        BannerAdView(controller: bannerCtrl)
                            .frame(height: 50)
                            .padding(.bottom, 6)
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
// ✅ 세련 디자인 + 알람 5개 제한 팝업 포함 MainView (세션 목록은 별도 페이지로 이동)
struct MainView: View {
    @State private var selectedTab: AlarmType = .daily
    @State private var selectedTime = Date()
    @State private var selectedWeekdays: Set<Int> = []
    @State private var selectedInterval: Double = 30
    @StateObject private var bannerCtrl = BannerAdController()   // ⬅️ 추가
//    @Binding var selectedLevel: ChatLevel?       // ⬅️ 추가
//        @State private var showLevelSelect = false   // ⬅️ 추가
    var onTapStart: (() -> Void)? = nil        // ⬅️ 추가
    @StateObject private var sentenceVM = DailySentenceViewModel()



    @EnvironmentObject var historyManager: ChatHistoryManager
    @Binding var showChatView: Bool

    private let weekdays = ["일","월","화","수","목","금","토"]

    @State private var now = Date()
    private let minuteTicker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    @State private var showAlarmLimitAlert = false

    private func mmss(_ sec: Int) -> String {
        let m = sec / 60, s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.purple.opacity(0.25), Color.indigo.opacity(0.25)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            NavigationView {
                ScrollView {
                    VStack(spacing: 18) {

                        BannerAdView(controller: bannerCtrl)
                                                    .frame(height: 50) // 표준 320x50
                                                    .padding(.top, 6)
                        
                        // 상단 바: 타이틀 + [히스토리] [세션] 아이콘
                        HStack(spacing: 10) {
                            Text("English Bell")
                                .font(.largeTitle.bold())
                                .foregroundColor(.primary)

                            Spacer()


                            // ✅ 새로: 날짜 목록 페이지로 이동
                                NavigationLink {
                                    DatesListView()
                                } label: {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.title3.weight(.semibold))
                                        .foregroundColor(.purple)
                                        .padding(8)
                                        .background(Color.white.opacity(0.55), in: Circle())
                                }
                                .accessibilityLabel("날짜별 목록")
  
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 6)

                        // 카드 1: 탭 + 저장
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
                                    let ok = historyManager.addAlarm(alarm: newAlarm) // Bool 반환 필수
                                    if !ok { showAlarmLimitAlert = true }
                                } label: {
                                    Text("저장").font(.headline)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }

                        // 카드 2: 상세 설정
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

                        SectionCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("오늘의 문장")
                                    .font(.headline)

                                if sentenceVM.dailySentence.isEmpty {
                                    Text("불러오는 중...")
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("“\(sentenceVM.dailySentence)”")
                                        .font(.title3)
                                        .fontWeight(.semibold)
                                        .padding(.top, 4)
                                    Text(sentenceVM.translation)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .onAppear {
                            sentenceVM.fetchDailySentence()
                        }




                        // 대화하기 버튼
                        // 대화하기 버튼
                        Button {
                            onTapStart?()                              // ⬅️ 레벨 선택 띄우기 신호만 보냄
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
//                        // ⬇️ 레벨 선택 풀스크린
//                        .fullScreenCover(isPresented: $showLevelSelect) {
//                            LevelSelectView { level in
//                                self.selectedLevel = level
//                                self.showLevelSelect = false
//                                self.showChatView = true
//                            }
//                        }


                        // 오늘 진행
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
                        // ✅ 알람 저장 목록 카드 (오늘 대화 카드 아래에 추가)
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


                        // ✅ 하단 “대화 기록” 섹션은 제거됨 (SessionsListView로 이동)

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
            .navigationViewStyle(.stack)   // ✅ iPad에서도 단일 화면(스택)로 표시

        }
        .alert("저장할 수 없어요😂", isPresented: $showAlarmLimitAlert) {
            Button("확인", role: .cancel) { }
        } message: {
            Text("알람은 최대 5개까지 저장할 수 있어요.")
        }
    }
}

//
// MARK: - Reusable UI
//

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

fileprivate struct FlowWeekdays: View {
    let labels: [String]
    @Binding var selected: Set<Int>

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


// ✅ 새로 추가: 세션 목록 페이지 (뒤로가기 포함)
struct SessionsListView: View {
    @EnvironmentObject var historyManager: ChatHistoryManager
    @Environment(\.dismiss) var dismiss

    private func mmss(_ sec: Int) -> String {
        let m = sec / 60, s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.purple.opacity(0.9), Color.indigo.opacity(0.9)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // 상단 바
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

                    Text("세션 목록")
                        .font(.headline)
                        .foregroundColor(.white)

                    Spacer()

                    Color.clear.frame(width: 36, height: 36)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // 리스트 (최신 우선, 최대 5개는 저장 정책에 의해 자동 제한)
                List {
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
                            .padding(.vertical, 6)
                        }
                    }
                    .onDelete { indexSet in
                        indexSet.forEach { idx in
                            let id = historyManager.chatSessions[idx].id
                            historyManager.deleteChatSession(id: id)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationBarBackButtonHidden(true)
    }
}



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

// ✅ 교체: ChatHistoryManager (세션은 '최근 10일'만 유지, 하루 내 세션은 무제한)
class ChatHistoryManager: ObservableObject {
    private let chatSessionsKey = "savedChatSessions"
    private let keepDays = 10                          // ✅ 최근 10일 유지

    @Published var alarms: [Alarm] = []
    private let alarmsKey = "savedAlarms"

    @Published var chatSessions: [ChatSession] = []

    init() {
        loadAlarms()
        loadChatSessions()
    }

    // MARK: - Chat History Management
    func loadChatSessions() {
        if let savedSessions = UserDefaults.standard.data(forKey: chatSessionsKey),
           let decoded = try? JSONDecoder().decode([ChatSession].self, from: savedSessions) {
            self.chatSessions = decoded
        } else {
            self.chatSessions = []
        }
        pruneToLastDays() // ✅ 로드하면서 10일 이내만 남기기
        self.chatSessions.sort { $0.startTime > $1.startTime }
    }

    func saveChatSession(_ session: ChatSession) {
        if let idx = chatSessions.firstIndex(where: { $0.id == session.id }) {
            chatSessions[idx] = session
        } else {
            chatSessions.insert(session, at: 0) // 최신 먼저
        }
        pruneToLastDays() // ✅ 저장할 때마다 10일 초과분 제거
        persistChatSessions()
    }

    func deleteChatSession(id: UUID) {
        chatSessions.removeAll { $0.id == id }
        persistChatSessions()
    }

    private func persistChatSessions() {
        if let encoded = try? JSONEncoder().encode(chatSessions) {
            UserDefaults.standard.set(encoded, forKey: chatSessionsKey)
        }
    }

    /// ✅ 최근 10일만 남기기 (startOfDay 기준)
    private func pruneToLastDays() {
        let cal = Calendar.current
        let startToday = cal.startOfDay(for: Date())
        guard let cutoff = cal.date(byAdding: .day, value: -(keepDays - 1), to: startToday) else { return }
        chatSessions = chatSessions.filter { s in
            cal.startOfDay(for: s.startTime) >= cutoff
        }
    }

    // MARK: - Aggregations (오늘 합계 및 날짜별 합계)
    /// 특정 날짜(현지) 총 누적 초
    func seconds(for date: Date) -> Int {
        let cal = Calendar.current
        let sod = cal.startOfDay(for: date)
        let eod = cal.date(byAdding: .day, value: 1, to: sod)!
        return chatSessions.reduce(0) { acc, s in
            (s.startTime >= sod && s.startTime < eod) ? acc + (s.totalSeconds ?? 0) : acc
        }
    }

    /// 최근 10일의 날짜별 총합 (최신 날짜 우선)
    func dailyTotals() -> [(date: Date, seconds: Int)] {
        let cal = Calendar.current
        var bucket: [Date: Int] = [:] // key = startOfDay

        for s in chatSessions {
            let day = cal.startOfDay(for: s.startTime)
            bucket[day, default: 0] += (s.totalSeconds ?? 0)
        }
        // 이미 prune되어 10일 이내만 있음
        return bucket
            .map { ($0.key, $0.value) }
            .sorted { $0.0 > $1.0 }
    }

    /// 특정 날짜의 세션 리스트(최신 우선)
    func sessions(on date: Date) -> [ChatSession] {
        let cal = Calendar.current
        return chatSessions
            .filter { cal.isDate($0.startTime, inSameDayAs: date) }
            .sorted { $0.startTime > $1.startTime }
    }

    // MARK: - Alarm Management (기존 그대로)
    private func saveAlarms() {
        if let encoded = try? JSONEncoder().encode(alarms) {
            UserDefaults.standard.set(encoded, forKey: alarmsKey)
        }
    }

    private func loadAlarms() {
        if let savedAlarms = UserDefaults.standard.data(forKey: alarmsKey),
           let decoded = try? JSONDecoder().decode([Alarm].self, from: savedAlarms) {
            self.alarms = decoded
        } else {
            self.alarms = []
        }
    }

    /// ⚠️ addAlarm은 이전 답변처럼 Bool 반환으로 이미 바꿨다는 전제 (5개 제한 유지)
    func addAlarm(alarm: Alarm) -> Bool {
        guard alarms.count < 5 else { return false }
        var newAlarm = alarm
        if newAlarm.id.isEmpty { newAlarm.id = UUID().uuidString }
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
                UNUserNotificationCenter.current()
                    .removePendingNotificationRequests(withIdentifiers: [alarms[index].id])
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
            content.sound = alarmSounds.randomElement().map { UNNotificationSound(named: UNNotificationSoundName($0)) } ?? .default

            let hm = Calendar.current.dateComponents([.hour, .minute], from: alarm.time)
            for wd in alarm.weekdays {
                var dc = hm; dc.weekday = wd
                let trigger = UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)
                let id = "\(alarm.id)_w\(wd)"
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger)) { err in
                    if let err = err { print("주간 알람 스케줄 실패(\(wd)): \(err)") }
                }
            }

        case .daily, .interval:
            let request = alarm.createNotificationRequest()
            if request.trigger != nil {
                center.add(request) { error in
                    if let error = error { print("알림 스케줄링 실패: \(error.localizedDescription)") }
                }
            }
        }
    }
}
// ✅ 새 페이지 1: 날짜 목록 (최근 10일, 합계와 진행률 표시)
struct DatesListView: View {
    @EnvironmentObject var historyManager: ChatHistoryManager
    @Environment(\.dismiss) var dismiss

    @StateObject private var bannerCtrl = BannerAdController()   // ⬅️ 추가

    private func mmss(_ sec: Int) -> String {
        let m = sec / 60, s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.purple.opacity(0.9), Color.indigo.opacity(0.9)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // 상단 바
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.title3.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.white.opacity(0.15), in: Circle())
                    }
                    Spacer()
                    Text("날짜별 기록")
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                    Color.clear.frame(width: 36, height: 36)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // ⬇️ 배너 (상단 바 바로 아래)
                                BannerAdView(controller: bannerCtrl)
                                    .frame(height: 50)
                                    .padding(.bottom, 8)
                // 날짜 리스트
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(historyManager.dailyTotals(), id: \.date) { (day, seconds) in
                            let progress = min(Double(seconds) / 3600.0, 1.0)
                            NavigationLink {
                                SessionsByDateView(date: day)
                            } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
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
                        }

                        if historyManager.dailyTotals().isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "calendar.badge.clock")
                                    .font(.system(size: 42))
                                    .foregroundColor(.white.opacity(0.85))
                                Text("표시할 날짜가 없어요")
                                    .foregroundColor(.white.opacity(0.95))
                                Text("대화를 시작해 기록을 쌓아보세요!")
                                    .foregroundColor(.white.opacity(0.85))
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

// ✅ 새 페이지 2: 특정 날짜의 세션 목록
struct SessionsByDateView: View {
    let date: Date
    @EnvironmentObject var historyManager: ChatHistoryManager
    @Environment(\.dismiss) var dismiss
    @StateObject private var bannerCtrl = BannerAdController()   // ⬅️ 추가

    private func mmss(_ sec: Int) -> String {
        let m = sec / 60, s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.purple.opacity(0.9), Color.indigo.opacity(0.9)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // 상단 바
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.title3.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.white.opacity(0.15), in: Circle())
                    }
                    Spacer()
                    Text(date, format: .dateTime.year().month().day())
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                    Color.clear.frame(width: 36, height: 36)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
                // ⬇️ 배너
                                BannerAdView(controller: bannerCtrl)
                                    .frame(height: 50)
                                    .padding(.bottom, 8)
                // 세션 리스트
                List {
                    ForEach(historyManager.sessions(on: date)) { session in
                        NavigationLink(destination: DetailedChatView(session: session)) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(session.startTime, format: .dateTime.hour().minute())
                                    .font(.subheadline)
                                Text(mmss(session.totalSeconds ?? 0))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    .onDelete { indexSet in
                        indexSet.forEach { idx in
                            let id = historyManager.sessions(on: date)[idx].id
                            historyManager.deleteChatSession(id: id)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationBarBackButtonHidden(true)
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
//        GADMobileAds.sharedInstance().start(completionHandler: nil)

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
    @State private var selectedMode: ChatMode? = nil    // ✅ 변경
    @State private var showLevelSelect = false        // ⬅️ 레벨 선택을 최상위에서 관리
    

    var body: some View {
           ZStack {
               if showChatView {
                   ChatView(
                       showChatView: $showChatView,
                       mode: selectedMode ?? .level(.beginner),   // ✅ 기본값은 beginner
                       onExit: {
                           showLevelSelect = true   // 뒤로가기 → 레벨 선택 다시 열기
                       }
                   )
               } else {
                   MainView(
                    onTapStart: { showLevelSelect = true }, showChatView: $showChatView   // ✅ 레벨 선택 띄우기
                      )
               }
           }
           // ⬇️ 레벨 선택은 항상 최상위에서 띄움(메인/채팅과 독립)
           .fullScreenCover(isPresented: $showLevelSelect) {
               LevelSelectView { mode in
                   selectedMode = mode
                   showLevelSelect = false
                   showChatView = true                        // ⬅️ 선택 즉시 ChatView 진입
               }
           }
       }
}
