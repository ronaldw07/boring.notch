//
//  drop.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on  04/08/24.
//

import Foundation
import SwiftUI


public class BoringAnimations {
    @Published var notchStyle: Style = .notch
    
    init() {
        self.notchStyle = .notch
    }
    
    var animation: Animation {
        if #available(macOS 14.0, *), notchStyle == .notch {
            Animation.spring(.bouncy(duration: 0.4))
        } else {
            Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.7)
        }
    }

    /// Ease-out quint. Used anywhere a tab's `extraContentHeight` animates
    /// back down toward zero — a spring's overshoot would carry it below
    /// zero and visibly yank the panel's bottom edge up past its resting
    /// position before settling back, so this decelerates into the target
    /// instead of springing toward it.
    var collapseCurve: Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: 0.35)
    }

    /// Opening and closing the panel itself. Applied *inside* `open()`/
    /// `close()` rather than left to callers to wrap — `close()` in
    /// particular is often called from an async Task (e.g. the hover-exit
    /// timer), and a state change made outside an active SwiftUI
    /// transaction doesn't reliably pick up an ambient `.animation(value:)`
    /// modifier the way a synchronous UI event does. Self-wrapping means it
    /// animates the same way no matter what called it.
    var panelAnimation: Animation {
        .spring(response: 0.42, dampingFraction: 1.0, blendDuration: 0)
    }

    // TODO: Move all animations to this file
    
}
