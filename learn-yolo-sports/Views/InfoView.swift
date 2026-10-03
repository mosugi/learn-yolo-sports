//
//  InfoView.swift
//  learn-yolo-sports
//
//  Created by mosugi on 2026/10/03.
//

import SwiftUI

// 情報表示用のビュー
struct InfoView: View {
    @State private var isAnimating = false
    @State private var textOpacity = 0.0
    @State private var scale = 0.5
    @State private var rotation = 0.0
    
    var body: some View {
        NavigationStack {
            ZStack {
                // グラデーション背景
                LinearGradient(
                    colors: [.purple, .blue, .pink],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                .hueRotation(.degrees(isAnimating ? 45 : 0))
                .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: isAnimating)
                
                VStack(spacing: 30) {
                    // アニメーションするスポーツアイコン
                    Image(systemName: "sportscourt.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, .cyan, .blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .rotationEffect(.degrees(rotation))
                        .shadow(color: .white.opacity(0.5), radius: 20)
                        .scaleEffect(scale)
                    
                    VStack(spacing: 10) {
                        Text("Sports")
                            .font(.system(size: 50, weight: .thin, design: .rounded))
                            .foregroundStyle(.white)
                            .opacity(textOpacity)
                        
                        Text("Analyzer")
                            .font(.system(size: 60, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.yellow, .orange, .pink],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .shadow(color: .pink.opacity(0.8), radius: 10, x: 0, y: 5)
                            .opacity(textOpacity)
                        
                        Text("YOLO Sports Edition")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                            .opacity(textOpacity)
                            .padding(.top, 5)
                    }
                    
                    // 装飾的なシンボル
                    HStack(spacing: 20) {
                        ForEach(0..<5) { index in
                            Circle()
                                .fill(.white.opacity(0.7))
                                .frame(width: 10, height: 10)
                                .scaleEffect(isAnimating ? 1.5 : 0.5)
                                .animation(
                                    .easeInOut(duration: 1)
                                        .repeatForever(autoreverses: true)
                                        .delay(Double(index) * 0.2),
                                    value: isAnimating
                                )
                        }
                    }
                }
            }
            .navigationTitle("アプリ情報")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // アイコンの回転とスケール
                withAnimation(.easeOut(duration: 1.5)) {
                    scale = 1.0
                }
                
                withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
                
                // テキストのフェードイン
                withAnimation(.easeIn(duration: 1.5).delay(0.5)) {
                    textOpacity = 1.0
                }
                
                // 背景とドットのアニメーション開始
                isAnimating = true
            }
        }
    }
}

#Preview {
    InfoView()
}
