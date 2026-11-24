//
//  CalendarTabView.swift
//  boringNotch
//
//  The day as one wide horizontal timeline: hours run left to right and
//  events sit in lanes as blocks sized by their real start and end. Scroll
//  sideways with two fingers or a mouse wheel; the expand button grows the
//  notch so overlapping events get room of their own. A header button turns
//  it into a vertical day like Google Calendar's: hours run down, events
//  that overlap sit side by side, and it scrolls up and down.
//

import AppKit
import Defaults
import EventKit
import SwiftUI

/// Height math for dragging the notch's bottom edge.
enum NotchResize {
    /// Within this of the normal size, a drag lands exactly on it.
    static let snap: CGFloat = 12

    /// Extra height after dragging the edge `dragged` points down (negative
    /// is up) from a start of `start`: never below the normal size or past
    /// `maximum`, and snapped to the normal size when close to it.
    static func extra(start: CGFloat, dragged: CGFloat, maximum: CGFloat) -> CGFloat {
        let raw = min(max(start + dragged, 0), max(0, maximum))
        return raw < snap ? 0 : raw.rounded()
    }
}

/// Pure lane math, kept out of the view.
enum DayTimelineLayout {
    struct Placed: Identifiable {
        let event: EventModel
        let lane: Int
        /// Seconds from the start of the day, clamped to it.
        let start: TimeInterval
        let end: TimeInterval
        /// Vertical view only: how many columns its group of overlapping
        /// events is split into; `lane` is its column.
        var columns = 1
        /// Week view only: which day's column it's in.
        var dayIndex = 0
        /// A repeating event shows once per day, so its start is part of it.
        var id: String { "\(event.id)|\(event.start.timeIntervalSince1970)|\(dayIndex)" }
    }

    /// Only the end can be dragged, like Google Calendar: the start
    /// changes by moving the event or typing it in Edit.
    enum DragMode { case move, resizeEnd }

    /// Dragging snaps to this.
    static let snap: TimeInterval = 15 * 60

    /// New span, in seconds from the start of the day, after dragging by
    /// `delta` seconds. A move keeps the event's length; a resize lands the
    /// moved edge on the grid and never inverts or collapses the event.
    static func adjusted(start: TimeInterval, end: TimeInterval, mode: DragMode,
                         delta: TimeInterval, dayLength: TimeInterval) -> (start: TimeInterval, end: TimeInterval) {
        func onGrid(_ value: TimeInterval) -> TimeInterval { (value / snap).rounded() * snap }
        switch mode {
        case .move:
            let length = end - start
            let steps = (delta / snap).rounded() * snap
            let newStart = min(max(start + steps, 0), max(0, dayLength - length))
            return (newStart, newStart + length)
        case .resizeEnd:
            let newEnd = min(max(onGrid(end + delta), start + snap), dayLength)
            return (start, newEnd)
        }
    }

    /// Zero-length items, like a reminder's due time, still get a block.
    static let minimumDuration: TimeInterval = 15 * 60

    /// The room a block needs for its title to be readable, however short
    /// the event: anything starting before this has passed gets a row of
    /// its own instead of squeezing in beside it.
    static let footprint: TimeInterval = 60 * 60

    /// Earliest first (longest first on a tie), each into the first lane
    /// that's free by its start. A lane stays taken for at least
    /// `footprint`, so near-simultaneous events stack top to bottom.
    static func place(_ events: [EventModel], dayStart: Date, dayLength: TimeInterval) -> [Placed] {
        var laneEnds: [TimeInterval] = []
        return spans(events, dayStart: dayStart, dayLength: dayLength)
            .map { event, start, end in
                let lane = laneEnds.firstIndex { $0 <= start } ?? laneEnds.count
                let taken = max(end, start + footprint)
                if lane == laneEnds.count {
                    laneEnds.append(taken)
                } else {
                    laneEnds[lane] = taken
                }
                return Placed(event: event, lane: lane, start: start, end: end)
            }
    }

    /// For the vertical view, like Google Calendar's day: events that
    /// overlap sit side by side and share the width. Events are taken
    /// earliest first into the first free column; a group ends where nothing
    /// in it is still running, and every event in a group gets the same
    /// column count.
    static func columns(_ events: [EventModel], dayStart: Date, dayLength: TimeInterval,
                        footprint: TimeInterval) -> [Placed] {
        let found = spans(events, dayStart: dayStart, dayLength: dayLength)
        let slots = columnSlots(found.map { ($0.1, $0.2) }, footprint: footprint)
        return zip(found, slots).map { span, slot in
            Placed(event: span.0, lane: slot.column, start: span.1, end: span.2, columns: slot.count)
        }
    }

    /// Column and group column count for spans already sorted by start.
    /// A span holds its column for at least `footprint`, so a very short
    /// event still has room for its title.
    static func columnSlots(_ spans: [(start: TimeInterval, end: TimeInterval)],
                            footprint: TimeInterval) -> [(column: Int, count: Int)] {
        var slots: [(column: Int, count: Int)] = []
        var groupStart = 0
        var columnEnds: [TimeInterval] = []
        var groupEnd = -TimeInterval.infinity

        func closeGroup() {
            for index in groupStart ..< slots.count {
                slots[index].count = columnEnds.count
            }
            groupStart = slots.count
            columnEnds = []
        }

        for span in spans {
            if span.start >= groupEnd { closeGroup() }
            let taken = max(span.end, span.start + footprint)
            let column = columnEnds.firstIndex { $0 <= span.start } ?? columnEnds.count
            if column == columnEnds.count {
                columnEnds.append(taken)
            } else {
                columnEnds[column] = taken
            }
            groupEnd = max(groupEnd, taken)
            slots.append((column, 1))
        }
        closeGroup()
        return slots
    }

    /// Timed events that touch the day, clamped to it, earliest first
    /// (longest first on a tie).
    private static func spans(_ events: [EventModel], dayStart: Date,
                              dayLength: TimeInterval) -> [(EventModel, TimeInterval, TimeInterval)] {
        events.compactMap { event -> (EventModel, TimeInterval, TimeInterval)? in
            let rawStart = event.start.timeIntervalSince(dayStart)
            let rawEnd = event.end.timeIntervalSince(dayStart)
            // Must actually touch the day: one ending right at midnight
            // belongs to the day before.
            guard rawStart < dayLength, rawEnd > 0 || rawStart >= 0 else { return nil }
            let start = max(rawStart, 0)
            let end = min(max(rawEnd, start + minimumDuration), dayLength)
            return (event, start, end)
        }
        .sorted { ($0.1, $1.2) < ($1.1, $0.2) }
    }
}

