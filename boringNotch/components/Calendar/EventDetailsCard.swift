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
    let onDelete: (EventScope) async -> Bool
    /// The edited event and which occurrences it applies to; true if the
    /// calendar took it.
    let onEdit: (EventEdit, EventScope) async -> Bool

    @State private var isEditing = false
    @State private var editTitle = ""
    @State private var editLocation = ""
    @State private var editNotes = ""
    @State private var editStart = Date()
    @State private var editEnd = Date()
    @State private var editAllDay = false
    @State private var editFailed = false
    /// A repeating event asks which occurrences a save is for.
    @State private var isChoosingSaveScope = false
    @FocusState private var isTitleFocused: Bool

    @State private var isChoosingScope = false
    @State private var isConfirmingDelete = false
    @State private var deleteFailed = false
    @State private var confirmResetTask: Task<Void, Never>?
    /// Backspace asked "Delete this event?"; Enter confirms, Escape backs out.
    @State private var isAskingToDelete = false
    @State private var keyMonitor: Any?

    private enum Key {
        static let backspace: UInt16 = 51
        static let forwardDelete: UInt16 = 117
        static let returnKey: UInt16 = 36
        static let enter: UInt16 = 76
        static let escape: UInt16 = 53
    }

    private var color: Color { Color(nsColor: event.calendar.color) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isEditing {
                editor
            } else {
                header
            }
            if isEditing {
                EmptyView()
            } else if isChoosingScope {
                scopeChooser
            } else if isAskingToDelete {
                deleteQuestion
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
        .onAppear {
            // Keys reach the notch only while it's the key window; it hands
            // focus back when the box closes.
            guard event.type.isEvent else { return }
            NotchKeyboardFocus.begin(holdsNotchOpen: false)
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { handleKey($0) }
        }
        .onDisappear {
            confirmResetTask?.cancel()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            if event.type.isEvent { NotchKeyboardFocus.end() }
        }
    }

    /// Backspace asks to delete, Enter confirms (on a repeating event, just
    /// this one), Escape backs out of the question or closes the box.
    private func handleKey(_ key: NSEvent) -> NSEvent? {
        if isEditing {
            guard key.keyCode == Key.escape else { return key }
            if isChoosingSaveScope {
                isChoosingSaveScope = false
            } else {
                endEditing()
            }
            return nil
        }
        switch key.keyCode {
        case Key.backspace, Key.forwardDelete:
            guard !isAskingToDelete, !isChoosingScope else { return nil }
            deleteFailed = false
            if event.hasRecurrenceRules {
                isChoosingScope = true
            } else {
                isAskingToDelete = true
            }
            return nil
        case Key.returnKey, Key.enter:
            guard isAskingToDelete || isChoosingScope else { return key }
            Task { await delete(.thisEvent) }
            return nil
        case Key.escape:
            if isAskingToDelete || isChoosingScope {
                isAskingToDelete = false
                isChoosingScope = false
            } else {
                onClose()
            }
            return nil
        default:
            return key
        }
    }

    // MARK: - Editing

    /// Title, time, location and notes as fields, with Cancel and Save.
    /// Notes from Google Calendar are edited as plain text.
    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 4, height: 20)
                TextField("", text: $editTitle, prompt: Text("Title").foregroundStyle(.white.opacity(0.35)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .focused($isTitleFocused)
                    .onSubmit(saveEdits)
            }
            timeRow
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    editField("mappin.and.ellipse", "Add location", text: $editLocation)
                    editField("text.alignleft", "Add description", text: $editNotes)
                    if editFailed {
                        Text("Couldn't save it. This calendar may be read-only.")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
                if !isChoosingSaveScope {
                    HStack(spacing: 6) {
                        pill("Cancel", tint: .white.opacity(0.12), text: .white, action: endEditing)
                        pill("Save", symbol: "return", tint: .accentColor, text: .white, action: saveEdits)
                    }
                }
            }
            if isChoosingSaveScope {
                saveScopeChooser
            }
        }
    }

    /// The day, then start and end times (hidden for an all-day event), then
    /// the All day switch. Each field takes typing or the arrow keys.
    private var timeRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 12)
            DatePicker("Day", selection: timeBinding(\.start) { $0.movingDay(to: $1) }, displayedComponents: .date)
            if !editAllDay {
                DatePicker("Start", selection: timeBinding(\.start) { $0.movingStart(to: $1) }, displayedComponents: .hourAndMinute)
                Text("–")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                DatePicker("End", selection: timeBinding(\.end) { $0.movingEnd(to: $1) }, displayedComponents: .hourAndMinute)
            }
            Spacer(minLength: 0)
            pill("All day", symbol: editAllDay ? "checkmark.square.fill" : "square",
                 tint: .white.opacity(editAllDay ? 0.22 : 0.12), text: .white) {
                applyTimes(editTimes.settingAllDay(!editAllDay))
            }
        }
        .datePickerStyle(.field)
        .labelsHidden()
        .controlSize(.small)
        .environment(\.colorScheme, .dark)
    }

    private var editTimes: EventEdit {
        EventEdit(title: editTitle, location: nil, notes: nil, start: editStart, end: editEnd, isAllDay: editAllDay)
    }

    private func applyTimes(_ times: EventEdit) {
        editStart = times.start
        editEnd = times.end
        editAllDay = times.isAllDay
    }

    /// Shows one of the times, and on a change runs it through the rule for
    /// that field (keep the length, keep the end after the start...).
    private func timeBinding(_ field: KeyPath<EventEdit, Date>, _ rule: @escaping (EventEdit, Date) -> EventEdit) -> Binding<Date> {
        Binding(
            get: { editTimes[keyPath: field] },
            set: { applyTimes(rule(editTimes, $0)) }
        )
    }

    /// Which occurrences of a repeating event the save is for. "This event"
    /// is highlighted: it's what Enter picks.
    private var saveScopeChooser: some View {
        HStack(spacing: 6) {
            Text("Save for")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            saveScopeButton("This event", .thisEvent)
            saveScopeButton("This & following", .thisAndFollowing)
            saveScopeButton("All events", .allEvents)
            Spacer(minLength: 0)
            pill("Cancel", tint: .white.opacity(0.12), text: .white) {
                isChoosingSaveScope = false
            }
        }
    }

    private func saveScopeButton(_ title: String, _ scope: EventScope) -> some View {
        let isEnterChoice = scope == .thisEvent
        return pill(title, symbol: isEnterChoice ? "return" : nil,
                    tint: isEnterChoice ? .accentColor : .white.opacity(0.12), text: .white) {
            save(scope)
        }
    }

    private func editField(_ symbol: String, _ placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 12)
            TextField("", text: text, prompt: Text(placeholder).foregroundStyle(.white.opacity(0.35)))
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .onSubmit(saveEdits)
        }
    }

    private func beginEditing() {
        editTitle = event.title
        editLocation = event.location ?? ""
        editNotes = event.notes.map(NotesText.plain) ?? ""
        editStart = event.start
        editEnd = event.end
        editAllDay = event.isAllDay
        editFailed = false
        isChoosingSaveScope = false
        isConfirmingDelete = false
        isEditing = true
        // Typing keeps the notch open, like the other text boxes in it.
        NotchKeyboardFocus.holdsNotchOpen = true
        DispatchQueue.main.async { isTitleFocused = true }
    }

    private func endEditing() {
        isEditing = false
        isChoosingSaveScope = false
        NotchKeyboardFocus.holdsNotchOpen = false
    }

    /// The fields as an edit. Text left as it was keeps the calendar's own
    /// copy, so saving only a new time doesn't flatten formatted notes.
    private var draft: EventEdit {
        let title = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let location = editLocation == (event.location ?? "")
            ? event.location : editLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = editNotes == (event.notes.map(NotesText.plain) ?? "")
            ? event.notes : editNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        return EventEdit(
            title: title.isEmpty ? event.title : title,
            location: location?.isEmpty == true ? nil : location,
            notes: notes?.isEmpty == true ? nil : notes,
            start: editStart, end: editEnd, isAllDay: editAllDay
        )
    }

    /// Return or Save. A repeating event first asks which occurrences; a
    /// second Return then picks "This event".
    private func saveEdits() {
        guard draft != EventEdit(event) else {
            endEditing()
            return
        }
        if event.hasRecurrenceRules && !isChoosingSaveScope {
            isChoosingSaveScope = true
            return
        }
        save(.thisEvent)
    }

    private func save(_ scope: EventScope) {
        let edit = draft
        Task {
            if await onEdit(edit, scope) {
                endEditing()
            } else {
                isChoosingSaveScope = false
                editFailed = true
            }
        }
    }

    /// Cancel first, Delete highlighted: Enter deletes.
    private var deleteQuestion: some View {
        HStack(spacing: 6) {
            Text("Delete this event?")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            pill("Cancel", tint: .white.opacity(0.12), text: .white) {
                isAskingToDelete = false
            }
            pill("Delete", symbol: "return", tint: .red.opacity(0.85), text: .white) {
                Task { await delete(.thisEvent) }
            }
        }
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
                HStack(spacing: 6) {
                    Text(timeText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                    if let relative = relativeText {
                        Text(relative)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(relative == "Now" ? .green : color)
                            .lineLimit(1)
                    }
                }
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
                guests
            }
            if let notes = event.notes.map(NotesText.plain)?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 12)
                    Text(Self.linkified(notes))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .tint(color)
                        .lineLimit(3)
                }
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

    /// Names with a dot for each answer: green yes, yellow maybe, red no,
    /// grey not yet. The first few, then a count.
    private var guests: some View {
        let shown = event.participants.prefix(Self.guestsShown)
        let more = event.participants.count - shown.count
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "person.2")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 12)
            HStack(spacing: 8) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, guest in
                    HStack(spacing: 3) {
                        Circle().fill(Self.color(for: guest.status)).frame(width: 5, height: 5)
                        Text(guest.isCurrentUser ? "You" : Self.shortName(guest.name))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                if more > 0 {
                    Text("+\(more)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }

    private static let guestsShown = 4

    private static func color(for status: AttendanceStatus) -> Color {
        switch status {
        case .accepted: .green
        case .maybe: .yellow
        case .declined: .red
        case .pending, .unknown: .white.opacity(0.35)
        }
    }

    /// "Sam Lee" → "Sam"; an email address → the part before the @.
    private static func shortName(_ name: String) -> String {
        let base = name.split(separator: "@").first.map(String.init) ?? name
        return base.split(separator: " ").first.map(String.init) ?? base
    }

    /// Notes with any web addresses made clickable.
    private static func linkified(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url,
                  let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
            result[lower..<upper].underlineStyle = .single
        }
        return result
    }

    /// "In 12 min", "Now", or nil when it's further off or already over.
    private var relativeText: String? {
        let now = Date.now
        if event.start <= now && now < event.end { return "Now" }
        let minutes = Int(event.start.timeIntervalSince(now) / 60)
        guard event.start > now, minutes < 60 * 3 else { return nil }
        if minutes < 1 { return "In 1 min" }
        if minutes < 60 { return "In \(minutes) min" }
        return "In \(minutes / 60) hr" + (minutes % 60 == 0 ? "" : " \(minutes % 60) min")
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
            if let join = event.meetingURL {
                pill("Join", symbol: "video.fill", tint: .green.opacity(0.85), text: .white) {
                    NSWorkspace.shared.open(join)
                }
            }
            pill("Open in Calendar", symbol: "arrow.up.forward.app", tint: .white.opacity(0.12), text: .white, action: onOpen)
            if event.type.isEvent {
                pill("Edit", symbol: "pencil", tint: .white.opacity(0.12), text: .white, action: beginEditing)
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

    /// "This event" is highlighted: it's what Enter deletes.
    private func scopeButton(_ title: String, _ scope: EventScope) -> some View {
        let isEnterChoice = scope == .thisEvent
        return pill(title, symbol: isEnterChoice ? "return" : nil,
                    tint: .red.opacity(isEnterChoice ? 0.85 : 0.22), text: isEnterChoice ? .white : .red) {
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

    private func delete(_ scope: EventScope) async {
        if await onDelete(scope) { return }
        isChoosingScope = false
        isConfirmingDelete = false
        isAskingToDelete = false
        deleteFailed = true
    }
}

/// Liquid Glass on macOS 26 and later; a dark frosted panel before.
struct CardBackground: ViewModifier {
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


extension EventModel {
    /// Hosts whose links join a video call.
    private static let meetingHosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com", "facetime.apple.com"]

    /// The first video-call link in the event's link, location or notes.
    var meetingURL: URL? {
        let candidates = [url?.absoluteString, location, notes].compactMap { $0 }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in candidates {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let found = match.url, let host = found.host?.lowercased() else { continue }
                if Self.meetingHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    return found
                }
            }
        }
        return nil
    }
}

/// Calendar notes as readable text. Google Calendar stores descriptions as
/// HTML, so tags become line breaks and bullets, and entities are decoded.
enum NotesText {
    private static let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]

    static func plain(_ notes: String) -> String {
        guard notes.range(of: "<[a-zA-Z/][^>]*>", options: .regularExpression) != nil else { return notes }
        var text = notes
        // A link keeps its address so it can still be clicked.
        text = text.replacingOccurrences(of: "<a[^>]*href=\"([^\"]*)\"[^>]*>(.*?)</a>", with: "$2 $1", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<li[^>]*>", with: "\n• ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</li>|</ul>|</ol>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in entities { text = text.replacingOccurrences(of: entity, with: character) }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // "https://x https://x" when a link's text was its own address.
        return lines.map { line in
            line.replacingOccurrences(of: "(\\S+) \\1(?=\\s|$)", with: "$1", options: .regularExpression)
        }.joined(separator: "\n")
    }
}
