// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct SessionCarouselView_SwiftUI: View {
    @State var index = 0

    var colors: [Color]
    
    public init(colors: [Color]) {
        self.colors = colors
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            ArrowView(value: $index.animation(.easeInOut), range: 0...(colors.count - 1), type: .decrement)
                .zIndex(1)
            
            PageView(index: $index.animation(), maxIndex: colors.count - 1) {
                ForEach(self.colors, id: \.self) { color in
                    Rectangle()
                        .foregroundColor(color)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            
            ArrowView(value: $index.animation(.easeInOut), range: 0...(colors.count - 1), type: .increment)
                .zIndex(1)
        }
    }
}

struct ArrowView: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let type: ArrowType
    
    enum ArrowType {
        case increment
        case decrement
    }
    
    init(value: Binding<Int>, range: ClosedRange<Int>, type: ArrowType) {
        self._value = value
        self.range = range
        self.type = type
    }
    
    var body: some View {
        let imageName = self.type == .decrement ? "chevron.left" : "chevron.right"
        Button {
            print("Tap")
            if self.type == .decrement {
                decrement()
            } else {
                increment()
            }
        } label: {
            Image(systemName: imageName)
                .foregroundColor(.white)
                .frame(width: 30, height: 30)
        }
    }
    
    func decrement() {
        if value > range.lowerBound {
            value -= 1
        }
        if value < range.lowerBound {
            value = range.lowerBound
        }
    }
    
    func increment() {
        if value < range.upperBound {
            value += 1
        }
        if value > range.upperBound {
            value = range.upperBound
        }
    }
}

struct PageView<Content>: View where Content: View {
    @Binding var index: Int
    let maxIndex: Int
    let content: () -> Content

    @State private var offset = CGFloat.zero
    @State private var dragging = false

    init(index: Binding<Int>, maxIndex: Int, @ViewBuilder content: @escaping () -> Content) {
        self._index = index
        self.maxIndex = maxIndex
        self.content = content
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        self.content()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                .content.offset(x: self.offset(in: geometry), y: 0)
                .frame(width: geometry.size.width, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 15))
                .gesture(
                    DragGesture(coordinateSpace: .local)
                        .onChanged { value in
                            self.dragging = true
                            self.offset = -CGFloat(self.index) * geometry.size.width + value.translation.width
                        }
                        .onEnded { value in
                            let predictedEndOffset = -CGFloat(self.index) * geometry.size.width + value.predictedEndTranslation.width
                            let predictedIndex = Int(round(predictedEndOffset / -geometry.size.width))
                            self.index = self.clampedIndex(from: predictedIndex)
                            withAnimation(.easeOut) {
                                self.dragging = false
                            }
                        }
                )
            }
            .clipped()

            PageControl(index: $index, maxIndex: maxIndex)
                .padding(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
        }
    }

    func offset(in geometry: GeometryProxy) -> CGFloat {
        if self.dragging {
            return max(min(self.offset, 0), -CGFloat(self.maxIndex) * geometry.size.width)
        } else {
            return -CGFloat(self.index) * geometry.size.width
        }
    }

    func clampedIndex(from predictedIndex: Int) -> Int {
        let newIndex = min(max(predictedIndex, self.index - 1), self.index + 1)
        guard newIndex >= 0 else { return 0 }
        guard newIndex <= maxIndex else { return maxIndex }
        return newIndex
    }
}

struct PageControl: View {
    @Binding var index: Int
    let maxIndex: Int

    var body: some View {
        ZStack {
            Capsule()
                .foregroundColor(.init(white: 0, opacity: 0.4))
            HStack(spacing: 4) {
                ForEach(0...maxIndex, id: \.self) { index in
                    Circle()
                        .fill(index == self.index ? Color.white : Color.gray)
                        .frame(width: 6.62, height: 6.62)
                }
            }
            .padding(6)
        }
        .fixedSize(horizontal: true, vertical: true)
        .frame(
            maxWidth: .infinity,
            maxHeight: 19
        )
    }
}

struct SessionCarouselView_SwiftUI_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            if #available(iOS 14.0, *) {
                Color.black.ignoresSafeArea()
            } else {
                Color.black
            }
            
            SessionCarouselView_SwiftUI(colors: [.red, .orange, .blue])
        }
    }
}
