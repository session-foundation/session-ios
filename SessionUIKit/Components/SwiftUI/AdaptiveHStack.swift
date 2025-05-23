// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

fileprivate struct AdaptiveHStackMaxSpacingWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .zero
    
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct AdaptiveHStack<Content: View>: View {
    let alignment: VerticalAlignment
    let minSpacing: CGFloat?
    let maxSpacing: CGFloat?
    @ViewBuilder let content: () -> Content
    
    @State private var idealWidthWithMaxSpacing: CGFloat = .zero
    @State private var availableWidth: CGFloat = 0
    @State private var useMinSpacing: Bool = false
    
    init(
        alignment: VerticalAlignment = .center,
        minSpacing: CGFloat? = nil,
        maxSpacing: CGFloat? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.alignment = alignment
        self.content = content
        
        switch (minSpacing, maxSpacing) {
            case (.some(let minSpacing), .some(let maxSpacing)):
                self.minSpacing = min(minSpacing, maxSpacing)
                self.maxSpacing = max(minSpacing, maxSpacing)
                
            case (.some(let spacing), .none), (.none, .some(let spacing)):
                self.minSpacing = spacing
                self.maxSpacing = spacing
                
            case (.none, .none):
                self.minSpacing = nil
                self.maxSpacing = nil
        }
    }
    
    var body: some View {
        if #available(iOS 16.0, *) {
             // TODO: When minimum target is iOS 16+, consider replacing
             ios15Layout
                .fixedSize(horizontal: false, vertical: true)
        } else {
             ios15Layout
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    @ViewBuilder
    private var ios15Layout: some View {
        switch (minSpacing, maxSpacing) {
            case (.none, .none):
                HStack(alignment: alignment) {
                    content()
                }
                
            case (.some(let spacing), .none), (.none, .some(let spacing)):
                HStack(alignment: alignment, spacing: spacing) {
                    content()
                }
                
            case (.some(let minSpacing), .some(let maxSpacing)):
                HStack(
                    alignment: alignment,
                    spacing: (useMinSpacing ? minSpacing : maxSpacing)
                ) {
                    content()
                }
                .background(
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { updateAvailableWidth(geometry.size.width) }
                            .onChange(of: geometry.size.width) { updateAvailableWidth($0) }
                    }
                    .overlay(
                        HStack(alignment: alignment, spacing: maxSpacing) {
                            content()
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .background(
                            GeometryReader { innerProxy in
                                Color.clear
                                    .preference(
                                        key: AdaptiveHStackMaxSpacingWidthPreferenceKey.self,
                                        value: innerProxy.size.width
                                    )
                            }
                        )
                        .hidden()
                    )
                    .onPreferenceChange(AdaptiveHStackMaxSpacingWidthPreferenceKey.self) { newIdealWidth in
                        if self.idealWidthWithMaxSpacing != newIdealWidth {
                            self.idealWidthWithMaxSpacing = newIdealWidth
                            self.updateSpacingDecision()
                        }
                    }
                )
        }
    }
    
    private func updateAvailableWidth(_ width: CGFloat) {
        if abs(availableWidth - width) > 0.1 {
            availableWidth = width
            
            if minSpacing != nil && maxSpacing != nil && minSpacing != maxSpacing {
                updateSpacingDecision()
            }
        }
    }

    private func updateSpacingDecision() {
        guard idealWidthWithMaxSpacing > 0, availableWidth > 0 else {
            if useMinSpacing != false {
                useMinSpacing = false
            }
            return
        }

        let shouldUseMin: Bool = (idealWidthWithMaxSpacing >= availableWidth)

        if useMinSpacing != shouldUseMin {
            useMinSpacing = shouldUseMin
        }
    }
}
