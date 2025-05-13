// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

fileprivate struct AdaptiveTextIdealWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .zero
    
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A component which will render the longest text value provided that will fit without truncating
///
/// **Note:** Before iOS 16 this will render _only_ the longest or shortest values
struct AdaptiveText: View {
    enum LoadingStyle {
        case progressView
        case text(String)
    }
    
    let textRepresentations: [(value: String, id: UUID)]
    let isLoading: Bool
    
    private var font: Font = .Body.baseRegular
    private var uiKitFont: UIFont = Fonts.Body.baseRegular
    @State private var foregroundColor: ThemeValue = .textPrimary
    @State private var loadingStyle: LoadingStyle = .progressView
    
    @State private var idealLongestTextWidth: CGFloat = .zero
    @State private var availableWidth: CGFloat = .zero

    private var useAbbreviatedForIOS15: Bool {
        guard idealLongestTextWidth > 0, availableWidth > 0 else { return false }
        
        return (idealLongestTextWidth > (availableWidth - 50.0))
    }
    
    init(
        text: String,
        isLoading: Bool = false
    ) {
        self.textRepresentations = [(text, UUID())]
        self.isLoading = isLoading
    }
    
    init(
        textOptions: [String],
        isLoading: Bool = false
    ) {
        self.textRepresentations = textOptions
            .sorted(by: { $0.count > $1.count })
            .map { ($0, UUID()) }
        self.isLoading = isLoading
    }
    
    var body: some View {
        ZStack {
            if isLoading {
                switch loadingStyle {
                    case .progressView: ProgressView()
                    case .text(let text): styledText(text).fixedSize(horizontal: true, vertical: true)
                }
            }
            else if textRepresentations.count <= 1 {
                styledText(textRepresentations.first?.value ?? "")
            }
            else {
                Group {
                    if #available(iOS 16.0, *) {
                        ViewThatFits(in: .horizontal) {
                            ForEach(textRepresentations, id: \.id) { text, _ in
                                styledText(text)
                            }
                        }
                    }
                    else {
                        let longestText: String = (textRepresentations.first?.value ?? "")
                        let shortestText: String = (textRepresentations.last?.value ?? "")
                        
                        styledText(useAbbreviatedForIOS15 ? longestText : shortestText)
                            .background(
                                GeometryReader { geometry in
                                    Color.clear
                                        .onAppear { self.availableWidth = geometry.size.width }
                                        .onChange(of: geometry.size.width) { newWidth in self.availableWidth = newWidth }
                                        .background(
                                            styledText(longestText)
                                                .fixedSize(horizontal: true, vertical: false)
                                                .background(
                                                    GeometryReader { innerProxy in
                                                        Color.clear
                                                            .preference(
                                                                key: AdaptiveTextIdealWidthPreferenceKey.self,
                                                                value: innerProxy.size.width
                                                            )
                                                    }
                                                )
                                                .hidden()
                                        )
                                }
                            )
                            .onPreferenceChange(AdaptiveTextIdealWidthPreferenceKey.self) { newIdealWidth in
                                /// Update the state, adding a small tolerance check to prevent potential minor floating point differences causing
                                /// excessive updates/loops
                                if abs(self.idealLongestTextWidth - newIdealWidth) > 1 {
                                    self.idealLongestTextWidth = newIdealWidth
                                }
                            }
                    }
                }
            }
        }
        .frame(height: calculateApproximateHeight())
        .clipped()
    }
    
    @ViewBuilder
    private func styledText(_ text: String) -> some View {
        Text(text)
            .font(font)
            .foregroundColor(themeColor: foregroundColor)
            .lineLimit(1)
    }
    
    private func calculateApproximateHeight() -> CGFloat {
        return uiKitFont.lineHeight + 4
    }
}

extension AdaptiveText {
    func font(_ font: Font, uiKit: UIFont) -> AdaptiveText {
        var view = self
        view.font = font
        view.uiKitFont = uiKit
        return view
    }

    func foregroundColor(themeColor: ThemeValue) -> AdaptiveText {
        var view = self
        view._foregroundColor = State(initialValue: themeColor)
        return view
    }
    
    func loadingStyle(_ style: LoadingStyle) -> AdaptiveText {
        var view = self
        view._loadingStyle = State(initialValue: style)
        return view
    }
}
