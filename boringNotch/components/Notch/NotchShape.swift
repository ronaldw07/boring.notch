//
//  NotchShape.swift
//  boringNotch
//
// Created by Kai Azim on 2023-08-24.
// Original source: https://github.com/MrKai77/DynamicNotchKit
// Modified by Alexander on 2025-05-18.

import SwiftUI

struct NotchShape: Shape {
    private var topCornerRadius: CGFloat
    private var bottomCornerRadius: CGFloat

    init(
        topCornerRadius: CGFloat? = nil,
        bottomCornerRadius: CGFloat? = nil
    ) {
        self.topCornerRadius = topCornerRadius ?? 6
        self.bottomCornerRadius = bottomCornerRadius ?? 14
    }

    /// How far before the radius each bottom corner starts to curve.
    private static let bottomCornerSpan: CGFloat = 1.3
    /// How far the curve's handles reach toward the corner, as a share of
    /// that span. Lower than a plain quarter curve (0.67), so it's softer.
    private static let bottomCornerPull: CGFloat = 0.6

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get {
            .init(
                topCornerRadius,
                bottomCornerRadius
            )
        }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(
            to: CGPoint(
                x: rect.minX,
                y: rect.minY
            )
        )

        path.addQuadCurve(
            to: CGPoint(
                x: rect.minX + topCornerRadius,
                y: rect.minY + topCornerRadius
            ),
            control: CGPoint(
                x: rect.minX + topCornerRadius,
                y: rect.minY
            )
        )

        // Bottom corners start curving a little earlier than the radius and
        // ease in gently, so they read as one smooth curve rather than a
        // pinched quarter turn.
        let span = min(bottomCornerRadius * Self.bottomCornerSpan, rect.height - topCornerRadius)
        let pull = span * Self.bottomCornerPull
        let left = rect.minX + topCornerRadius
        let right = rect.maxX - topCornerRadius

        path.addLine(to: CGPoint(x: left, y: rect.maxY - span))
        path.addCurve(
            to: CGPoint(x: left + span, y: rect.maxY),
            control1: CGPoint(x: left, y: rect.maxY - span + pull),
            control2: CGPoint(x: left + span - pull, y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: right - span, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: right, y: rect.maxY - span),
            control1: CGPoint(x: right - span + pull, y: rect.maxY),
            control2: CGPoint(x: right, y: rect.maxY - span + pull)
        )

        path.addLine(
            to: CGPoint(
                x: rect.maxX - topCornerRadius,
                y: rect.minY + topCornerRadius
            )
        )

        path.addQuadCurve(
            to: CGPoint(
                x: rect.maxX,
                y: rect.minY
            ),
            control: CGPoint(
                x: rect.maxX - topCornerRadius,
                y: rect.minY
            )
        )

        path.addLine(
            to: CGPoint(
                x: rect.minX,
                y: rect.minY
            )
        )

        return path
    }
}

#Preview {
    NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
        .frame(width: 200, height: 32)
        .padding(10)
}
