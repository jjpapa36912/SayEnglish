
import Foundation
import SwiftUI

struct LevelSelectView: View {
    var onPick: (ChatMode) -> Void
    @Environment(\.dismiss) var dismiss
    @StateObject private var bannerCtrl = BannerAdController()

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
                    Text("레벨 선택")
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                    Color.clear.frame(width: 36, height: 36)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // 배너
                BannerAdView(controller: bannerCtrl)
                    .frame(height: 50)
                    .padding(.bottom, 10)

                // 레벨 카드 3개
                VStack(spacing: 20) {
                            // 기존 3개 레벨
                            LevelCard(level: .beginner) { onPick(.level(.beginner)) }
                            LevelCard(level: .intermediate) { onPick(.level(.intermediate)) }
                            LevelCard(level: .advanced) { onPick(.level(.advanced)) }

                            // 오늘의 문장 카드
                            Button {
                                onPick(.dailySentence)
                            } label: {
                                HStack {
                                    Text("📝 오늘의 문장으로 대화하기")
                                        .font(.headline)
                                    Spacer()
                                    Text("매일 자정 업데이트")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                .padding()
                                .background(
                                    RoundedRectangle(cornerRadius: 16).fill(.thinMaterial)
                                )
                            }

                        }
                        .padding()
                Spacer(minLength: 20)
            }
        }
        .navigationBarBackButtonHidden(true)
    }
}

fileprivate struct LevelCard: View {
    let level: ChatLevel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 14) {
                Text(level.emoji).font(.system(size: 28))
                VStack(alignment: .leading, spacing: 4) {
                    Text(level.title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(level.subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.thinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                    )
            )
            .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }
}
