//
//  QuickAddCard.swift
//  boringNotch
//
//  Created by Ronald Wen on 2026-11-16.
//
//  The + in the Calendar tab: type an event in plain words, see what it
//  will become, press Return to add it.
//

import SwiftUI

struct QuickAddCard: View {
    /// The day on screen; a time typed without a day lands here.
    let day: Date
    /// Where the event will go, from Calendar's default calendar.
    let calendarTitle: String?
    /// True if the calendar took the new event.
    let onAdd: (QuickAddParser.Result) async -> Bool
    let onClose: () -> Void

    @State private var text = ""
    @State private var addFailed = false
    @FocusState private var isFocused: Bool
    @State private var escapeMonitor: Any?

    private static let escapeKeyCode: UInt16 = 53

    private var result: QuickAddParser.Result? {
        QuickAddParser.parse(text, day: day)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                TextField("", text: $text, prompt: Text("Lunch with Sam tomorrow 1pm").foregroundStyle(.white.opacity(0.35)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .focused($isFocused)
                    .onSubmit(add)
                    .onChange(of: text) { addFailed = false }
                    // Clicking into another app ends the edit, like the timer's field.
                    .onChange(of: isFocused) { _, focused in if !focused { onClose() } }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                Text(previewText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(addFailed ? .orange : .white.opacity(result == nil ? 0.45 : 0.8))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: add) {
                    Text("Add")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 22)
                        .background(Capsule().fill(result == nil ? .white.opacity(0.12) : .accentColor))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(result == nil)
            }
        }
        .padding(12)
        .frame(width: 440, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(CardBackground())
        .onAppear {
            NotchKeyboardFocus.begin()
            DispatchQueue.main.async { isFocused = true }
            // The text field doesn't pass Escape on, so catch it here.
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == Self.escapeKeyCode else { return event }
                onClose()
                return nil
            }
        }
        .onDisappear {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            NotchKeyboardFocus.end()
        }
    }

    /// What Return will add, e.g. "Lunch with Sam · Tue, Nov 17 · 1:00 – 2:00 PM · Work".
    private var previewText: String {
        if addFailed { return "Couldn't add it. Check that Calendar has a default calendar you can edit." }
        guard let result else { return "Type a time, like 3pm or tomorrow 6-7pm" }
        let dayText = Calendar.current.isDateInToday(result.start)
            ? "Today"
            : result.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let times = "\(result.start.formatted(date: .omitted, time: .shortened)) – \(result.end.formatted(date: .omitted, time: .shortened))"
        return [result.title, dayText, times, calendarTitle].compactMap { $0 }.joined(separator: " · ")
    }

    private func add() {
        guard let result else { return }
        Task {
            if await onAdd(result) {
                onClose()
            } else {
                addFailed = true
            }
        }
    }
}
