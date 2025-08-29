////  ChatModule.swift
////  Add this as a new file to your iOS project.
//
//import SwiftUI
//import AVFoundation
//import os // ← 로그용
//
//// MARK: - Log Helper
//
//fileprivate struct ChatLog {
//    static let subsystem = "com.yourapp.SayEnglish"
//    static let api = Logger(subsystem: subsystem, category: "API")
//    static let store = Logger(subsystem: subsystem, category: "Store")
//    static let chat = Logger(subsystem: subsystem, category: "Chat")
//    static let tts = Logger(subsystem: subsystem, category: "TTS")
//
//    // iOS 14 미만 대응 (필요시)
//    static func fallback(_ items: Any...) {
//        #if DEBUG
//        print(items.map { "\($0)" }.joined(separator: " "))
//        #endif
//    }
//}
//
//// MARK: - Models
//
//enum ChatRole: String, Codable { case user, assistant }
//
//struct ChatMessage: Identifiable, Codable {
//    let id: UUID
//    let role: ChatRole
//    let text: String
//    let timestamp: Date
//
//    init(id: UUID = UUID(), role: ChatRole, text: String, timestamp: Date = .init()) {
//        self.id = id; self.role = role; self.text = text; self.timestamp = timestamp
//    }
//}
//
//struct ChatSession: Identifiable, Codable, Equatable {
//    let id: UUID
//    var startedAt: Date
//    var endedAt: Date?
//    var messages: [ChatMessage]
//    var topic: String?         // 대화 주제
//    var summary: String?       // 대화 요약
//
//    var durationSeconds: Int {
//        guard let end = endedAt else { return 0 }
//        return Int(end.timeIntervalSince(startedAt))
//    }
//
//    init(id: UUID = UUID(),
//         startedAt: Date = .init(),
//         endedAt: Date? = nil,
//         messages: [ChatMessage] = [],
//         topic: String? = nil,
//         summary: String? = nil) {
//        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt
//        self.messages = messages; self.topic = topic; self.summary = summary
//    }
//
//    // ✅ Equatable 직접 구현 → id만 비교
//    static func == (lhs: ChatSession, rhs: ChatSession) -> Bool {
//        lhs.id == rhs.id
//    }
//}
//
//
//// MARK: - Store (local persistence)
//
//@MainActor
//final class ChatStore: ObservableObject {
//    @Published var sessions: [ChatSession] = []
//
//    static let shared = ChatStore()
//    private let fileURL: URL = {
//        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
//        return dir.appendingPathComponent("chat_sessions.json")
//    }()
//
//    private init() { load() }
//
//    func load() {
//        do {
//            let data = try Data(contentsOf: fileURL)
//            let list = try JSONDecoder().decode([ChatSession].self, from: data)
//            self.sessions = list.sorted { $0.startedAt > $1.startedAt }
//            ChatLog.store.info("Loaded chat sessions: \(self.sessions.count, privacy: .public)")
//        } catch {
//            ChatLog.store.error("Load failed: \(error.localizedDescription, privacy: .public)")
//        }
//    }
//
//    func save() {
//        do {
//            let data = try JSONEncoder().encode(sessions)
//            try data.write(to: fileURL, options: .atomic)
//            ChatLog.store.info("Saved chat sessions: \(self.sessions.count, privacy: .public)")
//        } catch {
//            ChatLog.store.error("Save failed: \(error.localizedDescription, privacy: .public)")
//        }
//    }
//
//    func upsert(_ session: ChatSession) {
//        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
//            sessions[idx] = session
//            ChatLog.store.info("Upsert update id=\(session.id.uuidString, privacy: .public) messages=\(session.messages.count, privacy: .public)")
//        } else {
//            sessions.insert(session, at: 0)
//            ChatLog.store.info("Upsert insert id=\(session.id.uuidString, privacy: .public) messages=\(session.messages.count, privacy: .public)")
//        }
//        save()
//    }
//}
//
//// MARK: - API Client (FastAPI)
//
//struct APIClient {
//    var baseURL: URL
//
//    // kickoff: 앱이 먼저 AI에게 “유용한 표현 알려줄게, 같이 연습할래?” 묻기
//    func kickoff() async throws -> String {
//        let url = baseURL.appendingPathComponent("/chat/start")
//        var req = URLRequest(url: url)
//        req.httpMethod = "POST"
//        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
//        let body = ["prompt": "I'll teach you useful expressions Americans use. Want to practice with me?"]
//        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
//
//        ChatLog.api.info("POST /chat/start → \(url.absoluteString, privacy: .public)")
//        let t0 = Date()
//        let (data, resp) = try await URLSession.shared.data(for: req)
//        let ms = Int(Date().timeIntervalSince(t0)*1000)
//        if let http = resp as? HTTPURLResponse {
//            ChatLog.api.info("POST /chat/start status=\(http.statusCode) time=\(ms)ms bytes=\(data.count)")
//        }
//
//        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
//        let text = (obj?["assistant_text"] as? String) ?? "Let's practice some useful expressions. Ready?"
//        ChatLog.api.info("kickoff text len=\(text.count)")
//        return text
//    }
//
//    // 사용자 발화 보내고, AI 응답 받기
//    func send(messages: [ChatMessage], userText: String) async throws -> String {
//        let url = baseURL.appendingPathComponent("/chat/reply")
//        var req = URLRequest(url: url)
//        req.httpMethod = "POST"
//        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
//
//        let payload: [String: Any] = [
//            "history": messages.map { ["role": $0.role.rawValue, "text": $0.text] },
//            "user_text": userText
//        ]
//        req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
//
//        ChatLog.api.info("POST /chat/reply msgs=\(messages.count) userTextLen=\(userText.count)")
//        let t0 = Date()
//        let (data, resp) = try await URLSession.shared.data(for: req)
//        let ms = Int(Date().timeIntervalSince(t0)*1000)
//        if let http = resp as? HTTPURLResponse {
//            ChatLog.api.info("POST /chat/reply status=\(http.statusCode) time=\(ms)ms bytes=\(data.count)")
//        }
//
//        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
//        let text = (obj?["assistant_text"] as? String) ?? "Got it!"
//        ChatLog.api.info("reply text len=\(text.count)")
//        return text
//    }
//
//    // 세션 요약/주제 만들기
//    func summarize(messages: [ChatMessage]) async throws -> (topic: String, summary: String) {
//        let url = baseURL.appendingPathComponent("/chat/summarize")
//        var req = URLRequest(url: url)
//        req.httpMethod = "POST"
//        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
//        let body: [String: Any] = [
//            "history": messages.map { ["role": $0.role.rawValue, "text": $0.text] }
//        ]
//        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
//
//        ChatLog.api.info("POST /chat/summarize msgs=\(messages.count)")
//        let t0 = Date()
//        let (data, resp) = try await URLSession.shared.data(for: req)
//        let ms = Int(Date().timeIntervalSince(t0)*1000)
//        if let http = resp as? HTTPURLResponse {
//            ChatLog.api.info("POST /chat/summarize status=\(http.statusCode) time=\(ms)ms bytes=\(data.count)")
//        }
//
//        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
//        let topic = (obj?["topic"] as? String) ?? "English practice"
//        let summary = (obj?["summary"] as? String) ?? "Practice session"
//        ChatLog.api.info("summary topicLen=\(topic.count) summaryLen=\(summary.count)")
//        return (topic, summary)
//    }
//}
//
//// MARK: - Chat UI
//
//struct ChatScreen: View {
//    @Environment(\.dismiss) private var dismiss
//    @State private var session = ChatSession()
//    @State private var inputText = ""
//    @State private var tts = AVSpeechSynthesizer()
//    let api: APIClient
//
//    var body: some View {
//        VStack(spacing: 0) {
//            // Header
//            HStack {
//                Text("연습 대화").font(.headline)
//                Spacer()
//                Button {
//                    Task { await endConversation() }
//                } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
//            }
//            .padding()
//            .background(.ultraThinMaterial)
//
//            // Messages
//            ScrollViewReader { proxy in
//                ScrollView {
//                    LazyVStack(alignment: .leading, spacing: 10) {
//                        ForEach(session.messages) { msg in
//                            ChatBubble(message: msg)
//                                .id(msg.id)
//                        }
//                    }.padding(12)
//                }
//                .onChange(of: session.messages.count) { _ in
//                    if let last = session.messages.last {
//                        proxy.scrollTo(last.id, anchor: .bottom)
//                    }
//                }
//            }
//
//            // Input
//            HStack {
//                TextField("메시지 입력…", text: $inputText, axis: .vertical)
//                    .textFieldStyle(.roundedBorder)
//                Button {
//                    Task { await sendUser() }
//                } label: {
//                    Image(systemName: "paperplane.fill").padding(8)
//                }
//                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
//            }
//            .padding(.horizontal)
//            .padding(.vertical, 8)
//            .background(Color(.systemBackground))
//        }
//        .onAppear {
//            ChatLog.chat.info("ChatScreen appear — new session id=\(self.session.id.uuidString, privacy: .public)")
//            Task { await kickoff() }
//        }
//    }
//
//    // kickoff: 버튼 누르자마자 AI가 먼저 말 건 것처럼
//    private func kickoff() async {
//        do {
//            ChatLog.chat.info("kickoff start")
//            let aiText = try await api.kickoff()
//            appendAssistant(aiText)
//            speak(aiText)
//            ChatLog.chat.info("kickoff done textLen=\(aiText.count)")
//        } catch {
//            let fallback = "Let's practice some useful expressions. Ready?"
//            appendAssistant(fallback); speak(fallback)
//            ChatLog.chat.error("kickoff failed: \(error.localizedDescription, privacy: .public)")
//        }
//    }
//
//    private func sendUser() async {
//        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
//        guard !text.isEmpty else { return }
//        inputText = ""
//        appendUser(text)
//        ChatLog.chat.info("user -> \(text.count) chars")
//
//        do {
//            let aiText = try await api.send(messages: session.messages, userText: text)
//            appendAssistant(aiText)
//            speak(aiText)
//            ChatLog.chat.info("assistant <- \(aiText.count) chars")
//        } catch {
//            appendAssistant("Sorry—network issue. Try again.")
//            ChatLog.chat.error("send failed: \(error.localizedDescription, privacy: .public)")
//        }
//    }
//
//    private func endConversation() async {
//        session.endedAt = Date()
//        ChatLog.chat.info("endConversation start messages=\(session.messages.count)")
//        // 요약 생성
//        do {
//            let (topic, summary) = try await api.summarize(messages: session.messages)
//            session.topic = topic; session.summary = summary
//            ChatLog.chat.info("summary ok topicLen=\(topic.count) summaryLen=\(summary.count)")
//        } catch {
//            ChatLog.chat.error("summary failed: \(error.localizedDescription, privacy: .public)")
//        }
//        // 저장 & 닫기
//        ChatStore.shared.upsert(session)
//        ChatLog.chat.info("session saved id=\(session.id.uuidString, privacy: .public) dur=\(session.durationSeconds)s")
//        dismiss()
//    }
//
//    private func appendUser(_ text: String) {
//        session.messages.append(.init(role: .user, text: text))
//    }
//    private func appendAssistant(_ text: String) {
//        session.messages.append(.init(role: .assistant, text: text))
//    }
//    private func speak(_ text: String) {
//        do {
//            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
//            try AVAudioSession.sharedInstance().setActive(true)
//        } catch {
//            ChatLog.tts.error("AudioSession error: \(error.localizedDescription, privacy: .public)")
//        }
//        let u = AVSpeechUtterance(string: text)
//        u.voice = AVSpeechSynthesisVoice(language: "en-US")
//        u.rate = AVSpeechUtteranceDefaultSpeechRate
//        ChatLog.tts.info("Speak len=\(text.count)")
//        tts.speak(u)
//    }
//}
//
//struct ChatBubble: View {
//    let message: ChatMessage
//    var body: some View {
//        HStack {
//            if message.role == .assistant {
//                bubble(alignment: .leading,
//                       bg: Color(.secondarySystemBackground),
//                       fg: .primary,
//                       text: message.text)
//                Spacer(minLength: 40)
//            } else {
//                Spacer(minLength: 40)
//                bubble(alignment: .trailing,
//                       bg: Color.accentColor.opacity(0.2),
//                       fg: .primary,
//                       text: message.text)
//            }
//        }
//    }
//
//    private func bubble(alignment: HorizontalAlignment, bg: Color, fg: Color, text: String) -> some View {
//        VStack(alignment: alignment, spacing: 4) {
//            Text(text).foregroundColor(fg)
//                .padding(12)
//                .background(bg)
//                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
//        }
//    }
//}
//
//// MARK: - History
//
//struct ChatHistoryList: View {
//    @ObservedObject var store = ChatStore.shared
//    var body: some View {
//        List {
//            ForEach(store.sessions) { s in
//                NavigationLink {
//                    ChatHistoryDetail(session: s)
//                } label: {
//                    VStack(alignment: .leading, spacing: 4) {
//                        HStack {
//                            Text(s.topic ?? "영어 연습").font(.headline)
//                            Spacer()
//                            Text(Self.dateString(s.startedAt)).foregroundColor(.secondary)
//                        }
//                        Text("대화시간 \(Self.durationString(s.durationSeconds)) • \(s.summary ?? "요약 준비됨")")
//                            .foregroundColor(.secondary)
//                            .font(.subheadline)
//                            .lineLimit(2)
//                    }
//                }
//            }
//        }
//        .onAppear { ChatLog.store.info("HistoryList appear count=\(store.sessions.count)") }
//        .navigationTitle("대화 기록")
//    }
//
//    static func dateString(_ d: Date) -> String {
//        let f = DateFormatter(); f.locale = .init(identifier: "ko_KR"); f.dateFormat = "yyyy.MM.dd"
//        return f.string(from: d)
//    }
//    static func durationString(_ sec: Int) -> String {
//        let m = sec / 60, s = sec % 60
//        return String(format: "%d:%02d", m, s)
//    }
//}
//
//struct ChatHistoryDetail: View {
//    let session: ChatSession
//    var body: some View {
//        ScrollView {
//            LazyVStack(alignment: .leading, spacing: 10) {
//                ForEach(session.messages) { msg in
//                    ChatBubble(message: msg)
//                }
//            }.padding()
//        }
//        .onAppear { ChatLog.chat.info("HistoryDetail appear id=\(session.id.uuidString, privacy: .public) msgs=\(session.messages.count)") }
//        .navigationTitle(session.topic ?? "대화")
//    }
//}
