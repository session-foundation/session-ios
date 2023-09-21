// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct ActivityIndicator: View {
    @State private var isAnimating: Bool = false

    public var body: some View {
        GeometryReader { (geometry: GeometryProxy) in
            Circle()
                .trim(from: 0, to: 0.9)
                .stroke(
                    themeColor: .borderSeparator,
                    style: StrokeStyle(
                        lineWidth: 2,
                        lineCap: .round
                    )
                )
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height
                )
                .
                .rotationEffect(!self.isAnimating ? .degrees(0) : .degrees(360))
                .animation(Animation
                    .timingCurve(0.5, 1, 0.25, 1, duration: 1.5)
                    .repeatForever(autoreverses: false)
                )
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear {
            self.isAnimating = true
        }
    }
}

