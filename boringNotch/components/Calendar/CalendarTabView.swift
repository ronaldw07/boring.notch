//
//  CalendarTabView.swift
//  boringNotch
//
//  The day as one wide horizontal timeline: hours run left to right and
//  events sit in lanes as blocks sized by their real start and end. Scroll
//  sideways with two fingers or a mouse wheel; the expand button grows the
//  notch so overlapping events get room of their own.
//

import AppKit
import Defaults
import EventKit
import SwiftUI

/// Pure lane math, kept out of the view.
enum DayTimelineLayout {
    struct Placed: Identifiable {
        let event: EventModel
        let lane: Int
        /// Seconds from the start of the day, clamped to it.
        let start: TimeInterval
        let end: TimeInterval
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
        let spans = events.compactMap { event -> (EventModel, TimeInterval, TimeInterval)? in
            let rawStart = event.start.timeIntervalSince(dayStart)
            let rawEnd = event.end.timeIntervalSince(dayStart)
            // Must actually touch the day: one ending right at midnight
            // belongs to the day before.
            guard rawStart < dayLength, rawEnd > 0 || rawStart >= 0 else { return nil }
            let start = max(rawStart, 0)
            let end = min(max(rawEnd, start + minimumDuration), dayLength)
            return (event, start, end)
        }
        var laneEnds: [TimeInterval] = []
        return spans
            .sorted { ($0.1, $1.2) < ($1.1, $0.2) }
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
}

struct CalendarTabView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var calendarManager = CalendarManager.shared
    @ObservedObject private var googleTasks = GoogleTasksManager.shared

    @State private var day: Date = Calendar.current.startOfDay(for: .now)
    @State private var offset: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var isExpanded = false
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if hasTasks {
                tasksStrip
            }
            timeline
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            vm.setExtraContentHeight(0)
            calendarManager.beginLiveRefresh()
            show(Calendar.current.startOfDay(for: .now))
            Task { await calendarManager.requestAccessForTab() }
        }
        .onDisappear {
            selectedEvent = nil
            calendarManager.endLiveRefresh()
            vm.isHoveringCalendar = false
            isExpanded = false
            vm.setExtraContentHeight(0)
        }
        .onChange(of: visibleLaneCount) { applyExtraHeight() }
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
        DayTimelineLayout.place(events.filter { !$0.isAllDay }, dayStart: day, dayLength: dayLength)
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
        placed.filter { $0.lane >= visibleLaneCount }.count
    }

    private var trackWidth: CGFloat {
        CGFloat(dayLength / 3600) * Self.hourWidth
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

            if hiddenCount > 0 {
                Text("\(hiddenCount) more")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.gray)
            }
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

    /// Same pair of symbols as the clipboard's expand button.
    private var expandButton: some View {
        Button(action: toggleExpanded) {
            Image(systemName: isExpanded
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
            .onAppear { setViewportWidth(geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in setViewportWidth(width) }
        }
        .frame(height: Self.hourRowHeight + lanesHeight)
        // On top of the track so it gets the scroll and click events; see
        // LyricsScrollCapture for why an NSView has to do this.
        .overlay {
            // Off while a details box is up, so clicks reach it and its
            // backdrop instead of the timeline underneath.
            if selectedEvent == nil {
                TimelineScrollCapture(
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

    private func setViewportWidth(_ width: CGFloat) {
        guard width != viewportWidth else { return }
        let isFirst = viewportWidth == 0
        viewportWidth = width
        if isFirst {
            scrollToDefault()
        } else {
            offset = clamped(offset)
        }
    }

    /// Today opens on "now"; any other day on its first event, or 8am.
    private func scrollToDefault() {
        guard viewportWidth > 0 else { return }
        if isToday {
            offset = clamped(x(for: Date.now.timeIntervalSince(day)) - viewportWidth * Self.nowAnchor)
        } else {
            let first = placed.map(\.start).min() ?? 8 * 3600
            offset = clamped(x(for: first) - Self.hourWidth / 2)
        }
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), max(0, trackWidth - viewportWidth))
    }

    private func scroll(by delta: CGFloat) {
        offset = clamped(offset - delta)
    }

    /// The block under a point, and which part of it: the edges resize,
    /// the middle moves.
    private func hit(at point: CGPoint) -> (item: DayTimelineLayout.Placed, mode: DayTimelineLayout.DragMode)? {
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
        if !current.moved {
            guard hypot(dx, point.y - current.startPoint.y) >= Self.dragThreshold else { return }
            current.moved = true
            activeDrag = current
        }
        // Reminders and the like can be clicked but not rescheduled here.
        guard current.item.event.type.isEvent else { return }

        let span = DayTimelineLayout.adjusted(
            start: current.item.start,
            end: current.item.end,
            mode: current.mode,
            delta: TimeInterval(dx / Self.hourWidth) * 3600,
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
        case .resizeStart, .resizeEnd: return .resizeLeftRight
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
    private func toggleExpanded() {
        withAnimation(vm.animationLibrary.collapseCurve) {
            isExpanded.toggle()
        }
        applyExtraHeight()
    }

    /// The notch grows for the task strip and, expanded, for extra rows —
    /// capped against the screen, like the clipboard's.
    @MainActor
    private func applyExtraHeight() {
        let collapsed = Self.lanesHeight(count: Self.collapsedLaneCount, laneHeight: Self.collapsedLaneHeight)
        let rows = isExpanded ? max(0, lanesHeight - collapsed) : 0
        let strip = hasTasks ? Self.tasksStripHeight + 6 : 0
        var total = rows + strip
        if let screenHeight = getScreenFrame(vm.screenUUID)?.height {
            total = min(total, max(0, screenHeight - windowSize.height))
        }
        vm.setExtraContentHeight(total)
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

    var body: some View {
        let color = Color(nsColor: event.calendar.color)
        HStack(spacing: 0) {
            Rectangle()
                .fill(color)
                .frame(width: 3)
            content
                .padding(.horizontal, 5)
            Spacer(minLength: 0)
        }
        // Grips on both ends: drag these to change the start or end time.
        .overlay(alignment: .leading) { if showsGrips { grip.padding(.leading, 5) } }
        .overlay(alignment: .trailing) { if showsGrips { grip.padding(.trailing, 2) } }
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
            .frame(width: 2.5, height: 10)
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
        view.onScroll = onScroll
        view.onPress = onPress
        view.onDrag = onDrag
        view.onRelease = onRelease
        view.cursorAt = cursorAt
    }

    final class CaptureView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        var onPress: ((CGPoint) -> Void)?
        var onDrag: ((CGPoint) -> Void)?
        var onRelease: ((CGPoint, NSView) -> Void)?
        var cursorAt: ((CGPoint) -> NSCursor)?
        private var isDragging = false

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

        override func mouseMoved(with event: NSEvent) {
            guard !isDragging else { return }
            (cursorAt?(point(of: event)) ?? .arrow).set()
        }

        override func mouseExited(with event: NSEvent) {
            NSCursor.arrow.set()
        }

        override func scrollWheel(with event: NSEvent) {
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
            let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX
                : event.scrollingDeltaY
            onScroll?(delta * scale)
        }

        override func mouseDown(with event: NSEvent) {
            isDragging = true
            onPress?(point(of: event))
        }

        override func mouseDragged(with event: NSEvent) {
            onDrag?(point(of: event))
        }

        override func mouseUp(with event: NSEvent) {
            isDragging = false
            onRelease?(point(of: event), self)
            (cursorAt?(point(of: event)) ?? .arrow).set()
        }
    }
}
