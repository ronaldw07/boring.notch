//
//  TaskEditCard.swift
//  boringNotch
//
//  What clicking a Google task shows: its title, due day, a time and notes
//  to edit, Done, Open in Google, Delete (tap twice) and Save. Return saves,
//  Escape closes. The time stays in Chora: Google Tasks has no time field.
//

import SwiftUI

struct TaskEditCard: View {
    let task: GoogleTask
    /// True if Google took the change.
    let onSave: (_ title: String, _ due: Date, _ notes: String, _ isCompleted: Bool, _ minutes: Int?) async -> Bool
    let onDelete: () async -> Bool
    let onClose: () -> Void

    @State private var title = ""
    @State private var due = Date()
    @State private var notes = ""
    @State private var isCompleted = false
    /// Minutes after midnight; nil for no time.
    @State private var minutes: Int?
    @State private var isConfirmingDelete = false
    @State private var failed = false
    @State private var escapeMonitor: Any?
    @FocusState private var isTitleFocused: Bool

    private static let escapeKeyCode: UInt16 = 53
    /// "Add time" starts at the next whole hour.
    private static let minutesPerHour = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { isCompleted.toggle() } label: {
                    Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(isCompleted ? .green : .gray)
                }
                .buttonStyle(.plain)
                .help(isCompleted ? "Mark not done" : "Mark done")
                TextField("", text: $title, prompt: Text("Task").foregroundStyle(.white.opacity(0.35)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .focused($isTitleFocused)
                    .onSubmit(save)
            }
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        icon("calendar")
                        DatePicker("Due", selection: $due, displayedComponents: .date)
                            .datePickerStyle(.field)
                            .labelsHidden()
                            .controlSize(.small)
                            .environment(\.colorScheme, .dark)
                            .fixedSize()
                        timeControl
                    }
                    HStack(spacing: 6) {
                        icon("text.alignleft")
                        TextField("", text: $notes, prompt: Text("Add details").foregroundStyle(.white.opacity(0.35)))
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .onSubmit(save)
                    }
                    if failed {
                        Text("Couldn't reach Google Tasks. Try again.")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    if let link = task.link {
                        pill("Google", symbol: "arrow.up.right.square", tint: .white.opacity(0.12), text: .white) {
                            NSWorkspace.shared.open(link)
                        }
                        .help("Open in Google")
                    }
                    pill(isConfirmingDelete ? "Tap again to delete" : "Delete", symbol: "trash",
                         tint: .red.opacity(isConfirmingDelete ? 0.85 : 0.22),
                         text: isConfirmingDelete ? .white : .red, action: tapDelete)
                    pill("Save", symbol: "return", tint: .accentColor, text: .white, action: save)
                }
            }
        }
        .padding(12)
        .frame(width: 440, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(CardBackground())
        .onAppear {
            title = task.title
            due = task.due
            notes = task.notes ?? ""
            isCompleted = task.isCompleted
            minutes = task.minutes
            NotchKeyboardFocus.begin()
            DispatchQueue.main.async { isTitleFocused = true }
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

    /// "Add time", or the time with an × to take it off again.
    @ViewBuilder
    private var timeControl: some View {
        if minutes == nil {
            Button {
                let hour = Calendar.current.component(.hour, from: .now) + 1
                minutes = min(hour, 23) * Self.minutesPerHour
            } label: {
                Text("Add time")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(Capsule().fill(.white.opacity(0.08)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Shows the task at this time in Chora's calendar (Google Tasks keeps only the day)")
        } else {
            DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                .datePickerStyle(.field)
                .labelsHidden()
                .controlSize(.small)
                .environment(\.colorScheme, .dark)
                .fixedSize()
            Button { minutes = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(.white.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Remove time")
        }
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: due).addingTimeInterval(TimeInterval((minutes ?? 0) * 60)) },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes = (parts.hour ?? 0) * Self.minutesPerHour + (parts.minute ?? 0)
            }
        )
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
            .frame(width: 12)
    }

    private func pill(_ label: String, symbol: String, tint: Color, text: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                Text(label).font(.system(size: 10, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(text)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(tint))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = trimmed.isEmpty ? task.title : trimmed
        let newNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let unchanged = newTitle == task.title && Calendar.current.isDate(due, inSameDayAs: task.due)
            && newNotes == (task.notes ?? "") && isCompleted == task.isCompleted && minutes == task.minutes
        guard !unchanged else {
            onClose()
            return
        }
        Task {
            if await onSave(newTitle, due, newNotes, isCompleted, minutes) {
                onClose()
            } else {
                failed = true
            }
        }
    }

    /// First tap asks, second deletes.
    private func tapDelete() {
        guard isConfirmingDelete else {
            isConfirmingDelete = true
            return
        }
        Task {
            if await onDelete() {
                onClose()
            } else {
                isConfirmingDelete = false
                failed = true
            }
        }
    }
}
