//
//  Model.swift
//  SayEnglish
//
//  Created by 김동준 on 9/6/25.
//

import Foundation
struct DailySentence: Codable {
    let date: String
    let sentence: String
}
enum ChatMode {
    case level(ChatLevel)     // beginner / intermediate / advanced
    case dailySentence        // 오늘의 문장 모드
}

import Foundation
@MainActor
class DailySentenceViewModel: ObservableObject {
    @Published var dailySentence: String = ""
    @Published var translation: String = ""

    #if DEBUG
    private let serverURL = "http://fe18a029cc8f.ngrok-free.app"
    #else
    private let serverURL = "http://13.124.208.108:6490"
    #endif
    
    // DailySentenceViewModel 내부

    private let lastDateKey = "dailySentence.lastDate"

    private func todayString() -> String {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }

    /// ✅ 새로 추가: 날짜가 바뀌었으면 서버에서 새로 가져오기
    @MainActor
    func refreshIfDateChanged() async {
        let today = todayString()
        let cached = UserDefaults.standard.string(forKey: lastDateKey)

        // 이미 오늘 것이 로드돼 있으면 스킵
        if cached == today, !dailySentence.isEmpty { return }

        await fetchDailySentence(force: true)
    }

    /// 기존 fetchDailySentence 보강:
    /// - 서버 응답의 date를 저장해 두고
    /// - translation도 함께 반영
    @MainActor
    func fetchDailySentence(force: Bool = false) async {
        do {
            guard let url = URL(string: "\(serverURL)/daily_sentence") else { return }
            let (data, _) = try await URLSession.shared.data(from: url)

            struct DailySentenceResponse: Codable {
                let date: String
                let sentence: String
                let translation: String
            }
            let decoded = try JSONDecoder().decode(DailySentenceResponse.self, from: data)

            self.dailySentence = decoded.sentence
            self.translation = decoded.translation     // ✅ 번역까지 표시
            UserDefaults.standard.set(decoded.date, forKey: lastDateKey)  // ✅ 날짜 저장
        } catch {
            print("❌ Failed to fetch daily sentence: \(error)")
        }
    }

    
    
}


struct DailySentenceResponse: Codable {
    let date: String
    let sentence: String
    let translation: String
}

