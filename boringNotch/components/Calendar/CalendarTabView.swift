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
        var id: String { event.id }
    }

    enum DragMode { case move, resizeStart, resizeEnd }

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
        case .resizeStart:
            let newStart = min(max(onGrid(start + delta), 0), end - snap)
            return (newStart, end)
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
    @AppStorage("calendarVerticalView") private var isVertical = false
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
    @State private var selectedEvent: EventModel?
    @State private var activeDrag: ActiveDrag?
    @State private var preview: Preview?

    /// A press on a block, from mouse-down until release.
    private struct ActiveDrag {
        let item: DayTimelineLayout.Placed
        let mode: DayTimelineLayout.DragMode
        let startPoint: CGPoint
        var moved = false
    }

    /// Where the dragged block is shown, until the calendar confirms it.
    private struct Preview {
        let id: String
        var start: TimeInterval
        var end: TimeInterval
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
            if hasTasks {
                tasksStrip
            }
            Group {
                if isVertical { verticalTimeline } else { timeline }
            }
                // Hung just under the strip, where there's room you can
                // see: the view's own bottom edge runs past the notch's
                // visible edge, so a message pinned there is drawn out of
                // sight. The vertical day runs almost to that edge, so
                // there it sits inside the timeline's corner instead.
                .overlay(alignment: .bottomTrailing) {
                    undoToast
                        .alignmentGuide(.bottom) { isVertical ? $0[.bottom] + 12 : $0[.top] - 4 }
                        .padding(.trailing, 10)
                }
                .overlay(alignment: .bottom) {
                    if isVertical && selectedEvent == nil {
                        resizeHandle
                            .alignmentGuide(.bottom) { $0[.bottom] - 10 }
                    }
                }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.2), value: calendarManager.undoMessage)
        .overlay { detailsOverlay }
        .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.18), value: selectedEvent?.id)
        .onChange(of: calendarManager.events) {
            // Gone from the calendar (deleted here or elsewhere): close its box.
            if let selected = selectedEvent,
               !calendarManager.events.contains(where: { $0.id == selected.id && $0.start == selected.start }) {
                selectedEvent = nil
            }
        }
        .onAppear {
            // Same as the clipboard: always opens at the normal size.
            isExpanded = false
            verticalExtra = 0
            vm.setExtraContentHeight(0)
            calendarManager.beginLiveRefresh()
            show(Calendar.current.startOfDay(for: .now))
            Task { await calendarManager.requestAccessForTab() }
        }
        .onDisappear {
            selectedEvent = nil
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
            applyExtraHeight()
        }
        // Switching to another tab and straight back can keep this view
        // without an onAppear or onDisappear, while the other tab has
        // already shrunk the panel. So if anything else changes the panel's
        // height, drop back to the normal size and ask for that again.
        .onChange(of: vm.extraContentHeight) {
            guard vm.extraContentHeight != desiredExtraHeight, resizeStartExtra == nil else { return }
            resetSize()
            if vm.notchState == .open && vm.coordinator.currentView == .calendar {
                applyExtraHeight()
            }
        }
        .onChange(of: visibleLaneCount) { applyExtraHeight() }
        .onChange(of: isVertical) {
            verticalExtra = 0
            applyExtraHeight()
        }
        .onChange(of: hasTasks) { applyExtraHeight() }
        // Google tasks for the shown day, refreshed while the tab is open.
        .task(id: "\(day.timeIntervalSince1970)-\(googleTasks.isSignedIn)") {
            while !Task.isCancelled {
                await googleTasks.reload(for: day)
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    // MARK: - Data

    private var dayLength: TimeInterval {
        let next = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        return next.timeIntervalSince(day)
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(day)
    }

    private var events: [EventModel] {
        EventListView.filteredEvents(events: calendarManager.events)
    }

    private var allDayEvents: [EventModel] {
        events.filter(\.isAllDay)
    }

    private var placed: [DayTimelineLayout.Placed] {
        let timed = events.filter { !$0.isAllDay }
        guard isVertical else {
            return DayTimelineLayout.place(timed, dayStart: day, dayLength: dayLength)
        }
        let footprint = TimeInterval(Self.minBlockHeight / Self.hourHeight) * 3600
        return DayTimelineLayout.columns(timed, dayStart: day, dayLength: dayLength, footprint: footprint)
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

    private var hasTasks: Bool {
        !googleTasks.tasks.isEmpty
    }

    private var hiddenCount: Int {
        guard !isVertical else { return 0 }
        return placed.filter { $0.lane >= visibleLaneCount }.count
    }

    private var trackWidth: CGFloat {
        CGFloat(dayLength / 3600) * Self.hourWidth
    }

    /// Points per hour along the time axis, whichever way it runs.
    private var hourSize: CGFloat {
        isVertical ? Self.hourHeight : Self.hourWidth
    }

    private func position(for seconds: TimeInterval) -> CGFloat {
        CGFloat(seconds / 3600) * hourSize
    }

    private var trackLength: CGFloat {
        position(for: dayLength)
    }

    private var viewportLength: CGFloat {
        isVertical ? viewportSize.height : viewportSize.width
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
            Text(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .monospacedDigit()
            navButton("chevron.right") { step(by: 1) }

            if !isToday {
                Button {
                    show(Calendar.current.startOfDay(for: .now))
                } label: {
                    Text("Today")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .frame(height: 18)
                        .background(Capsule().fill(Color(nsColor: .secondarySystemFill)))
                }
                .buttonStyle(.plain)
            }

            allDayChips
                .padding(.leading, 4)

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
            orientationButton
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
                .onTapGesture { open(event) }
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
        isVertical ? verticalExtra > 0 : isExpanded
    }

    /// A grabber on the notch's bottom edge: drag it to make the day taller
    /// or shorter.
    private var resizeHandle: some View {
        Capsule()
            .fill(.white.opacity(resizeStartExtra == nil ? 0.22 : 0.5))
            .frame(width: 36, height: 3)
            .frame(maxWidth: .infinity)
            .frame(height: 14)
            .overlay {
                NotchResizeCapture(
                    onBegin: beginResize,
                    onDrag: resize(by:),
                    onEnd: endResize
                )
                .frame(width: 160)
            }
    }

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
                ForEach(googleTasks.tasks) { task in
                    Button {
                        Task { await googleTasks.setCompleted(task, !task.isCompleted) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 11))
                                .foregroundStyle(task.isCompleted ? .green : .gray)
                            Text(task.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(task.isCompleted ? .gray : .white)
                                .strikethrough(task.isCompleted)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Capsule().fill(Color(nsColor: .secondarySystemFill)))
                    }
                    .buttonStyle(.plain)
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
                track(now: context.date)
                    .offset(x: -offset)
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
            if selectedEvent == nil {
                TimelineScrollCapture(
                    isVertical: false,
                    onScroll: scroll(by:),
                    onPress: press(at:),
                    onDrag: drag(to:),
                    onRelease: release(at:in:),
                    cursorAt: cursor(at:)
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
                verticalTrack(now: context.date, width: geometry.size.width)
                    // Clipping hides the hours scrolled above the view but
                    // doesn't stop them taking clicks, and they sit over the
                    // header's buttons. Clicks here go to the capture view.
                    .allowsHitTesting(false)
                    .offset(y: -offset)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    .clipped()
                    .mask(verticalEdgeFade)
                    .overlay { emptyState }
            }
            .onAppear { setViewportSize(geometry.size) }
            .onChange(of: geometry.size) { _, size in setViewportSize(size) }
        }
        .frame(height: verticalTimelineHeight)
        .overlay {
            if selectedEvent == nil {
                TimelineScrollCapture(
                    isVertical: true,
                    onScroll: scroll(by:),
                    onPress: press(at:),
                    onDrag: drag(to:),
                    onRelease: release(at:in:),
                    cursorAt: cursor(at:)
                )
            }
        }
        .onHover { vm.isHoveringCalendar = $0 }
    }

    /// Where a block sits in the vertical track, gutter included.
    private func verticalFrame(of item: DayTimelineLayout.Placed, start: TimeInterval,
                               end: TimeInterval, width: CGFloat) -> CGRect {
        let columnWidth = max(0, width - Self.gutterWidth) / CGFloat(item.columns)
        let height = max(position(for: end) - position(for: start), Self.minBlockHeight)
        return CGRect(
            x: Self.gutterWidth + CGFloat(item.lane) * columnWidth,
            y: position(for: start),
            width: columnWidth,
            height: height
        )
    }

    private func verticalTrack(now: Date, width: CGFloat) -> some View {
        let hours = Int(dayLength / 3600)
        let nowSeconds = now.timeIntervalSince(day)
        let showsNow = nowSeconds >= 0 && nowSeconds < dayLength
        let contentWidth = max(0, width - Self.gutterWidth)

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

            ForEach(placed) { item in
                let shown = preview?.id == item.id ? preview : nil
                let start = shown?.start ?? item.start
                let end = shown?.end ?? item.end
                let frame = verticalFrame(of: item, start: start, end: end, width: width)
                TimelineEventBlock(
                    event: item.event,
                    isCurrent: item.event.start <= now && now < item.event.end,
                    isExpanded: frame.height >= 28,
                    previewRange: shown.map { (day.addingTimeInterval($0.start), day.addingTimeInterval($0.end)) },
                    showsGrips: frame.height > 30,
                    isVertical: true
                )
                .frame(width: max(4, frame.width - 2), height: max(4, frame.height - 1))
                .offset(x: frame.minX + 1, y: frame.minY + 0.5)
                .zIndex(shown == nil ? 0 : 1)
            }

            if showsNow {
                // Time already gone, dimmed.
                Rectangle()
                    .fill(.black.opacity(0.4))
                    .frame(width: contentWidth, height: position(for: nowSeconds))
                    .offset(x: Self.gutterWidth)
                Rectangle()
                    .fill(.red)
                    .frame(width: contentWidth + 4, height: 1.5)
                    .offset(x: Self.gutterWidth - 4, y: position(for: nowSeconds) - 0.75)
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                    .offset(x: Self.gutterWidth - 6, y: position(for: nowSeconds) - 3)
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
            emptyText(isToday ? "No events today" : "No events")
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

    private func step(by days: Int) {
        guard let target = Calendar.current.date(byAdding: .day, value: days, to: day) else { return }
        show(target)
    }

    private func show(_ newDay: Date) {
        day = newDay
        scrollToDefault()
        Task {
            await calendarManager.updateCurrentDate(newDay)
            scrollToDefault()
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
        if isToday {
            offset = clamped(position(for: Date.now.timeIntervalSince(day)) - viewportLength * Self.nowAnchor)
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
        isVertical ? verticalHit(at: point) : horizontalHit(at: point)
    }

    /// Top and bottom edges resize, the rest moves.
    private func verticalHit(at point: CGPoint) -> (item: DayTimelineLayout.Placed, mode: DayTimelineLayout.DragMode)? {
        let trackPoint = CGPoint(x: point.x, y: point.y + offset)
        // Last drawn is on top.
        guard let item = placed.last(where: {
            verticalFrame(of: $0, start: $0.start, end: $0.end, width: viewportSize.width).contains(trackPoint)
        }) else { return nil }

        let frame = verticalFrame(of: item, start: item.start, end: item.end, width: viewportSize.width)
        let grab = min(Self.edgeGrab, frame.height / 3)
        if trackPoint.y - frame.minY <= grab { return (item, .resizeStart) }
        if frame.maxY - trackPoint.y <= grab { return (item, .resizeEnd) }
        return (item, .move)
    }

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
        if trackX - x(for: item.start) <= grab { return (item, .resizeStart) }
        if x(for: item.end) - trackX <= grab { return (item, .resizeEnd) }
        return (item, .move)
    }

    private func press(at point: CGPoint) {
        guard let found = hit(at: point) else { return }
        activeDrag = ActiveDrag(item: found.item, mode: found.mode, startPoint: point)
    }

    private func drag(to point: CGPoint) {
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
            delta: TimeInterval((isVertical ? dy : dx) / hourSize) * 3600,
            dayLength: dayLength
        )
        preview = Preview(id: current.item.id, start: span.start, end: span.end)
    }

    private func release(at point: CGPoint, in _: NSView) {
        guard let finished = activeDrag else { return }
        activeDrag = nil

        guard finished.moved else {
            selectedEvent = finished.item.event
            return
        }
        guard let moved = preview, moved.id == finished.item.id,
              moved.start != finished.item.start || moved.end != finished.item.end else {
            preview = nil
            return
        }

        let event = finished.item.event
        let newStart = day.addingTimeInterval(moved.start)
        let newEnd = day.addingTimeInterval(moved.end)
        Task {
            // Held until the calendar has reloaded, so the block doesn't
            // jump back to its old spot for a moment first.
            _ = await calendarManager.moveEvent(event, to: newStart, end: newEnd)
            preview = nil
        }
    }

    private func cursor(at point: CGPoint) -> NSCursor {
        guard let found = hit(at: point), found.item.event.type.isEvent else { return .arrow }
        switch found.mode {
        case .move: return .openHand
        case .resizeStart, .resizeEnd: return isVertical ? .resizeUpDown : .resizeLeftRight
        }
    }

    @ViewBuilder
    private var detailsOverlay: some View {
        if let event = selectedEvent {
            ZStack {
                Color.black.opacity(0.55)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedEvent = nil }
                EventDetailsCard(
                    event: event,
                    onClose: { selectedEvent = nil },
                    onOpen: { open(event) },
                    onDelete: { scope in await calendarManager.deleteEvent(event, scope: scope) }
                )
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            .transition(.opacity)
        }
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
        let strip = hasTasks ? Self.tasksStripHeight + 6 : 0
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
        let strip = hasTasks ? Self.tasksStripHeight + 6 : 0
        vm.setExtraContentHeightImmediately(extra + strip)
    }

    @MainActor
    private func endResize() {
        resizeStartExtra = nil
        vm.isResizingNotch = false
        if verticalExtra > 0 {
            rememberedVerticalExtra = Double(verticalExtra)
        }
    }

    @MainActor
    private func toggleExpanded() {
        guard !isVertical else {
            toggleVerticalSize()
            return
        }
        withAnimation(vm.animationLibrary.collapseCurve) {
            isExpanded.toggle()
        }
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

    /// The notch grows for the task strip and, expanded, for extra rows —
    /// capped against the screen, like the clipboard's.
    @MainActor
    private func applyExtraHeight() {
        vm.setExtraContentHeight(desiredExtraHeight)
    }

    private var desiredExtraHeight: CGFloat {
        let collapsed = Self.lanesHeight(count: Self.collapsedLaneCount, laneHeight: Self.collapsedLaneHeight)
        let rows = isVertical ? verticalExtra : (isExpanded ? max(0, lanesHeight - collapsed) : 0)
        let strip = hasTasks ? Self.tasksStripHeight + 6 : 0
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
    /// In the vertical day: text from the top, grips on the top and bottom.
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
        // Grips on both ends: drag these to change the start or end time.
        .overlay(alignment: isVertical ? .top : .leading) { if showsGrips { grip.padding(isVertical ? .top : .leading, isVertical ? 2 : 5) } }
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
    }

    final class CaptureView: NSView {
        var isVertical = false
        var onScroll: ((CGFloat) -> Void)?
        var onPress: ((CGPoint) -> Void)?
        var onDrag: ((CGPoint) -> Void)?
        var onRelease: ((CGPoint, NSView) -> Void)?
        var cursorAt: ((CGPoint) -> NSCursor)?
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
