//
//  NewEventCard.swift
//  boringNotch
//
//  Created by Ronald Wen on 2026-11-16.
//
//  What shows after dragging out a new event on an empty part of the
//  calendar: a title, the time it covers, which calendar and color,
//  whether it repeats, a reminder, a location and a description, then Save.
//

import SwiftUI

struct NewEventCard: View {
    struct Details {
        let title: String
        let calendarID: String?
        let location: String
        let notes: String
        let repeats: EventRepeat
        let reminderMinutes: Int?
        let guests: [String]
        let addsMeet: Bool
        /// Nil keeps the calendar's color.
        let color: GoogleEventColor?
    }

    let start: Date
    let end: Date
    let calendars: [CalendarModel]
    let defaultCalendarID: String?
    /// Signed in to Google Calendar, so guests, Meet links and a color can be added.
    var canInvite = false
    /// True if the calendar took the new event.
    let onSave: (Details) async -> Bool
    let onClose: () -> Void

    @State private var title = ""
    @State private var location = ""
    @State private var notes = ""
    @State private var calendarID: String?
    @State private var repeats: EventRepeat = .never
    @State private var reminderMinutes: Int?
    @State private var guestsText = ""
    @State private var addsMeet = false
    @State private var color: GoogleEventColor?
    @State private var saveFailed = false
    @State private var escapeMonitor: Any?
    @FocusState private var isTitleFocused: Bool

    private static let escapeKeyCode: UInt16 = 53

    private var calendar: CalendarModel? {
        calendars.first { $0.id == (calendarID ?? defaultCalendarID) } ?? calendars.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(shownColor)
                    .frame(width: 4, height: 20)
                TextField("", text: $title, prompt: Text("Add title").foregroundStyle(.white.opacity(0.35)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .focused($isTitleFocused)
                    .onSubmit(save)
                closeButton
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    row("clock", timeText)
                    HStack(spacing: 6) {
                        repeatMenu
                        reminderMenu
                    }
                    if case .custom = repeats {
                        CustomRepeatEditor(start: start, custom: customBinding)
                    }
                    if canInvite {
                        HStack(spacing: 6) {
                            field("person.2", "Add guests (emails)", text: $guestsText)
                            meetToggle
                        }
                    }
                    field("mappin.and.ellipse", "Add location", text: $location)
                    field("text.alignleft", "Add description", text: $notes)
                    if saveFailed {
                        Text(invites ? "Couldn't save it. Guests, Meet and colors need a Google calendar." : "Couldn't save it. This calendar may be read-only.")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 4) {
                        calendarMenu
                        if canInvite { colorMenu }
                    }
                    Button(action: save) {
                        Text("Save")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 22)
                            .background(Capsule().fill(Color.accentColor))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(width: 440, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(CardBackground())
        .onAppear {
            NotchKeyboardFocus.begin()
            DispatchQueue.main.async { isTitleFocused = true }
            // The text fields don't pass Escape on, so catch it here.
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

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private var calendarMenu: some View {
        Menu {
            ForEach(calendars, id: \.id) { option in
                Button {
                    calendarID = option.id
                } label: {
                    Label {
                        Text(option.title)
                    } icon: {
                        Image(nsImage: Self.dot(option.color))
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color(nsColor: calendar?.color ?? .systemBlue))
                    .frame(width: 7, height: 7)
                Text(calendar?.title ?? "Calendar")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(.white.opacity(0.12)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Guests, a Meet link or a color were asked for, so it goes through Google.
    private var invites: Bool {
        canInvite && (addsMeet || color != nil || !GoogleCalendarFormat.guestEmails(from: guestsText).isEmpty)
    }

    /// The chosen color, else the calendar's.
    private var shownColor: Color {
        Color(nsColor: color?.color ?? calendar?.color ?? .systemBlue)
    }

    /// Google Calendar's event colors, beside the calendar menu.
    private var colorMenu: some View {
        Menu {
            Button {
                color = nil
            } label: {
                Label { Text("Calendar color") } icon: { Image(nsImage: Self.dot(calendar?.color ?? .systemBlue)).renderingMode(.original) }
                    .labelStyle(.titleAndIcon)
            }
            ForEach(GoogleEventColor.allCases, id: \.self) { option in
                Button {
                    color = option
                } label: {
                    Label { Text(option.name) } icon: { Image(nsImage: Self.dot(option.color)).renderingMode(.original) }
                        .labelStyle(.titleAndIcon)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(shownColor)
                    .frame(width: 9, height: 9)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(Capsule().fill(.white.opacity(0.12)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Event color")
    }

    private var meetToggle: some View {
        Button { addsMeet.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: addsMeet ? "checkmark.square.fill" : "video")
                    .font(.system(size: 9, weight: .semibold))
                Text("Google Meet")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(addsMeet ? .white : .white.opacity(0.75))
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(addsMeet ? Color.green.opacity(0.5) : .white.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var repeatMenu: some View {
        Menu {
            ForEach(EventRepeat.presets, id: \.self) { option in
                Button(option.label(for: start)) { repeats = option }
            }
            Divider()
            Button("Custom…") {
                if case .custom = repeats { return }
                repeats = .custom(.starting(on: start))
            }
        } label: {
            pill("arrow.clockwise", repeats.label(for: start))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// The custom rule being edited; only read while `repeats` is custom.
    private var customBinding: Binding<CustomRepeat> {
        Binding(
            get: {
                if case .custom(let custom) = repeats { return custom }
                return .starting(on: start)
            },
            set: { repeats = .custom($0) }
        )
    }

    private var reminderMenu: some View {
        Menu {
            ForEach(EventReminder.choices, id: \.self) { minutes in
                Button(EventReminder.label(minutes)) { reminderMinutes = minutes }
            }
        } label: {
            pill("bell", EventReminder.label(reminderMinutes))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// A small menu button: icon, current choice, up-down chevron.
    private func pill(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 6, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Capsule().fill(.white.opacity(0.08)))
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 12)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
    }

    private func field(_ symbol: String, _ placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 12)
            TextField("", text: text, prompt: Text(placeholder).foregroundStyle(.white.opacity(0.35)))
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .onSubmit(save)
        }
    }

    /// "Tue, Nov 17 · 1:00 – 2:30 PM"
    private var timeText: String {
        let day = start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return "\(day) · \(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    /// A colour swatch for the menu, which only shows images, not views.
    private static func dot(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return image
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = Details(
            title: trimmed.isEmpty ? QuickAddParser.untitled : trimmed,
            calendarID: calendar?.id,
            location: location,
            notes: notes,
            repeats: repeats,
            reminderMinutes: reminderMinutes,
            guests: canInvite ? GoogleCalendarFormat.guestEmails(from: guestsText) : [],
            addsMeet: canInvite && addsMeet,
            color: canInvite ? color : nil
        )
        Task {
            if await onSave(details) {
                onClose()
            } else {
                saveFailed = true
            }
        }
    }
}
