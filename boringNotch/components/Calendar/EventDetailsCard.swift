//
//  EventDetailsCard.swift
//  boringNotch
//
//  What clicking an event in the Calendar tab shows: its details, plus
//  Open in Calendar and Delete. Deleting a repeating event asks which of its
//  occurrences, the way Google Calendar does.
//

import SwiftUI

struct EventDetailsCard: View {
    let event: EventModel
    let onClose: () -> Void
    let onOpen: () -> Void
    /// True if the calendar took the deletion.
    let onDelete: (EventDeletionScope) async -> Bool

    @State private var isChoosingScope = false
    @State private var isConfirmingDelete = false
    @State private var deleteFailed = false
    @State private var confirmResetTask: Task<Void, Never>?

    private var color: Color { Color(nsColor: event.calendar.color) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isChoosingScope {
                scopeChooser
            } else {
                // Details beside the buttons rather than above them: the
                // notch's content area is wide and short.
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        details
                        if deleteFailed {
                            Text("Couldn't delete it. This calendar may be read-only.")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 0)
                    actions
                }
            }
        }
        .padding(12)
        .frame(width: 440, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(CardBackground())
        .onDisappear { confirmResetTask?.cancel() }
    }

    // MARK: - Content

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(timeText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            line("calendar", event.calendar.title + (event.hasRecurrenceRules ? " · Repeats" : ""))
            if let location = event.location, !location.isEmpty {
                line("mappin.and.ellipse", location)
            }
            if !event.participants.isEmpty {
                line("person.2", "\(event.participants.count) \(event.participants.count == 1 ? "guest" : "guests")")
            }
            if let notes = event.notes, !notes.isEmpty {
                line("text.alignleft", notes, lines: 2)
            }
        }
    }

    private func line(_ symbol: String, _ text: String, lines: Int = 1) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 12)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(lines)
        }
    }

    private var timeText: String {
        let start = event.start, end = event.end
        let day = start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let startTime = start.formatted(date: .omitted, time: .shortened)
        let endTime = end.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDate(start, inSameDayAs: end) || end <= start {
            return end <= start ? "\(day) · \(startTime)" : "\(day) · \(startTime) – \(endTime)"
        }
        let endDay = end.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return "\(day) \(startTime) – \(endDay) \(endTime)"
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .trailing, spacing: 6) {
            pill("Open in Calendar", symbol: "arrow.up.forward.app", tint: .white.opacity(0.12), text: .white, action: onOpen)
            if event.type.isEvent {
                pill(isConfirmingDelete ? "Tap again to delete" : "Delete",
                     symbol: "trash",
                     tint: .red.opacity(isConfirmingDelete ? 0.85 : 0.22),
                     text: isConfirmingDelete ? .white : .red,
                     action: tapDelete)
            }
        }
    }

    /// Which occurrences of a repeating event to delete.
    private var scopeChooser: some View {
        HStack(spacing: 6) {
            Text("Delete")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            scopeButton("This event", .thisEvent)
            scopeButton("This & following", .thisAndFollowing)
            scopeButton("All events", .allEvents)
            Spacer(minLength: 0)
            pill("Cancel", tint: .white.opacity(0.12), text: .white) {
                isChoosingScope = false
            }
        }
    }

    private func scopeButton(_ title: String, _ scope: EventDeletionScope) -> some View {
        pill(title, tint: .red.opacity(0.22), text: .red) {
            Task { await delete(scope) }
        }
    }

    private func pill(_ title: String, symbol: String? = nil, tint: Color, text: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                }
                Text(title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(text)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(tint))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func tapDelete() {
        deleteFailed = false
        if event.hasRecurrenceRules {
            isChoosingScope = true
            return
        }
        guard isConfirmingDelete else {
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)) { isConfirmingDelete = true }
            confirmResetTask = Task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)) { isConfirmingDelete = false }
            }
            return
        }
        confirmResetTask?.cancel()
        Task { await delete(.thisEvent) }
    }

    private func delete(_ scope: EventDeletionScope) async {
        if await onDelete(scope) { return }
        isChoosingScope = false
        isConfirmingDelete = false
        deleteFailed = true
    }
}

/// Liquid Glass on macOS 26 and later; a dark frosted panel before.
private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 14))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        }
    }
}
