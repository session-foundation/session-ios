// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SwiftUI

public enum ViewPosition: String, Sendable {
    case top
    case bottom
    case none
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var opposite: ViewPosition {
        switch self {
            case .top: return .bottom
            case .bottom: return .top
            case .topLeft: return .bottomRight
            case .topRight: return .bottomLeft
            case .bottomLeft: return .topRight
            case .bottomRight: return .topLeft
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
        let arrowOffSet: CGFloat = 30 - triangleSideLength + height / 2

        var path = Path()
        // 1. Start at top-left arc start point
        path.move(to: CGPoint(x: minX + height / 2, y: minY))

        // 2. Top edge (arrow if needed)
        if actualArrowPosition == .topLeft {
            path.addLine(to: CGPoint(x: minX + arrowOffSet, y: minY))
            path = self.makeArrow(path: &path, rect: rect, triangleSideLength: triangleSideLength, offset: arrowOffSet, position: .topLeft)
        } else if actualArrowPosition == .topRight {
            path.addLine(to: CGPoint(x: maxX - arrowOffSet - triangleSideLength, y: minY))
            path = self.makeArrow(path: &path, rect: rect, triangleSideLength: triangleSideLength, offset: arrowOffSet,position: .topRight)
        } else if actualArrowPosition == .top {
            path.addLine(to: CGPoint(x: rect.midX - triangleSideLength / 2, y: minY))
            path = self.makeArrow(path: &path, rect: rect, triangleSideLength: triangleSideLength, offset: arrowOffSet,position: .top)
        }
        path.addLine(to: CGPoint(x: maxX - height / 2, y: minY))

        // 3. Right corner
        path.addArc(
            center: CGPoint(x: maxX - height / 2, y: minY + height / 2),
            radius: height / 2,
            startAngle: Angle(degrees: -90),
            endAngle: Angle(degrees: 90),
            clockwise: false
        )

        // 4. Bottom edge (arrow if needed)
        if actualArrowPosition == .bottomRight {
            path.addLine(to: CGPoint(x: maxX - arrowOffSet, y: maxY))
            path = self.makeArrow(path: &path, rect: rect, triangleSideLength: triangleSideLength, offset: arrowOffSet,position: .bottomRight)
        } else if actualArrowPosition == .bottomLeft {
            path.addLine(to: CGPoint(x: minX + arrowOffSet + triangleSideLength, y: maxY))
            path = self.makeArrow(path: &path, rect: rect, triangleSideLength: triangleSideLength, offset: arrowOffSet,position: .bottomLeft)
        } else if actualArrowPosition == .bottom {
            path.addLine(to: CGPoint(x: rect.midX + triangleSideLength / 2, y: maxY))
            path = self.makeArrow(path: &path, rect: rect, triangleSideLength: triangleSideLength, offset: arrowOffSet,position: .bottom)
        }
        path.addLine(to: CGPoint(x: minX + height / 2, y: maxY))

        // 5. Left corner
        path.addArc(
            center: CGPoint(x: minX + height / 2, y: maxY - height / 2),
            radius: height / 2,
            startAngle: Angle(degrees: 90),
            endAngle: Angle(degrees: 270),
            clockwise: false
        )

        return path
    }

    func trianglePointsFor(arrowPosition: ViewPosition, rect: CGRect, triangleSideLength: CGFloat, offset: CGFloat) -> (CGPoint, CGPoint, CGPoint) {
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
            case .topLeft:
                return (
                    CGPoint(x: rect.minX + offset, y: rect.minY),
                    CGPoint(x: rect.minX + offset + triangleSideLength / 2, y: rect.minY - arrowLength),
                    CGPoint(x: rect.minX + offset + triangleSideLength, y: rect.minY)
                )
            case .topRight:
                return (
                    CGPoint(x: rect.maxX - offset - triangleSideLength, y: rect.minY),
                    CGPoint(x: rect.maxX - offset - triangleSideLength / 2, y: rect.minY - arrowLength),
                    CGPoint(x: rect.maxX - offset, y: rect.minY)
                )
            case .bottomLeft:
                return (
                    CGPoint(x: rect.minX + offset + triangleSideLength, y: rect.maxY),
                    CGPoint(x: rect.minX + offset + triangleSideLength / 2, y: rect.maxY + arrowLength),
                    CGPoint(x: rect.minX + offset, y: rect.maxY)
                )
            case .bottomRight:
                return (
                    CGPoint(x: rect.maxX - offset, y: rect.maxY),
                    CGPoint(x: rect.maxX - offset - triangleSideLength / 2, y: rect.maxY + arrowLength),
                    CGPoint(x: rect.maxX - offset - triangleSideLength, y: rect.maxY)
                )
            default:
                return (
                    CGPoint.zero,
                    CGPoint.zero,
                    CGPoint.zero
                )
        }
    }
    
    func makeArrow(path: inout Path, rect: CGRect, triangleSideLength: CGFloat, offset: CGFloat, position: ViewPosition) -> Path {
        let points = self.trianglePointsFor(
            arrowPosition: position,
            rect: rect,
            triangleSideLength: triangleSideLength,
            offset: offset
        )
        
        path.addLine(to: points.0)
        path.addLine(to: points.1)
        path.addLine(to: points.2)
        
        return path
    }
}
