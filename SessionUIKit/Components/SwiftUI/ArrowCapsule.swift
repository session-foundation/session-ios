// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SwiftUI

public enum ViewPosition: String, Sendable {
    case top
    case bottom
    case none
    
    var opposite: ViewPosition {
        switch self {
            case .top: return .bottom
            case .bottom: return .top
            default: return .none
        }
    }
}

struct ArrowCapsule: Shape {
    let arrowPosition: ViewPosition
    let arrowLength: CGFloat

    func path(in rect: CGRect) -> Path {
        let height = rect.size.height
        
        let maxX = rect.maxX
        let minX = rect.minX
        let maxY = rect.maxY
        let minY = rect.minY

        let triangleSideLength : CGFloat = arrowLength / CGFloat(sqrt(0.75))
        let actualArrowPosition: ViewPosition = self.arrowLength > 0  ? self.arrowPosition : .none

        var path = Path()
        path.move(to: CGPoint(x: minX + height/2, y: minY))

        if actualArrowPosition == .top {
            path = self.makeArrow(path: &path, rect:rect, triangleSideLength: triangleSideLength, position: actualArrowPosition)
        }
        path.addLine(to: CGPoint(x: maxX - height/2, y: minY))
        path.addArc(
            center: CGPoint(x: maxX - height/2, y: minY + height/2),
            radius: height/2,
            startAngle: Angle(degrees: -90),
            endAngle: Angle(degrees: 90),
            clockwise: false
        )
        if actualArrowPosition == .bottom {
            path = self.makeArrow(path: &path, rect:rect, triangleSideLength: triangleSideLength, position: actualArrowPosition)
        }
        path.addLine(to: CGPoint(x: minX + height/2, y: maxY))
        path.addArc(
            center: CGPoint(x: minX + height/2, y: maxY - height/2),
            radius: height/2,
            startAngle: Angle(degrees: 90),
            endAngle: Angle(degrees: 270),
            clockwise: false
        )
        return path
    }

    func trianglePointsFor(arrowPosition: ViewPosition, rect: CGRect, triangleSideLength: CGFloat) -> (CGPoint, CGPoint, CGPoint) {
        switch arrowPosition {
            case .top:
                return (
                    CGPoint(x: rect.midX - triangleSideLength / 2 , y: rect.minY),
                    CGPoint(x: rect.midX, y: rect.minY - arrowLength),
                    CGPoint(x: rect.midX + triangleSideLength / 2, y: rect.minY)
                )
            case .bottom:
                return (
                    CGPoint(x: rect.midX + triangleSideLength / 2 , y: rect.maxY),
                    CGPoint(x: rect.midX, y: rect.maxY + arrowLength),
                    CGPoint(x: rect.midX - triangleSideLength / 2, y: rect.maxY)
                )
            default:
                return (
                    CGPoint.zero,
                    CGPoint.zero,
                    CGPoint.zero
                )
        }
    }
    
    func makeArrow(path: inout Path, rect: CGRect, triangleSideLength: CGFloat, position: ViewPosition) -> Path {
        let points = self.trianglePointsFor(
            arrowPosition: position,
            rect: rect,
            triangleSideLength: triangleSideLength
        )
        
        path.addLine(to: points.0)
        path.addLine(to: points.1)
        path.addLine(to: points.2)
        
        return path
    }
}