struct CalendarTabView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var calendarManager = CalendarManager.shared
    @ObservedObject private var googleTasks = GoogleTasksManager.shared

    @State private var day: Date = Calendar.current.startOfDay(for: .now)
    /// The day an arrow or Today asked for, while its events load. The
    /// timeline keeps showing the old day until then, so it never draws one
    /// day's events on another.
    @State private var requestedDay: Date?
    @State private var requestedSpan: CalendarSpan?
    /// 1 stepping forward, -1 back: the new day drifts in from that side.
    @State private var dayDirection: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A quick crossfade between days, the new one drifting in a few points
    /// from the side you stepped toward. Fade only with reduced motion.
    private static let daySwitch = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)
    private static let dayDrift: CGFloat = 10

    private var dayTransition: AnyTransition {
        let drift = reduceMotion ? 0 : Self.dayDrift * dayDirection
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: drift)),
            removal: .opacity
        )
    }
    @AppStorage("calendarVerticalView") private var isVertical = false
    @AppStorage("calendarSpan") private var span: CalendarSpan = .day
    @ObservedObject private var weather = WeatherManager.shared
    @ObservedObject private var googleCalendar = GoogleCalendarManager.shared
    /// How far the timeline is scrolled along its time axis.
    @State private var offset: CGFloat = 0
    @State private var viewportSize: CGSize = .zero
    @State private var isExpanded = false
    /// Vertical view: how much taller than its normal size the notch has
    /// been dragged or expanded. Zero is the normal size.
    @State private var verticalExtra: CGFloat = 0
    /// Height at the start of a drag on the bottom edge.
    @State private var resizeStartExtra: CGFloat?
    /// The size the expand button goes back to: the last one dragged to.
    @AppStorage("calendarVerticalExtraHeight") private var rememberedVerticalExtra: Double = 0
    /// Whether the calendar was left expanded, so switching tabs or closing
    /// the notch brings it back at the same size.
    @AppStorage("calendarWasExpanded") private var wasExpanded = false
    @State private var selectedEvent: EventModel?
    @State private var isQuickAdding = false
    @State private var isShowingWeather = false
    @State private var isSearching = false
    @State private var isPointerInside = false
    /// The key monitor for shortcuts, while the calendar has the keyboard.
    @State private var shortcutMonitor: Any?
    /// What search looks through; nil while it loads.
    @State private var searchable: [EventModel]?
    @State private var creating: Creating?
    /// A Google task open to edit.
    @State private var editingTask: GoogleTask?
    /// Where the pointer is, for ⌘V. A plain box so moving the pointer
    /// doesn't redraw the tab.
    @State private var pointer = PointerSpot()
    @State private var newRange: NewRange?
    @State private var isHoveringHandle = false
    @State private var activeDrag: ActiveDrag?
    @State private var preview: Preview?
    /// A repeating event that's been dragged, waiting on which occurrences
    /// to move; its block stays where it was dropped meanwhile.
    @State private var pendingMove: PendingMove?

    /// A press on a block, from mouse-down until release.
    private struct ActiveDrag {
        let item: DayTimelineLayout.Placed
        let mode: DayTimelineLayout.DragMode
        let startPoint: CGPoint
        var moved = false
    }

    /// A new event being dragged out on an empty part of the day, in
    /// seconds from the day's start. `anchor` is where the press landed.
    private struct Creating {
        let anchor: TimeInterval
        let startPoint: CGPoint
        /// Week view: the day column the press landed in.
        let dayIndex: Int
        var start: TimeInterval
        var end: TimeInterval
        var moved = false
    }

    /// The span a new event will cover, held while its box is open.
    private struct NewRange: Equatable {
        let start: TimeInterval
        let end: TimeInterval
        var dayIndex = 0
    }

    /// Where the dragged block is shown, until the calendar confirms it.
    private struct Preview {
        let id: String
        var start: TimeInterval
        var end: TimeInterval
        /// Week view: a move can carry it to another day's column.
        var dayIndex = 0
    }

    private struct PendingMove: Equatable {
        let event: EventModel
        let start: Date
        let end: Date
    }

    private static let edgeGrab: CGFloat = 12
    private static let dragThreshold: CGFloat = 4

    private static let hourWidth: CGFloat = 96
    private static let hourRowHeight: CGFloat = 14
    private static let laneSpacing: CGFloat = 3
    private static let collapsedLaneHeight: CGFloat = 24
    private static let expandedLaneHeight: CGFloat = 40
    private static let collapsedLaneCount = 3
    private static let maxExpandedLaneCount = 6
    /// Where "now" lands when the tab opens, as a fraction of the width —
    /// enough of the morning to see what just happened, most of the view
    /// left for what's next.
    private static let nowAnchor: CGFloat = 1.0 / 3

    // Vertical view.
    private static let hourHeight: CGFloat = 40
    private static let gutterWidth: CGFloat = 34
    /// A block is never shorter than this, so its title stays readable.
    private static let minBlockHeight: CGFloat = 14
    /// Extra height over the strip's, so the day reaches the notch's lower edge.
    private static let verticalFillHeight: CGFloat = 30
    /// How much taller the expand button makes the vertical view before
    /// any size has been dragged to.
    private static let verticalExtraHeight: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if hasAllDayRow {
                allDayChips
                    .frame(height: Self.allDayRowHeight, alignment: .leading)
            }
            if hasTasks {
                tasksStrip
            }
            ZStack(alignment: .top) {
                // Keyed by the span, so Day, Week and Month switch the way days do.
                Group {
                    if span == .month {
                        monthView
                    } else if isColumns {
                        VStack(spacing: Self.weekHeaderSpacing) {
                            if span.isMultiDay { weekHeaderRow }
                            verticalTimeline
                        }
                    } else {
                        timeline
                    }
                }
                .id(span)
                .transition(dayTransition)
            }
                // Hung just under the strip, where there's room you can
                // see: the view's own bottom edge runs past the notch's
                // visible edge, so a message pinned there is drawn out of
                // sight. The vertical day runs almost to that edge, so
                // there it sits inside the timeline's corner instead.
                .overlay(alignment: .bottomTrailing) {
                    undoToast
                        .alignmentGuide(.bottom) { isTall ? $0[.bottom] + 12 : $0[.top] - 4 }
                        .padding(.trailing, 10)
                }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onHover { inside in
            isPointerInside = inside
            updateShortcutFocus()
        }
        .onChange(of: isOverlayOpen) { updateShortcutFocus() }
        // On the whole tab's bottom edge, not the timeline's, so it sits
        // near the notch's edge and its mouse area is always inside the
        // panel, at any height.
        .overlay(alignment: .bottom) {
            if isTall && selectedEvent == nil && !isQuickAdding && newRange == nil && pendingMove == nil && !isShowingWeather && !isSearching {
                resizeHandle
            }
        }
        .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.2), value: calendarManager.undoMessage)
        .overlay { detailsOverlay }
        .overlay { quickAddOverlay }
        .overlay { newEventOverlay }
        .overlay { moveScopeOverlay }
        .overlay { weatherOverlay }
        .overlay { searchOverlay }
        .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.18), value: isSearching)
        .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.18), value: isShowingWeather)
        .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.18), value: pendingMove)
        .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.18), value: newRange)
        .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.18), value: isQuickAdding)
        .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.18), value: selectedEvent?.id)
        .onChange(of: calendarManager.events) { refreshSelected() }
        .onChange(of: googleCalendar.colors) { refreshSelected() }
        .onAppear {
            restoreSize()
            calendarManager.beginLiveRefresh()
            show(Calendar.current.startOfDay(for: .now))
            weather.refreshIfStale()
            Task { await calendarManager.requestAccessForTab() }
        }
        .onDisappear {
            selectedEvent = nil
            isQuickAdding = false
            isShowingWeather = false
            isSearching = false
            isPointerInside = false
            updateShortcutFocus()
            creating = nil
            newRange = nil
            // Leaving the tab ends the undo window: waiting deletes happen now.
            calendarManager.closeUndoWindow()
            calendarManager.endLiveRefresh()
            vm.isHoveringCalendar = false
            isExpanded = false
            verticalExtra = 0
            vm.isResizingNotch = false
            // A quick close-and-reopen can mount the next calendar before this
            // one finishes leaving; don't shrink the panel out from under it.
            if !(vm.notchState == .open && vm.coordinator.currentView == .calendar) {
                vm.setExtraContentHeight(0)
            }
        }
        // Closing shrinks the panel back to normal, so the calendar's own
        // size has to follow, or reopening shows the old size in a short panel.
        .onChange(of: vm.notchState) {
            guard vm.notchState == .open else {
                resetSize()
                return
            }
            restoreSize()
        }
        // Switching to another tab and straight back can keep this view
        // without an onAppear or onDisappear, while the other tab has
        // already shrunk the panel. So if anything else changes the panel's
        // height, drop back to the normal size and ask for that again.
        .onChange(of: vm.extraContentHeight) {
            guard vm.extraContentHeight != desiredExtraHeight, resizeStartExtra == nil else { return }
            resetSize()
            if vm.notchState == .open && vm.coordinator.currentView == .calendar {
                restoreSize()
            }
        }
        .onChange(of: visibleLaneCount) { applyExtraHeight() }
        .onChange(of: isVertical) {
            verticalExtra = 0
            isExpanded = false
            wasExpanded = false
            applyExtraHeight()
        }
        .onChange(of: hasTasks) { applyExtraHeight() }
        .onChange(of: hasAllDayRow) { applyExtraHeight() }
        // Google tasks for the days on screen, refreshed while the tab is open.
        .modifier(TabWatchers(tasksKey: tasksKey, keepTasksLoaded: keepTasksLoaded, onTimeZoneChange: followTimeZone,
                             editingTaskID: editingTask?.id))
    }

    /// The Mac moved to another time zone: days start at the new midnight,
    /// so re-anchor the day shown (midday keeps it the same date) and reload.
    private func followTimeZone() {
        NSTimeZone.resetSystemTimeZone()
        show(Calendar.current.startOfDay(for: day.addingTimeInterval(Self.halfDay)))
    }

    private static let halfDay: TimeInterval = 12 * 3600

    /// Tasks are already in memory from launch; opening the tab (or signing
    /// in) just asks for a fresh copy in the background.
    private var tasksKey: String {
        "\(googleTasks.isSignedIn)"
    }

    private func keepTasksLoaded() async {
        googleTasks.startRefreshing()
        await googleTasks.reload()
    }

    // MARK: - Data

    private var dayLength: TimeInterval {
        let next = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        return next.timeIntervalSince(day)
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(day)
    }

    /// Four days or the week run top to bottom in day columns, like the vertical day.
    private var isColumns: Bool {
        span.isMultiDay || (span == .day && isVertical)
    }

    /// Week and month need height, like the vertical day.
    private var isTall: Bool {
        span != .day || isVertical
    }

    /// One column for the day, four or seven for the multi-day views.
    private var columnDays: [Date] {
        span.isMultiDay ? CalendarGrid.days(for: span, around: day) : [day]
    }

    /// Whether today is on screen, so the Today button can hide.
    private var showsToday: Bool {
        switch span {
        case .day: isToday
        case .fourDays, .week: columnDays.contains { Calendar.current.isDateInToday($0) }
        case .month: Calendar.current.isDate(day, equalTo: .now, toGranularity: .month)
        }
    }

    private func columnDay(_ index: Int) -> Date {
        columnDays.indices.contains(index) ? columnDays[index] : day
    }

    /// Which column today is in, if it's showing.
    private var todayColumn: Int? {
        columnDays.firstIndex { Calendar.current.isDateInToday($0) }
    }

    /// The shown events, in the colors set on Google where there are any.
    private var events: [EventModel] {
        let colors = googleCalendar.colors
        return EventListView.filteredEvents(events: calendarManager.events).map { event in
            guard let uid = event.externalID,
                  let color = colors[GoogleCalendarFormat.key(uid: uid, start: event.start)] else { return event }
            return event.recolored(color.color)
        }
    }

    /// Fetches the Google event colors for the days now showing. In the
    /// background: the switch doesn't wait on the network.
    private func loadColors(for shown: [Date]) {
        guard googleCalendar.isAvailable, let first = shown.first, let last = shown.last,
              let end = Calendar.current.date(byAdding: .day, value: 1, to: last) else { return }
        Task { await googleCalendar.loadColors(from: first, to: end, calendars: calendarManager.shownCalendars) }
    }

    private var allDayEvents: [EventModel] {
        events.filter(\.isAllDay)
    }

    private var placed: [DayTimelineLayout.Placed] {
        let timed = events.filter { !$0.isAllDay }
        guard isColumns else {
            return DayTimelineLayout.place(timed + taskBlocks(on: day), dayStart: day, dayLength: dayLength)
        }
        let footprint = TimeInterval(Self.minBlockHeight / Self.hourHeight) * 3600
        return columnDays.enumerated().flatMap { index, columnDay in
            DayTimelineLayout.columns(timed + taskBlocks(on: columnDay), dayStart: columnDay, dayLength: dayLength, footprint: footprint)
                .map { item in
                    var item = item
                    item.dayIndex = index
                    return item
                }
        }
    }

    // MARK: - Tasks on the grid

    /// Tasks with only a day sit in the row above the hours (in the day
    /// view) or under the date (in the week), the way Google shows them.
    private func untimedTasks(on columnDay: Date) -> [GoogleTask] {
        googleTasks.tasks(on: columnDay).filter { $0.minutes == nil }
    }

    private static let taskBlockPrefix = "gtask:"
    private static let tasksCalendar = CalendarModel(
        id: "google-tasks", account: "Google", title: "Tasks", color: .systemBlue,
        isSubscribed: false, isReminder: true
    )

    /// Tasks given a time in Chora, as blocks at that time. Shaped like a
    /// reminder: it can be clicked, not dragged.
    private func taskBlocks(on columnDay: Date) -> [EventModel] {
        googleTasks.tasks(on: columnDay).compactMap { task in
            guard let start = task.timedStart else { return nil }
            return EventModel(
                id: Self.taskBlockPrefix + task.id, start: start, end: start,
                title: (task.isCompleted ? "✓ " : "○ ") + task.title,
                location: nil, notes: task.notes, url: nil, isAllDay: false,
                type: .reminder(completed: task.isCompleted), calendar: Self.tasksCalendar,
                participants: [], timeZone: nil, hasRecurrenceRules: false, priority: nil
            )
        }
    }

    /// Clicking a block opens its task box if it's a task, else the event's.
    private func open(block event: EventModel) {
        guard event.id.hasPrefix(Self.taskBlockPrefix) else {
            selectedEvent = event
            return
        }
        let id = String(event.id.dropFirst(Self.taskBlockPrefix.count))
        editingTask = googleTasks.tasks.first { $0.id == id }
    }

    private var laneCount: Int {
        (placed.map(\.lane).max() ?? -1) + 1
    }

    private var visibleLaneCount: Int {
        isExpanded
            ? min(max(laneCount, Self.collapsedLaneCount), Self.maxExpandedLaneCount)
            : Self.collapsedLaneCount
    }

    private var laneHeight: CGFloat {
        isExpanded ? Self.expandedLaneHeight : Self.collapsedLaneHeight
    }

    /// The day view's strip of tasks, there whenever signed in to Google so
    /// it doesn't come and go between days; the other views show them per day.
    private var hasTasks: Bool {
        span == .day && googleTasks.isSignedIn
    }

    /// The day's all-day events sit on a row of their own under the header.
    private static let allDayRowHeight: CGFloat = 18
    private var hasAllDayRow: Bool {
        span == .day && !allDayEvents.isEmpty
    }

    /// Height the notch grows by for the rows under the header, spacing included.
    private var stripsHeight: CGFloat {
        (hasTasks ? Self.tasksStripHeight + 6 : 0) + (hasAllDayRow ? Self.allDayRowHeight + 6 : 0)
    }

    private var hiddenCount: Int {
        guard !isTall else { return 0 }
        return placed.filter { $0.lane >= visibleLaneCount }.count
    }

    private var trackWidth: CGFloat {
        CGFloat(dayLength / 3600) * Self.hourWidth
    }

    /// Points per hour along the time axis, whichever way it runs.
    private var hourSize: CGFloat {
        isColumns ? Self.hourHeight : Self.hourWidth
    }

    private func position(for seconds: TimeInterval) -> CGFloat {
        CGFloat(seconds / 3600) * hourSize
    }

    private var trackLength: CGFloat {
        position(for: dayLength)
    }

    private var viewportLength: CGFloat {
        isColumns ? viewportSize.height : viewportSize.width
    }

    private static func lanesHeight(count: Int, laneHeight: CGFloat) -> CGFloat {
        CGFloat(count) * laneHeight + CGFloat(max(0, count - 1)) * laneSpacing
    }

    private var lanesHeight: CGFloat {
        Self.lanesHeight(count: visibleLaneCount, laneHeight: laneHeight)
    }

    private func x(for seconds: TimeInterval) -> CGFloat {
        CGFloat(seconds / 3600) * Self.hourWidth
    }

    private func laneY(_ lane: Int) -> CGFloat {
        Self.hourRowHeight + CGFloat(lane) * (laneHeight + Self.laneSpacing)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            navButton("chevron.left") { step(by: -1) }
            Text(headerTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
            navButton("chevron.right") { step(by: 1) }

            if !showsToday {
                Button {
                    show(Calendar.current.startOfDay(for: .now))
                } label: {
                    // Outlined, like Google Calendar's Today button.
                    Text("Today")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .frame(height: 18)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.45), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            if span == .day {
                weatherLabel
                    .padding(.leading, 2)
            }

            Spacer(minLength: 0)

            if calendarManager.undoFailed {
                Text("Couldn't undo that")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
            }
            if hiddenCount > 0 {
                Text("\(hiddenCount) more")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.gray)
            }
            // Before the picker, so the picker stays put when this hides.
            if span == .day {
                orientationButton
            }
            spanPicker
            searchButton
            quickAddButton
            expandButton
        }
        .frame(height: 22)
    }

    private func navButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.gray)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static let maxAllDayChips = 2

    /// "Tue, Nov 17", "Nov 16 – 22", or "November 2026".
    private var headerTitle: String {
        switch span {
        case .day:
            return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .fourDays, .week:
            guard let first = columnDays.first, let last = columnDays.last else { return "" }
            let sameMonth = Calendar.current.isDate(first, equalTo: last, toGranularity: .month)
            let end = sameMonth ? last.formatted(.dateTime.day()) : last.formatted(.dateTime.month(.abbreviated).day())
            return "\(first.formatted(.dateTime.month(.abbreviated).day())) – \(end)"
        case .month:
            return day.formatted(.dateTime.month(.wide).year())
        }
    }

    /// The shown day's weather: today's has the temperature now and when
    /// rain starts; another day's has its chance of rain when it's likely.
    @ViewBuilder
    private var weatherLabel: some View {
        if let forecast = weather.forecast, let today = forecast.days[day] {
            let now = isToday ? forecast.currentTemperature.map { "\($0)° · " } ?? "" : ""
            let rain = isToday
                ? forecast.rainNote
                : (today.rainChance >= WeatherForecast.rainLikely ? "Rain \(today.rainChance)%" : nil)
            Button { isShowingWeather = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: today.symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 10))
                    Text("\(now)\(today.high)°/\(today.low)°")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .monospacedDigit()
                    if let rain {
                        Text(rain)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.cyan)
                    }
                }
                .lineLimit(1)
                .fixedSize()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show the forecast")
        }
    }

    /// Gone from the calendar (deleted here or elsewhere): close its box.
    /// Changed (edited here or elsewhere, or recolored): show the new version.
    private func refreshSelected() {
        guard let selected = selectedEvent else { return }
        // A new time from the box itself moves the start, so fall back
        // to the identifier alone.
        let shown = events
        let fresh = shown.first { $0.id == selected.id && $0.start == selected.start }
            ?? shown.first { $0.id == selected.id }
        if fresh != selected { selectedEvent = fresh }
    }

    // MARK: - Keyboard shortcuts

    /// A card or prompt is up; it has the keyboard, not the shortcuts.
    private var isOverlayOpen: Bool {
        selectedEvent != nil || editingTask != nil || isQuickAdding || newRange != nil || pendingMove != nil || isShowingWeather || isSearching
    }

    /// Google Calendar's keys work while the pointer is over the calendar
    /// and nothing's open on top of it. Moving away hands the keyboard back
    /// to the app you were in. A card that opens takes the keyboard over
    /// itself and gives it back when it closes, so this only takes it back
    /// once that's done.
    private func updateShortcutFocus() {
        let wantsKeys = isPointerInside && !isOverlayOpen
        if wantsKeys == (shortcutMonitor != nil) { return }
        if let monitor = shortcutMonitor {
            NSEvent.removeMonitor(monitor)
            shortcutMonitor = nil
            if !isOverlayOpen { NotchKeyboardFocus.end() }
            return
        }
        // After a closing card has given the keyboard back.
        DispatchQueue.main.async {
            guard isPointerInside, !isOverlayOpen, shortcutMonitor == nil else { return }
            NotchKeyboardFocus.begin(holdsNotchOpen: false)
            shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { key in
                handleShortcut(key) ? nil : key
            }
        }
    }

    /// C new event, T today, J/K or arrows forward/back, D/X/W/M the
    /// views, / search, ⌘V paste a copied event. Anything else held with
    /// ⌘, ⌃ or ⌥ passes through.
    @MainActor
    private func handleShortcut(_ key: NSEvent) -> Bool {
        if key.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           key.charactersIgnoringModifiers?.lowercased() == "z" {
            Task { await calendarManager.undoLastChange() }
            return true
        }
        if key.modifierFlags.intersection([.command, .control, .option]) == .command,
           key.charactersIgnoringModifiers?.lowercased() == "v",
           let copied = EventClipboard.copied {
            paste(copied)
            return true
        }
        guard key.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch key.keyCode {
        case Self.leftArrowKey: step(by: -1); return true
        case Self.rightArrowKey: step(by: 1); return true
        default: break
        }
        switch key.charactersIgnoringModifiers?.lowercased() {
        case "c": isQuickAdding = true
        case "t": show(Calendar.current.startOfDay(for: .now))
        case "j", "n": step(by: 1)
        case "k", "p": step(by: -1)
        case "d": setSpan(.day)
        case "x": setSpan(.fourDays)
        case "w": setSpan(.week)
        case "m": setSpan(.month)
        case "/": openSearch()
        default: return false
        }
        return true
    }

    /// At the slot under the pointer; over a month day, that day at the
    /// copy's own time; anywhere else, the first day on screen at that time.
    private func paste(_ copied: CopiedEvent) {
        let targetDay: Date
        var slot: TimeInterval?
        if span == .month {
            targetDay = pointer.monthDay ?? day
        } else if let point = pointer.point {
            targetDay = columnDay(isColumns ? dayIndex(at: point) : 0)
            slot = time(at: point)
        } else {
            targetDay = columnDay(0)
        }
        let times = copied.pasteTimes(on: targetDay, slot: slot, snap: DayTimelineLayout.snap)
        Task { _ = await calendarManager.pasteEvent(copied, start: times.start, end: times.end) }
    }

    private static let leftArrowKey: UInt16 = 123
    private static let rightArrowKey: UInt16 = 124

    private var searchButton: some View {
        Button(action: openSearch) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color(nsColor: .secondarySystemFill)))
        }
        .buttonStyle(.plain)
        .help("Search events")
    }

    private func openSearch() {
        selectedEvent = nil
        searchable = nil
        isSearching = true
        Task { searchable = await calendarManager.searchableEvents() }
    }

    @ViewBuilder
    private var searchOverlay: some View {
        if isSearching {
            ZStack {
                Color.black.opacity(0.55)
                    .contentShape(Rectangle())
                    .onTapGesture { isSearching = false }
                SearchCard(
                    events: searchable,
                    onPick: { event in
                        isSearching = false
                        let eventDay = Calendar.current.startOfDay(for: event.start)
                        // Its box opens once the day has loaded, so the load can't close it.
                        if span == .day { show(eventDay, thenOpen: event) } else { setSpan(.day, day: eventDay, thenOpen: event) }
                    },
                    onClose: { isSearching = false }
                )
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var weatherOverlay: some View {
        if isShowingWeather, let forecast = weather.forecast {
            ZStack {
                Color.black.opacity(0.55)
                    .contentShape(Rectangle())
                    .onTapGesture { isShowingWeather = false }
                WeatherCard(forecast: forecast, onClose: { isShowingWeather = false })
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            .transition(.opacity)
        }
    }

    /// Day, Week, Month, like Google Calendar's view switch.
    private var spanPicker: some View {
        HStack(spacing: 0) {
            ForEach(CalendarSpan.allCases, id: \.self) { option in
                Button { setSpan(option) } label: {
                    Text(option.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(span == option ? .white : .gray)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(Capsule().fill(span == option ? Color(nsColor: .secondarySystemFill) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }

    /// Like `show`: loads the new span's events first, then crossfades to
    /// it, so it never appears empty and then fills in.
    @MainActor
    private func setSpan(_ option: CalendarSpan, day newDay: Date? = nil, thenOpen event: EventModel? = nil) {
        guard option != span else { return }
        let target = newDay ?? day
        preview = nil
        activeDrag = nil
        creating = nil
        newRange = nil
        requestedSpan = option
        requestedDay = target
        let shown = CalendarGrid.days(for: option, around: target)
        Task {
            await calendarManager.load(from: shown.first ?? target, days: shown.count)
            // A later click has taken over; its own load will finish.
            guard requestedSpan == option, requestedDay == target else { return }
            requestedSpan = nil
            requestedDay = nil
            // Day → Week → Month drifts in from the right; back, from the left.
            let order = CalendarSpan.allCases
            dayDirection = (order.firstIndex(of: option) ?? 0) > (order.firstIndex(of: span) ?? 0) ? 1 : -1
            // The new layout measures itself as it appears, then scrolls to now.
            viewportSize = .zero
            withAnimation(Self.daySwitch) {
                span = option
                day = target
            }
            restoreSize()
            loadColors(for: shown)
            if let event { selectLoaded(event) }
        }
    }

    /// The loaded copy of an event, in its box.
    private func selectLoaded(_ event: EventModel) {
        selectedEvent = events.first { $0.id == event.id && $0.start == event.start } ?? event
    }

    /// From the month or a week's day header: that day on its own.
    @MainActor
    private func openDay(_ date: Date) {
        setSpan(.day, day: Calendar.current.startOfDay(for: date))
    }

    /// Each day of the week: its name and date (click to open it), its
    /// weather, and its first all-day event.
    private var weekHeaderRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.gutterWidth)
            ForEach(columnDays, id: \.self) { columnDay in
                weekHeaderCell(columnDay)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: weekHeaderHeight, alignment: .top)
    }

    private func weekHeaderCell(_ columnDay: Date) -> some View {
        let isToday = Calendar.current.isDateInToday(columnDay)
        let allDay = CalendarGrid.events(on: columnDay, from: allDayEvents)
        return VStack(spacing: 2) {
            Button { openDay(columnDay) } label: {
                HStack(spacing: 3) {
                    Text(columnDay.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.gray)
                    Text(columnDay.formatted(.dateTime.day()))
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Circle().fill(isToday ? Color.accentColor : .clear))
                }
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(columnDay.formatted(date: .complete, time: .omitted))")
            if let dayWeather = weather.forecast?.days[columnDay] {
                HStack(spacing: 3) {
                    Image(systemName: dayWeather.symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 10))
                    Text("\(dayWeather.high)°/\(dayWeather.low)°")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .monospacedDigit()
                }
                .lineLimit(1)
            }
            if let first = allDay.first {
                let color = Color(nsColor: first.calendar.color)
                Text(allDay.count > 1 ? "\(first.title) +\(allDay.count - 1)" : first.title)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, minHeight: 13, maxHeight: 13)
                    .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.3)))
                    .padding(.horizontal, 2)
                    .onTapGesture { selectedEvent = first }
            }
            weekTaskLine(columnDay)
        }
    }

    /// The day's first task, its circle ticks it off; "+2" opens the day,
    /// where the strip shows them all.
    @ViewBuilder
    private func weekTaskLine(_ columnDay: Date) -> some View {
        let tasks = untimedTasks(on: columnDay)
        if let first = tasks.first {
            HStack(spacing: 3) {
                Button {
                    Task { await googleTasks.setCompleted(first, !first.isCompleted) }
                } label: {
                    Image(systemName: first.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 9))
                        .foregroundStyle(first.isCompleted ? .green : .gray)
                }
                .buttonStyle(.plain)
                .help(first.isCompleted ? "Mark not done" : "Mark done")
                Button { editingTask = first } label: {
                    Text(first.title)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(first.isCompleted ? .gray : .white)
                        .strikethrough(first.isCompleted)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Edit task")
                Spacer(minLength: 0)
                if tasks.count > 1 {
                    Button { openDay(columnDay) } label: {
                        Text("+\(tasks.count - 1)")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.gray)
                    }
                    .buttonStyle(.plain)
                    .help("Open the day to see all its tasks")
                }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 13, maxHeight: 13)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: .secondarySystemFill)))
            .padding(.horizontal, 2)
        }
    }

    /// The month grid, as tall as the vertical day; it crossfades between
    /// months the way the day does between days.
    private var monthView: some View {
        ZStack(alignment: .topLeading) {
            CalendarMonthView(
                days: CalendarGrid.month(containing: day),
                month: day,
                events: events,
                tasks: googleTasks.tasks,
                weather: weather.forecast?.days ?? [:],
                onOpenDay: openDay,
                onToggleTask: { task in
                    Task { await googleTasks.setCompleted(task, !task.isCompleted) }
                },
                onOpenTask: { editingTask = $0 },
                onHoverDay: { hoveredDay, isInside in
                    // Leaving one day can be heard after entering the next.
                    if isInside {
                        pointer.monthDay = hoveredDay
                    } else if pointer.monthDay == hoveredDay {
                        pointer.monthDay = nil
                    }
                }
            )
            .id(day)
            .transition(dayTransition)
        }
        .frame(height: verticalTimelineHeight)
        .clipped()
    }

    private var allDayChips: some View {
        HStack(spacing: 4) {
            ForEach(allDayEvents.prefix(Self.maxAllDayChips)) { event in
                let color = Color(nsColor: event.calendar.color)
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(event.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 7)
                .frame(maxWidth: 130, minHeight: 18, maxHeight: 18)
                .background(Capsule().fill(color.opacity(0.22)))
                .onTapGesture { selectedEvent = event }
            }
            if allDayEvents.count > Self.maxAllDayChips {
                Text("+\(allDayEvents.count - Self.maxAllDayChips)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.gray)
            }
        }
    }

    /// Says what the last change saved, with Undo beside it, like Google
    /// Calendar's. Undo takes changes back one at a time, newest first; the
    /// x keeps everything as it is.
    @ViewBuilder
    private var undoToast: some View {
        if let message = calendarManager.undoMessage {
            HStack(spacing: 10) {
                Text(message)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Button {
                    Task { await calendarManager.undoLastChange() }
                } label: {
                    Text("Undo")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.effectiveAccent)
                }
                .buttonStyle(.plain)
                Button {
                    calendarManager.closeUndoWindow()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.gray)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 22)
            .background(
                Capsule()
                    .fill(Color(white: 0.14))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
            )
            .transition(.opacity.combined(with: .offset(y: 4)))
        }
    }

    /// Shows the layout it switches to: stacked rows for the day running
    /// down, side-by-side columns for the strip running across.
    /// Opens a box for typing an event in plain words.
    private var quickAddButton: some View {
        Button {
            selectedEvent = nil
            isQuickAdding = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color(nsColor: .secondarySystemFill)))
        }
        .buttonStyle(.plain)
        .help("Add an event")
    }

    @ViewBuilder
    private var quickAddOverlay: some View {
        if isQuickAdding {
            ZStack {
                Color.black.opacity(0.55)
                    .contentShape(Rectangle())
                    .onTapGesture { isQuickAdding = false }
                QuickAddCard(
                    day: day,
                    calendarTitle: calendarManager.newEventCalendarTitle,
                    onAdd: { result in
                        let added = await calendarManager.createEvent(title: result.title, start: result.start, end: result.end)
                        if added { show(Calendar.current.startOfDay(for: result.start)) }
                        return added
                    },
                    onClose: { isQuickAdding = false }
                )
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            .transition(.opacity)
        }
    }

    private var orientationButton: some View {
        Button(action: toggleOrientation) {
            Image(systemName: isVertical ? "rectangle.split.3x1" : "rectangle.split.1x2")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color(nsColor: .secondarySystemFill)))
        }
        .buttonStyle(.plain)
        .help(isVertical ? "Show the day across" : "Show the day down")
    }

    /// Vertical view: anything taller than normal counts as expanded, so a
    /// drag on the bottom edge turns this into the shrink button.
    private var showsExpanded: Bool {
        isTall ? verticalExtra > 0 : isExpanded
    }

    /// A grabber on the notch's bottom edge: drag it to make the day taller
    /// or shorter.
    private var resizeHandle: some View {
        Capsule()
            .fill(.white.opacity(resizeStartExtra == nil ? 0.3 : 0.55))
            .frame(width: 56, height: 6)
            // The grab area: just the pill and a little around it, so the
            // arrows only show over the pill itself.
            .frame(width: Self.handleGrabSize.width, height: Self.handleGrabSize.height)
            .contentShape(Rectangle())
            .overlay {
                NotchResizeCapture(
                    onBegin: beginResize,
                    onDrag: resize(by:),
                    onEnd: endResize
                )
            }
            // The AppKit view never hears the pointer move over it here, so
            // the arrows come from SwiftUI's hover. Re-claimed on every move,
            // or the timeline above takes the cursor back and it flickers.
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isHoveringHandle = true
                    CursorLock.claim(Self.handleCursorOwner) { _ in .resizeUpDown }
                    NSCursor.resizeUpDown.set()
                case .ended:
                    isHoveringHandle = false
                    if resizeStartExtra == nil { releaseHandleCursor() }
                }
            }
            .frame(maxWidth: .infinity)
            // Into the black strip under the timeline, clear of its events.
            .padding(.bottom, -4)
    }

    private static let handleGrabSize = CGSize(width: 80, height: 16)

    private func releaseHandleCursor() {
        CursorLock.release(Self.handleCursorOwner)
        NSCursor.arrow.set()
    }

    /// Stands in for the grabber when it holds the cursor.
    private static let handleCursorOwner = NSObject()

    /// Same pair of symbols as the clipboard's expand button.
    private var expandButton: some View {
        Button(action: toggleExpanded) {
            Image(systemName: showsExpanded
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color(nsColor: .secondarySystemFill)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tasks

    private static let tasksStripHeight: CGFloat = 22

    private var tasksStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if untimedTasks(on: day).isEmpty {
                    Text("No tasks due")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.gray)
                        .padding(.horizontal, 4)
                }
                // The circle ticks a task off; its title opens it to edit.
                ForEach(untimedTasks(on: day)) { task in
                    HStack(spacing: 5) {
                        Button {
                            Task { await googleTasks.setCompleted(task, !task.isCompleted) }
                        } label: {
                            Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 11))
                                .foregroundStyle(task.isCompleted ? .green : .gray)
                        }
                        .buttonStyle(.plain)
                        .help(task.isCompleted ? "Mark not done" : "Mark done")
                        Button { editingTask = task } label: {
                            Text(task.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(task.isCompleted ? .gray : .white)
                                .strikethrough(task.isCompleted)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .help("Edit task")
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Capsule().fill(Color(nsColor: .secondarySystemFill)))
                }
            }
        }
        .frame(height: Self.tasksStripHeight)
        .onHover { vm.isHoveringCalendar = $0 }
    }

    // MARK: - Timeline

    private var timeline: some View {
        GeometryReader { geometry in
            TimelineView(.everyMinute) { context in
                ZStack(alignment: .topLeading) {
                    track(now: context.date)
                        .offset(x: -offset)
                        .id(day)
                        .transition(dayTransition)
                }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    .clipped()
                    .mask(edgeFade)
                    .overlay { emptyState }
            }
            .onAppear { setViewportSize(geometry.size) }
            .onChange(of: geometry.size) { _, size in setViewportSize(size) }
        }
        .frame(height: Self.hourRowHeight + lanesHeight)
        // On top of the track so it gets the scroll and click events; see
        // LyricsScrollCapture for why an NSView has to do this.
        .overlay {
            // Off while a details box is up, so clicks reach it and its
            // backdrop instead of the timeline underneath.
            if selectedEvent == nil && editingTask == nil && pendingMove == nil && !isShowingWeather && !isSearching {
                TimelineScrollCapture(
                    isVertical: false,
                    onScroll: scroll(by:),
                    onPress: press(at:),
                    onDrag: drag(to:),
                    onRelease: release(at:in:),
                    cursorAt: cursor(at:),
                    onExit: { pointer.point = nil }
                )
            }
        }
        // Keeps a sideways swipe here scrolling the day instead of
        // switching tabs.
        .onHover { vm.isHoveringCalendar = $0 }
    }

    private func track(now: Date) -> some View {
        let hours = Int(dayLength / 3600)
        let nowSeconds = now.timeIntervalSince(day)
        let showsNow = nowSeconds >= 0 && nowSeconds < dayLength

        return ZStack(alignment: .topLeading) {
            ForEach(0 ..< hours, id: \.self) { hour in
                Text(hourLabel(hour))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.gray)
                    .offset(x: x(for: TimeInterval(hour) * 3600) + 4)
                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(width: 1, height: Self.hourRowHeight + lanesHeight)
                    .offset(x: x(for: TimeInterval(hour) * 3600))
            }

            ForEach(placed.filter { $0.lane < visibleLaneCount }) { item in
                let shown = preview?.id == item.id ? preview : nil
                let start = shown?.start ?? item.start
                let end = shown?.end ?? item.end
                TimelineEventBlock(
                    event: item.event,
                    isCurrent: item.event.start <= now && now < item.event.end,
                    isExpanded: isExpanded,
                    previewRange: shown.map { (day.addingTimeInterval($0.start), day.addingTimeInterval($0.end)) },
                    showsGrips: x(for: end) - x(for: start) > 48
                )
                .frame(width: max(4, x(for: end) - x(for: start) - 2), height: laneHeight)
                .offset(x: x(for: start) + 1, y: laneY(item.lane))
                .zIndex(shown == nil ? 0 : 1)
            }

            if let ghost = ghostRange {
                ghostBlock(ghost)
                    .frame(width: max(4, x(for: ghost.end) - x(for: ghost.start) - 2), height: lanesHeight)
                    .offset(x: x(for: ghost.start) + 1, y: Self.hourRowHeight)
                    .zIndex(2)
            }

            if showsNow {
                // Time already gone, dimmed.
                Rectangle()
                    .fill(.black.opacity(0.4))
                    .frame(width: x(for: nowSeconds), height: lanesHeight)
                    .offset(y: Self.hourRowHeight)
                Rectangle()
                    .fill(.red)
                    .frame(width: 1.5, height: lanesHeight + 4)
                    .offset(x: x(for: nowSeconds) - 0.75, y: Self.hourRowHeight - 4)
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                    .offset(x: x(for: nowSeconds) - 3, y: Self.hourRowHeight - 6)
            }
        }
        .frame(width: trackWidth, height: Self.hourRowHeight + lanesHeight, alignment: .topLeading)
    }

    private var edgeFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .white, location: 0.03),
                .init(color: .white, location: 0.97),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: - Vertical timeline

    /// The day names, weather and all-day row over the week's columns.
    private static let baseWeekHeaderHeight: CGFloat = 46
    /// Room for a line of tasks under each day, kept whenever signed in to
    /// Google so the header doesn't change height from week to week.
    private static let weekTaskLineHeight: CGFloat = 15
    private var weekHeaderHeight: CGFloat {
        Self.baseWeekHeaderHeight + (googleTasks.isSignedIn ? Self.weekTaskLineHeight : 0)
    }
    private static let weekHeaderSpacing: CGFloat = 4

    /// The week's columns give up the room its header row takes, so the
    /// week ends where the day does, inside the notch.
    private var columnsHeight: CGFloat {
        verticalTimelineHeight - (span.isMultiDay ? weekHeaderHeight + Self.weekHeaderSpacing : 0)
    }

    private var verticalTimelineHeight: CGFloat {
        // Taller than the strip, which has to leave room for its hour row:
        // a vertical day can use the whole space under the header.
        let base = Self.hourRowHeight
            + Self.lanesHeight(count: Self.collapsedLaneCount, laneHeight: Self.collapsedLaneHeight)
            + Self.verticalFillHeight
        return base + verticalExtra
    }

    private var verticalTimeline: some View {
        GeometryReader { geometry in
            TimelineView(.everyMinute) { context in
                ZStack(alignment: .topLeading) {
                    verticalTrack(now: context.date, width: geometry.size.width)
                        // Clipping hides the hours scrolled above the view but
                        // doesn't stop them taking clicks, and they sit over the
                        // header's buttons. Clicks here go to the capture view.
                        .allowsHitTesting(false)
                        .offset(y: -offset)
                        .id(day)
                        .transition(dayTransition)
                }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    .clipped()
                    .mask(verticalEdgeFade)
                    .overlay { emptyState }
            }
            .onAppear { setViewportSize(geometry.size) }
            .onChange(of: geometry.size) { _, size in setViewportSize(size) }
        }
        .frame(height: columnsHeight)
        .overlay {
            if selectedEvent == nil && editingTask == nil && pendingMove == nil && !isShowingWeather && !isSearching {
                TimelineScrollCapture(
                    isVertical: true,
                    onScroll: scroll(by:),
                    onPress: press(at:),
                    onDrag: drag(to:),
                    onRelease: release(at:in:),
                    cursorAt: cursor(at:),
                    onExit: { pointer.point = nil }
                )
            }
        }
        .onHover { vm.isHoveringCalendar = $0 }
    }

    /// One day's column: the whole width for the day, a seventh for the week.
    private func dayWidth(in width: CGFloat) -> CGFloat {
        max(0, width - Self.gutterWidth) / CGFloat(columnDays.count)
    }

    /// The day column under a point.
    private func dayIndex(at point: CGPoint) -> Int {
        let index = Int((point.x - Self.gutterWidth) / max(1, dayWidth(in: viewportSize.width)))
        return min(max(index, 0), columnDays.count - 1)
    }

    /// Where a block sits in the vertical track, gutter included.
    private func verticalFrame(of item: DayTimelineLayout.Placed, start: TimeInterval,
                               end: TimeInterval, width: CGFloat, dayIndex: Int? = nil) -> CGRect {
        let dayWidth = self.dayWidth(in: width)
        let columnWidth = dayWidth / CGFloat(item.columns)
        let height = max(position(for: end) - position(for: start), Self.minBlockHeight)
        return CGRect(
            x: Self.gutterWidth + CGFloat(dayIndex ?? item.dayIndex) * dayWidth + CGFloat(item.lane) * columnWidth,
            y: position(for: start),
            width: columnWidth,
            height: height
        )
    }

    private func verticalTrack(now: Date, width: CGFloat) -> some View {
        let hours = Int(dayLength / 3600)
        let contentWidth = max(0, width - Self.gutterWidth)
        let dayWidth = dayWidth(in: width)
        // The now line runs across today's column only.
        let nowColumn = todayColumn
        let nowSeconds = now.timeIntervalSince(columnDay(nowColumn ?? 0))
        let showsNow = nowColumn != nil && nowSeconds >= 0 && nowSeconds < dayLength
        let nowX = Self.gutterWidth + CGFloat(nowColumn ?? 0) * dayWidth

        return ZStack(alignment: .topLeading) {
            ForEach(0 ..< hours, id: \.self) { hour in
                Text(hourLabel(hour))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.gray)
                    .frame(width: Self.gutterWidth - 8, alignment: .trailing)
                    .offset(y: position(for: TimeInterval(hour) * 3600) - 6)
                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(width: contentWidth, height: 1)
                    .offset(x: Self.gutterWidth, y: position(for: TimeInterval(hour) * 3600))
            }

            // Lines between the week's days.
            ForEach(1 ..< max(1, columnDays.count), id: \.self) { index in
                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(width: 1, height: trackLength)
                    .offset(x: Self.gutterWidth + CGFloat(index) * dayWidth)
            }

            ForEach(placed) { item in
                let shown = preview?.id == item.id ? preview : nil
                let start = shown?.start ?? item.start
                let end = shown?.end ?? item.end
                let frame = verticalFrame(of: item, start: start, end: end, width: width, dayIndex: shown?.dayIndex)
                let shownDay = columnDay(shown?.dayIndex ?? item.dayIndex)
                TimelineEventBlock(
                    event: item.event,
                    isCurrent: item.event.start <= now && now < item.event.end,
                    isExpanded: frame.height >= 28,
                    previewRange: shown.map { (shownDay.addingTimeInterval($0.start), shownDay.addingTimeInterval($0.end)) },
                    showsGrips: frame.height > 30 && frame.width > 30,
                    isVertical: true
                )
                .frame(width: max(4, frame.width - 2), height: max(4, frame.height - 1))
                .offset(x: frame.minX + 1, y: frame.minY + 0.5)
                .zIndex(shown == nil ? 0 : 1)
            }

            if let ghost = ghostRange {
                ghostBlock(ghost)
                    .frame(width: max(4, dayWidth - 2), height: max(Self.minBlockHeight, position(for: ghost.end) - position(for: ghost.start) - 1))
                    .offset(x: Self.gutterWidth + CGFloat(ghost.dayIndex) * dayWidth + 1, y: position(for: ghost.start) + 0.5)
                    .zIndex(2)
            }

            if showsNow {
                // Time already gone, dimmed.
                Rectangle()
                    .fill(.black.opacity(0.4))
                    .frame(width: dayWidth, height: position(for: nowSeconds))
                    .offset(x: nowX)
                Rectangle()
                    .fill(.red)
                    .frame(width: dayWidth + 4, height: 1.5)
                    .offset(x: nowX - 4, y: position(for: nowSeconds) - 0.75)
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                    .offset(x: nowX - 6, y: position(for: nowSeconds) - 3)
            }
        }
        .frame(width: width, height: trackLength, alignment: .topLeading)
    }

    private var verticalEdgeFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .white, location: 0.05),
                .init(color: .white, location: 0.95),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    @ViewBuilder
    private var emptyState: some View {
        let status = calendarManager.calendarAuthorizationStatus
        if status == .denied || status == .restricted {
            emptyText("Allow calendar access in System Settings › Privacy & Security")
        } else if events.isEmpty {
            emptyText(span == .week ? "No events this week" : span == .fourDays ? "No events these days" : (isToday ? "No events today" : "No events"))
        }
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.gray)
            .padding(.top, Self.hourRowHeight)
            .allowsHitTesting(false)
    }

    private func hourLabel(_ hour: Int) -> String {
        let date = day.addingTimeInterval(TimeInterval(hour) * 3600)
        let clockHour = Calendar.current.component(.hour, from: date)
        let twelveHour = clockHour % 12 == 0 ? 12 : clockHour % 12
        return "\(twelveHour)\(clockHour < 12 ? "am" : "pm")"
    }

    // MARK: - Actions

    /// From the day already asked for, so quick clicks each count.
    private func step(by count: Int) {
        show(CalendarGrid.step(requestedDay ?? day, by: count, span: span))
    }

    /// Loads the events first, then swaps day and events in together. The
    /// week and month load every day they show.
    private func show(_ newDay: Date, thenOpen event: EventModel? = nil) {
        dayDirection = newDay < (requestedDay ?? day) ? -1 : 1
        requestedDay = newDay
        let shown = CalendarGrid.days(for: span, around: newDay)
        Task {
            await calendarManager.load(from: shown.first ?? newDay, days: shown.count)
            // A later click has taken over; its own load will finish.
            guard requestedDay == newDay else { return }
            requestedDay = nil
            withAnimation(Self.daySwitch) { day = newDay }
            scrollToDefault()
            loadColors(for: shown)
            if let event { selectLoaded(event) }
        }
    }

    private func setViewportSize(_ size: CGSize) {
        guard size != viewportSize else { return }
        let isFirst = viewportSize == .zero
        viewportSize = size
        if isFirst {
            scrollToDefault()
        } else {
            offset = clamped(offset)
        }
    }

    /// Today opens on "now"; any other day on its first event, or 8am.
    private func scrollToDefault() {
        guard viewportLength > 0 else { return }
        if let today = todayColumn {
            offset = clamped(position(for: Date.now.timeIntervalSince(columnDay(today))) - viewportLength * Self.nowAnchor)
        } else {
            let first = placed.map(\.start).min() ?? 8 * 3600
            offset = clamped(position(for: first) - hourSize / 2)
        }
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), max(0, trackLength - viewportLength))
    }

    private func scroll(by delta: CGFloat) {
        offset = clamped(offset - delta)
    }

    /// The block under a point, and which part of it: the edges resize,
    /// the middle moves.
    private func hit(at point: CGPoint) -> (item: DayTimelineLayout.Placed, mode: DayTimelineLayout.DragMode)? {
        isColumns ? verticalHit(at: point) : horizontalHit(at: point)
    }

    /// The bottom edge resizes, the rest moves.
    private func verticalHit(at point: CGPoint) -> (item: DayTimelineLayout.Placed, mode: DayTimelineLayout.DragMode)? {
        let trackPoint = CGPoint(x: point.x, y: point.y + offset)
        // Last drawn is on top.
        guard let item = placed.last(where: {
            verticalFrame(of: $0, start: $0.start, end: $0.end, width: viewportSize.width).contains(trackPoint)
        }) else { return nil }

        let frame = verticalFrame(of: item, start: item.start, end: item.end, width: viewportSize.width)
        let grab = min(Self.edgeGrab, frame.height / 3)
        if frame.maxY - trackPoint.y <= grab { return (item, .resizeEnd) }
        return (item, .move)
    }

    /// The right edge resizes, the rest moves.
    private func horizontalHit(at point: CGPoint) -> (item: DayTimelineLayout.Placed, mode: DayTimelineLayout.DragMode)? {
        let trackX = point.x + offset
        let laneStride = laneHeight + Self.laneSpacing
        let y = point.y - Self.hourRowHeight
        guard y >= 0 else { return nil }
        let lane = Int(y / laneStride)
        guard y - CGFloat(lane) * laneStride <= laneHeight else { return nil }
        guard let item = placed.first(where: {
            $0.lane == lane && $0.lane < visibleLaneCount
                && x(for: $0.start) <= trackX && trackX <= x(for: $0.end)
        }) else { return nil }

        let grab = min(Self.edgeGrab, (x(for: item.end) - x(for: item.start)) / 3)
        if x(for: item.end) - trackX <= grab { return (item, .resizeEnd) }
        return (item, .move)
    }

    private func press(at point: CGPoint) {
        guard let found = hit(at: point) else {
            beginCreating(at: point)
            return
        }
        activeDrag = ActiveDrag(item: found.item, mode: found.mode, startPoint: point)
    }

    private func drag(to point: CGPoint) {
        if creating != nil {
            extendCreating(to: point)
            return
        }
        guard var current = activeDrag else { return }
        let dx = point.x - current.startPoint.x
        let dy = point.y - current.startPoint.y
        if !current.moved {
            guard hypot(dx, dy) >= Self.dragThreshold else { return }
            current.moved = true
            activeDrag = current
        }
        // Reminders and the like can be clicked but not rescheduled here.
        guard current.item.event.type.isEvent else { return }

        let span = DayTimelineLayout.adjusted(
            start: current.item.start,
            end: current.item.end,
            mode: current.mode,
            delta: TimeInterval((isColumns ? dy : dx) / hourSize) * 3600,
            dayLength: dayLength
        )
        // In the week, moving sideways carries it to another day.
        var dayIndex = current.item.dayIndex
        if columnDays.count > 1 && current.mode == .move {
            let shift = Int((dx / max(1, dayWidth(in: viewportSize.width))).rounded())
            dayIndex = min(max(dayIndex + shift, 0), columnDays.count - 1)
        }
        preview = Preview(id: current.item.id, start: span.start, end: span.end, dayIndex: dayIndex)
    }

    private func release(at point: CGPoint, in _: NSView) {
        if creating != nil {
            finishCreating()
            return
        }
        guard let finished = activeDrag else { return }
        activeDrag = nil

        guard finished.moved else {
            open(block: finished.item.event)
            return
        }
        guard let moved = preview, moved.id == finished.item.id,
              moved.start != finished.item.start || moved.end != finished.item.end
                || moved.dayIndex != finished.item.dayIndex else {
            preview = nil
            return
        }

        let landedDay = columnDay(moved.dayIndex)
        let move = PendingMove(event: finished.item.event,
                               start: landedDay.addingTimeInterval(moved.start),
                               end: landedDay.addingTimeInterval(moved.end))
        if move.event.hasRecurrenceRules {
            pendingMove = move
        } else {
            commit(move, scope: .thisEvent)
        }
    }

    private func commit(_ move: PendingMove, scope: EventScope) {
        pendingMove = nil
        Task {
            // Held until the calendar has reloaded, so the block doesn't
            // jump back to its old spot for a moment first.
            _ = await calendarManager.moveEvent(move.event, to: move.start, end: move.end, scope: scope)
            preview = nil
        }
    }

    private func cancelPendingMove() {
        pendingMove = nil
        preview = nil
    }

    @ViewBuilder
    private var moveScopeOverlay: some View {
        if let move = pendingMove {
            ZStack {
                Color.black.opacity(0.35)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: cancelPendingMove)
                MoveScopeCard(
                    title: move.event.title,
                    onChoose: { commit(move, scope: $0) },
                    onCancel: cancelPendingMove
                )
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            .transition(.opacity)
        }
    }

    // MARK: - New event by dragging

    /// The time under a point in the timeline, within the day.
    private func time(at point: CGPoint) -> TimeInterval {
        let along = (isColumns ? point.y : point.x) + offset
        return min(max(TimeInterval(along / hourSize) * 3600, 0), dayLength)
    }

    /// A press on empty space starts a new event at the slot under it.
    private func beginCreating(at point: CGPoint) {
        guard selectedEvent == nil, !isQuickAdding, newRange == nil, !isShowingWeather, !isSearching else { return }
        let snap = DayTimelineLayout.snap
        let anchor = min((time(at: point) / snap).rounded(.down) * snap, dayLength - snap)
        let column = isColumns ? dayIndex(at: point) : 0
        creating = Creating(anchor: anchor, startPoint: point, dayIndex: column, start: anchor, end: anchor + snap)
    }

    /// Dragging either way from the press stretches the new event, in
    /// 15-minute steps.
    private func extendCreating(to point: CGPoint) {
        guard var current = creating else { return }
        if !current.moved {
            guard hypot(point.x - current.startPoint.x, point.y - current.startPoint.y) >= Self.dragThreshold else { return }
            current.moved = true
        }
        let snap = DayTimelineLayout.snap
        let at = (time(at: point) / snap).rounded() * snap
        current.start = min(current.anchor, at)
        current.end = min(max(current.anchor + snap, at), dayLength)
        creating = current
    }

    /// Lifting opens the box for the new event. A click without a drag
    /// makes it an hour long, like Google Calendar.
    private func finishCreating() {
        guard let finished = creating else { return }
        creating = nil
        let end = finished.moved ? finished.end : min(finished.anchor + Self.clickEventLength, dayLength)
        newRange = NewRange(start: finished.start, end: end, dayIndex: finished.dayIndex)
    }

    private static let clickEventLength: TimeInterval = 60 * 60

    /// The outline of the event being made: while dragging, then while its
    /// box is open.
    private var ghostRange: NewRange? {
        creating.map { NewRange(start: $0.start, end: $0.end, dayIndex: $0.dayIndex) } ?? newRange
    }

    private func ghostBlock(_ range: NewRange) -> some View {
        let color = Color.accentColor
        let day = columnDay(range.dayIndex)
        return RoundedRectangle(cornerRadius: 5)
            .fill(color.opacity(0.35))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(color, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Text("\(day.addingTimeInterval(range.start).formatted(date: .omitted, time: .shortened)) – \(day.addingTimeInterval(range.end).formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            }
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var newEventOverlay: some View {
        if let range = newRange {
            ZStack {
                Color.black.opacity(0.35)
                    .contentShape(Rectangle())
                    .onTapGesture { newRange = nil }
                NewEventCard(
                    start: columnDay(range.dayIndex).addingTimeInterval(range.start),
                    end: columnDay(range.dayIndex).addingTimeInterval(range.end),
                    calendars: calendarManager.editableEventCalendars,
                    defaultCalendarID: calendarManager.newEventCalendarID,
                    canInvite: googleCalendar.isAvailable,
                    onSave: { details in
                        if !details.guests.isEmpty || details.addsMeet || details.color != nil {
                            return await createOnGoogle(details,
                                                        start: columnDay(range.dayIndex).addingTimeInterval(range.start),
                                                        end: columnDay(range.dayIndex).addingTimeInterval(range.end))
                        }
                        return await calendarManager.createEvent(
                            title: details.title,
                            start: columnDay(range.dayIndex).addingTimeInterval(range.start),
                            end: columnDay(range.dayIndex).addingTimeInterval(range.end),
                            calendarID: details.calendarID,
                            location: details.location,
                            notes: details.notes,
                            repeats: details.repeats,
                            reminderMinutes: details.reminderMinutes
                        )
                    },
                    onClose: { newRange = nil }
                )
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            .transition(.opacity)
        }
    }

    private func cursor(at point: CGPoint) -> NSCursor {
        pointer.point = point
        guard let found = hit(at: point), found.item.event.type.isEvent else { return .arrow }
        switch found.mode {
        case .move: return .openHand
        case .resizeEnd: return isColumns ? .resizeUpDown : .resizeLeftRight
        }
    }

    @ViewBuilder
    private var detailsOverlay: some View {
        if let task = editingTask {
            ZStack {
                Color.black.opacity(0.55)
                    .contentShape(Rectangle())
                    .onTapGesture { editingTask = nil }
                TaskEditCard(
                    task: task,
                    onSave: { title, due, notes, done, minutes in
                        await googleTasks.update(task, title: title, due: due, notes: notes, isCompleted: done, minutes: minutes)
                    },
                    onDelete: { await googleTasks.delete(task) },
                    onClose: { editingTask = nil }
                )
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            .transition(.opacity)
        } else if let event = selectedEvent {
            ZStack {
                Color.black.opacity(0.55)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedEvent = nil }
                EventDetailsCard(
                    event: event,
                    onClose: { selectedEvent = nil },
                    onOpen: { open(event) },
                    onDelete: { scope in await calendarManager.deleteEvent(event, scope: scope) },
                    onEdit: { edit, scope in
                        await calendarManager.updateEvent(event, edit: edit, scope: scope)
                    },
                    onDuplicate: {
                        guard let copy = await calendarManager.duplicateEvent(event) else { return false }
                        selectedEvent = copy
                        return true
                    },
                    onRespond: hasGoogle(event) ? { status in
                        await googleCalendar.respond(to: event, with: status)
                    } : nil,
                    onSetColor: hasGoogle(event) ? { color in
                        await googleCalendar.setColor(color, of: event)
                    } : nil
                )
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            .transition(.opacity)
        }
    }

    /// Whether Google Calendar can find this event: signed in, and it came
    /// from Google with a UID to look it up by.
    private func hasGoogle(_ event: EventModel) -> Bool {
        googleCalendar.isAvailable && event.externalID != nil
    }

    /// Guests, Meet links and colors go through Google; the Mac's calendar picks
    /// the event up on its next sync.
    private func createOnGoogle(_ details: NewEventCard.Details, start: Date, end: Date) async -> Bool {
        guard let model = calendarManager.editableEventCalendars.first(where: { $0.id == details.calendarID }),
              let googleID = await googleCalendar.googleCalendarID(for: model) else { return false }
        let body = GoogleCalendarFormat.newEvent(
            title: details.title, start: start, end: end, isAllDay: false,
            location: details.location, notes: details.notes, guests: details.guests, addsMeet: details.addsMeet,
            repeats: details.repeats, reminderMinutes: details.reminderMinutes, color: details.color
        )
        return await googleCalendar.create(in: googleID, body: body, addsMeet: details.addsMeet)
    }

    private func open(_ event: EventModel) {
        guard let url = event.calendarAppURL() else { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    private func toggleOrientation() {
        preview = nil
        activeDrag = nil
        isVertical.toggle()
        // The other layout measures itself as it appears, then scrolls to now.
        viewportSize = .zero
    }

    /// Room the vertical day can grow into: the screen, less the notch's
    /// own height and the task strip.
    private var maxVerticalExtra: CGFloat {
        let strip = stripsHeight
        guard let screenHeight = getScreenFrame(vm.screenUUID)?.height else { return Self.verticalExtraHeight }
        return max(0, screenHeight - windowSize.height - strip)
    }

    @MainActor
    private func beginResize() {
        resizeStartExtra = verticalExtra
        vm.isResizingNotch = true
    }

    @MainActor
    private func resize(by distance: CGFloat) {
        guard let start = resizeStartExtra else { return }
        let extra = NotchResize.extra(start: start, dragged: distance, maximum: maxVerticalExtra)
        guard extra != verticalExtra else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { verticalExtra = extra }
        let strip = stripsHeight
        vm.setExtraContentHeightImmediately(extra + strip)
    }

    @MainActor
    private func endResize() {
        resizeStartExtra = nil
        vm.isResizingNotch = false
        if !isHoveringHandle { releaseHandleCursor() }
        if verticalExtra > 0 {
            rememberedVerticalExtra = Double(verticalExtra)
        }
        wasExpanded = verticalExtra > 0
    }

    @MainActor
    private func toggleExpanded() {
        guard !isTall else {
            toggleVerticalSize()
            return
        }
        withAnimation(vm.animationLibrary.collapseCurve) {
            isExpanded.toggle()
        }
        wasExpanded = isExpanded
        applyExtraHeight()
    }

    /// Shrinks back to the normal size, remembering the current one, or grows
    /// back to the size it was last dragged to.
    @MainActor
    private func toggleVerticalSize() {
        let target: CGFloat
        if verticalExtra > 0 {
            rememberedVerticalExtra = Double(verticalExtra)
            target = 0
        } else {
            let remembered = CGFloat(rememberedVerticalExtra)
            target = min(remembered > 0 ? remembered : Self.verticalExtraHeight, maxVerticalExtra)
        }
        withAnimation(vm.animationLibrary.collapseCurve) {
            verticalExtra = target
        }
        wasExpanded = target > 0
        applyExtraHeight()
    }

    /// Back to the normal size, without touching the panel: whatever closed
    /// the notch or switched tabs has already shrunk it.
    @MainActor
    private func resetSize() {
        isExpanded = false
        verticalExtra = 0
        resizeStartExtra = nil
        vm.isResizingNotch = false
    }

    /// Back to the size the calendar was left at: expanded or normal, and
    /// in the top-to-bottom view, the height it was last dragged to.
    @MainActor
    private func restoreSize() {
        isExpanded = !isTall && wasExpanded
        // Week and month always open tall: they don't fit the normal height.
        if isTall && (wasExpanded || span != .day) {
            let remembered = CGFloat(rememberedVerticalExtra)
            verticalExtra = min(remembered > 0 ? remembered : Self.verticalExtraHeight, maxVerticalExtra)
        } else {
            verticalExtra = 0
        }
        applyExtraHeight()
    }

    /// The notch grows for the task strip and, expanded, for extra rows —
    /// capped against the screen, like the clipboard's.
    @MainActor
    private func applyExtraHeight() {
        vm.setExtraContentHeight(desiredExtraHeight)
    }

    private var desiredExtraHeight: CGFloat {
        let collapsed = Self.lanesHeight(count: Self.collapsedLaneCount, laneHeight: Self.collapsedLaneHeight)
        let rows = isTall ? verticalExtra : (isExpanded ? max(0, lanesHeight - collapsed) : 0)
        let strip = stripsHeight
        let total = rows + strip
        guard let screenHeight = getScreenFrame(vm.screenUUID)?.height else { return total }
        return min(total, max(0, screenHeight - windowSize.height))
    }
}

private struct TimelineEventBlock: View {
    let event: EventModel
    let isCurrent: Bool
    let isExpanded: Bool
    /// While being dragged: the span it would land on.
    var previewRange: (Date, Date)?
    /// Hidden on blocks too narrow to fit them beside the title.
    var showsGrips = true
    /// In the vertical day: text from the top, the grip on the bottom.
    var isVertical = false

    var body: some View {
        let color = Color(nsColor: event.calendar.color)
        HStack(alignment: isVertical ? .top : .center, spacing: 0) {
            Rectangle()
                .fill(color)
                .frame(width: 3)
            content
                .padding(.horizontal, 5)
                .padding(.top, isVertical ? 1 : 0)
            Spacer(minLength: 0)
        }
        // A grip on the end only: drag it to change the end time.
        .overlay(alignment: isVertical ? .bottom : .trailing) { if showsGrips { grip.padding(isVertical ? .bottom : .trailing, 2) } }
        // Solid, so the hour lines behind don't show through the block.
        .background {
            ZStack {
                Color.black
                color.opacity(isCurrent ? 0.4 : 0.22)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(.white.opacity(previewRange != nil ? 0.8 : (isCurrent ? 0.5 : 0)), lineWidth: 1)
        )
    }

    private var grip: some View {
        Capsule()
            .fill(.white.opacity(0.35))
            .frame(width: isVertical ? 10 : 2.5, height: isVertical ? 2.5 : 10)
    }

    @ViewBuilder
    private var content: some View {
        if isExpanded {
            VStack(alignment: .leading, spacing: 1) {
                title
                time
                if let location = event.location, !location.isEmpty {
                    Text(location)
                        .font(.system(size: 9))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }
            }
        } else {
            HStack(spacing: 4) {
                title
                time
            }
        }
    }

    private var title: some View {
        Text(event.title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    private var timeText: String {
        guard let (start, end) = previewRange else {
            return event.start.formatted(date: .omitted, time: .shortened)
        }
        return "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    private var time: some View {
        Text(timeText)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(1)
    }
}

/// Takes scroll, press, drag and release over the timeline, and sets the
/// cursor. Sideways trackpad swipes scroll as they are; a mouse wheel's
/// vertical notches scroll sideways too, scaled up the same way the lyrics
/// panel does it.
private struct TimelineScrollCapture: NSViewRepresentable {
    var isVertical: Bool
    var onScroll: (CGFloat) -> Void
    var onPress: (CGPoint) -> Void
    var onDrag: (CGPoint) -> Void
    var onRelease: (CGPoint, NSView) -> Void
    var cursorAt: (CGPoint) -> NSCursor
    var onExit: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        update(nsView)
    }

    private func update(_ view: CaptureView) {
        view.isVertical = isVertical
        view.onScroll = onScroll
        view.onPress = onPress
        view.onDrag = onDrag
        view.onRelease = onRelease
        view.cursorAt = cursorAt
        view.onExit = onExit
    }

    final class CaptureView: NSView {
        var isVertical = false
        var onScroll: ((CGFloat) -> Void)?
        var onPress: ((CGPoint) -> Void)?
        var onDrag: ((CGPoint) -> Void)?
        var onRelease: ((CGPoint, NSView) -> Void)?
        var cursorAt: ((CGPoint) -> NSCursor)?
        var onExit: (() -> Void)?
        private var isDragging = false
        private var dragCursor: NSCursor = .arrow

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            ))
        }

        private func point(of event: NSEvent) -> CGPoint {
            convert(event.locationInWindow, from: nil)
        }

        private func cursor(for event: NSEvent) -> NSCursor {
            if isDragging { return dragCursor }
            let point = point(of: event)
            // A missed exit leaves this view's claim in place; outside it,
            // the header's buttons get the plain arrow.
            guard bounds.contains(point) else { return .arrow }
            return cursorAt?(point) ?? .arrow
        }

        override func mouseEntered(with event: NSEvent) {
            CursorLock.claim(self) { [weak self] in self?.cursor(for: $0) ?? .arrow }
            cursor(for: event).set()
        }

        override func mouseMoved(with event: NSEvent) {
            // Claimed here too, not just on enter: the enter is missed when
            // the view appears or resizes under a pointer that's already in it.
            CursorLock.claim(self) { [weak self] in self?.cursor(for: $0) ?? .arrow }
            cursor(for: event).set()
        }

        override func mouseExited(with event: NSEvent) {
            onExit?()
            guard !isDragging else { return }
            CursorLock.release(self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { CursorLock.release(self) }
        }

        override func scrollWheel(with event: NSEvent) {
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
            let delta = isVertical || abs(event.scrollingDeltaX) < abs(event.scrollingDeltaY)
                ? event.scrollingDeltaY
                : event.scrollingDeltaX
            onScroll?(delta * scale)
        }

        override func mouseDown(with event: NSEvent) {
            let grabbed = cursorAt?(point(of: event)) ?? .arrow
            dragCursor = grabbed == .openHand ? .closedHand : grabbed
            isDragging = true
            onPress?(point(of: event))
            dragCursor.set()
        }

        override func mouseDragged(with event: NSEvent) {
            onDrag?(point(of: event))
            dragCursor.set()
        }

        override func mouseUp(with event: NSEvent) {
            isDragging = false
            onRelease?(point(of: event), self)
            (cursorAt?(point(of: event)) ?? .arrow).set()
        }
    }
}

/// Takes a drag on the notch's bottom edge. It reads the pointer in screen
/// coordinates: the window grows down under the pointer while it drags, so
/// anything measured inside the window would move with it.
private struct NotchResizeCapture: NSViewRepresentable {
    var onBegin: () -> Void
    var onDrag: (CGFloat) -> Void
    var onEnd: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: HandleView, context: Context) {
        update(nsView)
    }

    private func update(_ view: HandleView) {
        view.onBegin = onBegin
        view.onDrag = onDrag
        view.onEnd = onEnd
    }

    final class HandleView: NSView {
        var onBegin: (() -> Void)?
        var onDrag: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?
        private var startY: CGFloat?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            ))
        }

        /// Arrows while dragging or over the grabber; a missed exit doesn't
        /// leave them stuck elsewhere.
        private func cursor(for event: NSEvent) -> NSCursor {
            startY != nil || bounds.contains(convert(event.locationInWindow, from: nil))
                ? .resizeUpDown : .arrow
        }

        private func claimCursor() {
            CursorLock.claim(self) { [weak self] in self?.cursor(for: $0) ?? .arrow }
        }

        override func mouseEntered(with event: NSEvent) {
            claimCursor()
            NSCursor.resizeUpDown.set()
        }

        override func mouseMoved(with event: NSEvent) {
            claimCursor()
            cursor(for: event).set()
        }

        override func mouseExited(with event: NSEvent) {
            guard startY == nil else { return }
            CursorLock.release(self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { CursorLock.release(self) }
        }

        override func mouseDown(with event: NSEvent) {
            startY = NSEvent.mouseLocation.y
            claimCursor()
            onBegin?()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let startY else { return }
            // Screen y grows upward; dragging down makes the notch taller.
            onDrag?(startY - NSEvent.mouseLocation.y)
            NSCursor.resizeUpDown.set()
        }

        override func mouseUp(with event: NSEvent) {
            startY = nil
            onEnd?()
            let inside = bounds.contains(convert(event.locationInWindow, from: nil))
            if !inside { CursorLock.release(self) }
        }
    }
}

/// The pointer's last spot over the timeline (or day in the month), kept
/// out of SwiftUI state on purpose: it changes on every mouse move.
private final class PointerSpot {
    var point: CGPoint?
    var monthDay: Date?
}

/// The tab's background jobs, kept out of its body so that stays quick to
/// compile: Google tasks for the days on screen, and the Mac changing time zone.
private struct TabWatchers: ViewModifier {
    let tasksKey: String
    let keepTasksLoaded: () async -> Void
    let onTimeZoneChange: () -> Void
    /// The task box opens and closes like the event box.
    let editingTaskID: String?

    func body(content: Content) -> some View {
        content
            .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.18), value: editingTaskID)
            .task(id: tasksKey) { await keepTasksLoaded() }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                onTimeZoneChange()
            }
    }
}
