//
//  MoveScopeCard.swift
//  boringNotch
//
//  Asked after dragging a repeating event: move just this one, this and
//  the ones after it, or all of them, the way Google Calendar asks.
//  Return picks "This event", Escape puts it back.
//

import SwiftUI

struct MoveScopeCard: View {
    let title: String
    let onChoose: (EventScope) -> Void
    let onCancel: () -> Void

    @State private var keyMonitor: Any?

    private enum Key {
        static let returnKey: UInt16 = 36
        static let enter: UInt16 = 76
        static let escape: UInt16 = 53
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Move “\(title)”")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            HStack(spacing: 6) {
                choice("This event", .thisEvent)
                choice("This & following", .thisAndFollowing)
                choice("All events", .allEvents)
                Spacer(minLength: 0)
                pill("Cancel", symbol: nil, tint: .white.opacity(0.12), action: onCancel)
            }
        }
        .padding(12)
        .frame(width: 400, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(CardBackground())
        .onAppear {
            NotchKeyboardFocus.begin(holdsNotchOpen: false)
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { key in
                switch key.keyCode {
                case Key.returnKey, Key.enter:
                    onChoose(.thisEvent)
                    return nil
                case Key.escape:
                    onCancel()
                    return nil
                default:
                    return key
                }
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            NotchKeyboardFocus.end()
        }
    }

    /// "This event" is highlighted: it's what Return picks.
    private func choice(_ label: String, _ scope: EventScope) -> some View {
        let isReturnChoice = scope == .thisEvent
        return pill(label, symbol: isReturnChoice ? "return" : nil,
                    tint: isReturnChoice ? .accentColor : .white.opacity(0.12)) {
            onChoose(scope)
        }
    }

    private func pill(_ label: String, symbol: String?, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                }
                Text(label).font(.system(size: 10, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(tint))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
