import SwiftUI

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let rt = topRadius
        let rb = bottomRadius

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        path.addQuadCurve(
            to: CGPoint(x: rect.minX + rt, y: rect.minY + rt),
            control: CGPoint(x: rect.minX + rt, y: rect.minY)
        )

        path.addLine(to: CGPoint(x: rect.minX + rt, y: rect.maxY - rb))

        path.addQuadCurve(
            to: CGPoint(x: rect.minX + rt + rb, y: rect.maxY),
            control: CGPoint(x: rect.minX + rt, y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: rect.maxX - rt - rb, y: rect.maxY))

        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - rt, y: rect.maxY - rb),
            control: CGPoint(x: rect.maxX - rt, y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: rect.maxX - rt, y: rect.minY + rt))

        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - rt, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}
