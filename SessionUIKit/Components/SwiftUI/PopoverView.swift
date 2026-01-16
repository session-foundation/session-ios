// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SwiftUI

struct PopoverViewModifier<ContentView>: ViewModifier where ContentView: View {
    var contentView: () -> ContentView
    var backgroundThemeColor: ThemeValue
    @Binding var show: Bool
    var position: ViewPosition
    var offset: CGFloat
    var viewId: String

    // Measure the popover content locally so callers don't have to.
    @State private var popoverSize: CGSize = .zero
    
    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(PopoverViewOriginPreferenceKey.self) { preferences in
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        self.popoverView(
                            geometry: geometry,
                            preferences: preferences,
                            content: self.contentView,
                            isPresented: self.$show,
                            backgroundThemeColor: self.backgroundThemeColor,
                            position: self.position,
                            offset: offset,
                            viewId: self.viewId
                        )
                    }
                }
            }
    }
    
    internal func popoverView<PopoverContentView: View>(
        geometry: GeometryProxy?,
        preferences: [PopoverViewOriginPreference],
        @ViewBuilder content: @escaping (() -> PopoverContentView),
        isPresented: Binding<Bool>,
        backgroundThemeColor: ThemeValue,
        position: ViewPosition,
        offset: CGFloat,
        viewId: String
    ) -> some View {
        var originBounds = CGRect.zero
        if let originPreference = preferences.first(where: { $0.viewId == viewId }), let geometry = geometry {
           originBounds = geometry[originPreference.bounds]
        }
        return withAnimation {
            content()
                .background {
                    ArrowCapsule(
                        arrowPosition: position.opposite,
                        arrowLength: 10,
                        arrowOffset: offset
                    )
                    .fill(themeColor: backgroundThemeColor)
                    .shadow(color: .black.opacity(0.35), radius: 4)
                }
                .background(
                    // Measure the rendered content size.
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { popoverSize = geo.size }
                            .onChange(of: geo.size) { newSize in
                                if popoverSize != newSize {
                                    popoverSize = newSize
                                }
                            }
                    }
                )
                .opacity(isPresented.wrappedValue ? 1 : 0)
                .modifier(
                    PopoverOffset(
                        viewSize: popoverSize,
                        originBounds: originBounds,
                        position: position,
                        offset: offset,
                        arrowLength: 10
                    )
                )
        }
    }
}

internal struct PopoverOffset: ViewModifier {
    var viewSize: CGSize
    var originBounds: CGRect
    var position: ViewPosition
    var offset: CGFloat
    var arrowLength: CGFloat

    func body(content: Content) -> some View {
        content
            .offset(
                x: self.offsetXFor(
                    position: position,
                    offset: offset,
                    size: viewSize,
                    originBounds: originBounds,
                    arrowLength: arrowLength
                ),
                y: self.offsetYFor(
                    position: position,
                    size: viewSize,
                    originBounds: originBounds,
                    arrowLength: arrowLength
                )
            )
    }

    func offsetXFor(position: ViewPosition, offset: CGFloat, size: CGSize, originBounds: CGRect, arrowLength: CGFloat) -> CGFloat {
        let triangleSideLength: CGFloat = arrowLength / CGFloat(sqrt(0.75))
        let arrowOffSet: CGFloat = offset - triangleSideLength + size.height / 2
        switch position {
            case .top, .bottom:
                // Center horizontally
                return originBounds.minX + (originBounds.size.width  - size.width) / 2
            case .topLeft, .bottomLeft:
                // Align right
                return originBounds.maxX - size.width + arrowOffSet - triangleSideLength / 2
            case .topRight, .bottomRight:
                // Align left
                return originBounds.minX - arrowOffSet
            case .none:
                return 0
        }
    }

    func offsetYFor(position: ViewPosition, size: CGSize, originBounds: CGRect, arrowLength: CGFloat) -> CGFloat {
        switch position {
            case .top, .topLeft, .topRight:
                // Position above origin + arrow
                return originBounds.minY - size.height - arrowLength
            case .bottom, .bottomLeft, .bottomRight:
                // Position below origin + arrow
                return originBounds.maxY + arrowLength
            case .none:
                return 0
        }
    }
}


public struct AnchorView: ViewModifier {
    let viewId: String

    public func body(content: Content) -> some View {
        content.anchorPreference(key: PopoverViewOriginPreferenceKey.self, value: .bounds) {  [PopoverViewOriginPreference(viewId: self.viewId, bounds: $0)]}
    }
}

public extension View {
    func anchorView(viewId: String)-> some View {
        self.modifier(AnchorView(viewId: viewId))
    }
}

public extension View {
    func popoverView<ContentView: View>(
        content: @escaping () -> ContentView,
        backgroundThemeColor: ThemeValue,
        isPresented: Binding<Bool>,
        position: ViewPosition,
        offset: CGFloat = 30,
        viewId: String
    ) -> some View {
        self.modifier(
            PopoverViewModifier(
                contentView: content,
                backgroundThemeColor: backgroundThemeColor,
                show: isPresented,
                position: position,
                offset: offset,
                viewId: viewId
            )
        )
    }
}

// MARK: - PopoverViewOriginBoundsPreferenceKey

struct PopoverViewOriginPreferenceKey: PreferenceKey {
    ///PopoverViewOriginPreferenceKey initializer.
    init() {}
    ///PopoverViewOriginPreferenceKey value array
    typealias Value = [PopoverViewOriginPreference]
    ///PopoverViewOriginPreferenceKey default value array
    static var defaultValue: [PopoverViewOriginPreference] = []
    ///PopoverViewOriginPreferenceKey reduce function. modifies the sequence by adding a new value if needed.
    static func reduce(value: inout [PopoverViewOriginPreference], nextValue: () -> [PopoverViewOriginPreference]) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - PopoverViewOriginPreference: holds an identifier for the origin view  of the popover and its bounds anchor.

struct PopoverViewOriginPreference  {
    ///PopoverViewOriginPreference initializer
    init(viewId: String, bounds: Anchor<CGRect>) {
        self.viewId  = viewId
        self.bounds = bounds
    }
    ///popover origin view identifier.
    var viewId: String
    /// popover origin view bounds Anchor.
    var bounds: Anchor<CGRect>
}
