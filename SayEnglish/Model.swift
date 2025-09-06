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
    func fetchDailySentence() {
        Task {
            do {
                guard let url = URL(string: "\(serverURL)/daily_sentence") else { return }
                let (data, _) = try await URLSession.shared.data(from: url)
                let decoded = try JSONDecoder().decode(DailySentenceResponse.self, from: data)
                self.dailySentence = decoded.sentence
                self.translation = decoded.translation
            } catch {
                print("❌ Failed to fetch daily sentence: \(error)")
            }
        }
    }
}


struct DailySentenceResponse: Codable {
    let date: String
    let sentence: String
    let translation: String
}

