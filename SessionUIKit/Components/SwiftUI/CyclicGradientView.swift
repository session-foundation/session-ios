import SwiftUI

struct CyclicGradientView<Content>: View where Content: View {
    @State private var phase: CGFloat = 0
    private let colors: [Color] = [
        Theme.PrimaryColor.green.colorSwiftUI,
        Theme.PrimaryColor.blue.colorSwiftUI,
        Theme.PrimaryColor.purple.colorSwiftUI,
        Theme.PrimaryColor.pink.colorSwiftUI,
        Theme.PrimaryColor.red.colorSwiftUI,
        Theme.PrimaryColor.orange.colorSwiftUI,
        Theme.PrimaryColor.yellow.colorSwiftUI
    ]
    
    var duration: Double { 0.25 * Double(colors.count)}

    let content: () -> Content

    var body: some View {
        content()
            .overlay(
                TimelineView(.animation) { timeline in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    let phase = CGFloat((now / duration).truncatingRemainder(dividingBy: 1.0))

                    ZStack {
                        Canvas { context, size in
                            let stops = Array(colors + colors)
                            let offset = phase * size.height
                            context.withCGContext { cg in
                                let rect = CGRect(origin: .zero, size: size)
                                let cgGrad = CGGradient(
                                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: stops.map { UIColor($0).cgColor } as CFArray,
                                    locations: (0...stops.count-1).map { CGFloat($0)/CGFloat(stops.count-1) }
                                )!
                                cg.saveGState()
                                cg.addRect(rect)
                                cg.clip()
                                cg.drawLinearGradient(
                                    cgGrad,
                                    start: CGPoint(x: 0, y: -offset),
                                    end: CGPoint(x: 0, y: size.height - offset),
                                    options: []
                                )
                                cg.drawLinearGradient(
                                    cgGrad,
                                    start: CGPoint(x: 0, y: size.height - offset),
                                    end: CGPoint(x: 0, y: 2 * size.height - offset),
                                    options: []
                                )
                                cg.restoreGState()
                            }
                        }
                    }
                }
            )
            .mask(content())
    }
}
