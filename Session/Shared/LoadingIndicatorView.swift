// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct ActivityIndicator: View {
    @State private var trimTo: Double = 0.05
    @State private var shorten: Bool = false
    @State private var rotation: Double = 0

    public var body: some View {
        GeometryReader { (geometry: GeometryProxy) in
            Circle()
                .trim(from: 0, to: trimTo)
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
                .rotationEffect(.degrees(rotation))
                .animation(
                    Animation.timingCurve(0.5, 1, 0.25, 1, duration: 1.5),
                    value: self.shorten
                )
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear {
            Timer.scheduledTimerOnMainThread(withTimeInterval: 1.5, repeats: true) { _ in
                if self.shorten {
                    self.trimTo = 0.05
                    self.rotation += 540
                } else {
                    self.trimTo = 0.95
                    self.rotation += 180
                }
                
                self.shorten = !self.shorten
            }
        }
    }
}

struct ActivityIndicator_Previews: PreviewProvider {
    static var previews: some View {
        ActivityIndicator()
            .foregroundColor(.black)
            .frame(
                width: 24,
                height: 24
            )
    }
}


