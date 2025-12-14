// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

struct ShineButton<Label>: View where Label: View {
    let action: () -> Void
    let label: () -> Label

    @State private var shineX: CGFloat = -1.5
    @State private var timer: Timer?

    var body: some View {
        Button(action: action) {
            ZStack {
                label()
                ShineOverlay(shineX: $shineX)
                    .allowsHitTesting(false)
                    .cornerRadius(6)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .onAppear {
            startAnimating()
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

    private func startAnimating() {
        shineX = -1.5
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.4, repeats: true) { _ in
            shineX = -1.5
            withAnimation(.linear(duration: 0.6)) {
                shineX = 1.5
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now()) {
            withAnimation(.linear(duration: 0.6)) {
                shineX = 1.5
            }
        }
    }
}

struct ShineOverlay: View {
    @Binding var shineX: CGFloat

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            Rectangle()
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.white.opacity(0),
                            Color.white.opacity(0.7),
                            Color.white.opacity(0)
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: width * 0.4, height: height)
                .offset(
                    x: shineX * width,
                    y: 0
                )
        }
        .clipped()
    }
}
