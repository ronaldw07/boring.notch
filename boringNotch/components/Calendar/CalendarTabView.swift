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

    /// Zero-length items, like a reminder's due time, still get a block.
    static let minimumDuration: TimeInterval = 15 * 60

    /// Earliest first (longest first on a tie), each into the first lane
    /// that's free by its start — so overlaps stack and nothing else does.
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
                if lane == laneEnds.count {
                    laneEnds.append(end)
                } else {
                    laneEnds[lane] = end
                }
                return Placed(event: event, lane: lane, start: start, end: end)
            }
    }
}

struct CalendarTabView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var calendarManager = CalendarManager.shared

    @State private var day: Date = Calendar.current.startOfDay(for: .now)
    @State private var offset: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var isExpanded = false

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
            timeline
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            // Same as the clipboard: always opens at the normal size.
            isExpanded = false
            vm.setExtraContentHeight(0)
            calendarManager.beginLiveRefresh()
            show(Calendar.current.startOfDay(for: .now))
        }
        .onDisappear {
            calendarManager.endLiveRefresh()
            vm.isHoveringCalendar = false
            if isExpanded {
                isExpanded = false
                vm.setExtraContentHeight(0)
            }
        }
        .onChange(of: visibleLaneCount) {
            if isExpanded {
                vm.setExtraContentHeight(expandShortfall())
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
        .overlay(TimelineScrollCapture(onScroll: scroll(by:), onTap: tap(at:)))
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
                TimelineEventBlock(
                    event: item.event,
                    isCurrent: item.event.start <= now && now < item.event.end,
                    isExpanded: isExpanded
                )
                .frame(width: max(4, x(for: item.end) - x(for: item.start) - 2), height: laneHeight)
                .offset(x: x(for: item.start) + 1, y: laneY(item.lane))
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

    private func tap(at point: CGPoint) {
        let trackX = point.x + offset
        let laneStride = laneHeight + Self.laneSpacing
        let y = point.y - Self.hourRowHeight
        guard y >= 0 else { return }
        let lane = Int(y / laneStride)
        guard y - CGFloat(lane) * laneStride <= laneHeight else { return }
        let hit = placed.first {
            $0.lane == lane && $0.lane < visibleLaneCount
                && x(for: $0.start) <= trackX && trackX <= x(for: $0.end)
        }
        if let hit { open(hit.event) }
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
        vm.setExtraContentHeight(isExpanded ? expandShortfall() : 0)
    }

    /// Capped against the screen, like the clipboard's.
    @MainActor
    private func expandShortfall() -> CGFloat {
        let collapsed = Self.lanesHeight(count: Self.collapsedLaneCount, laneHeight: Self.collapsedLaneHeight)
        let shortfall = max(0, lanesHeight - collapsed)
        guard let screenHeight = getScreenFrame(vm.screenUUID)?.height else { return shortfall }
        return min(shortfall, max(0, screenHeight - windowSize.height))
    }
}

private struct TimelineEventBlock: View {
    let event: EventModel
    let isCurrent: Bool
    let isExpanded: Bool

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
        .background(color.opacity(isCurrent ? 0.4 : 0.22))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(.white.opacity(isCurrent ? 0.5 : 0), lineWidth: 1)
        )
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

    private var time: some View {
        Text(event.start.formatted(date: .omitted, time: .shortened))
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(1)
    }
}

/// Takes scroll and click events over the timeline. Sideways trackpad
/// swipes scroll as they are; a mouse wheel's vertical notches scroll
/// sideways too, scaled up the same way the lyrics panel does it.
private struct TimelineScrollCapture: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void
    var onTap: (CGPoint) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onScroll = onScroll
        view.onTap = onTap
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onTap = onTap
    }

    final class CaptureView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        var onTap: ((CGPoint) -> Void)?

        override var isFlipped: Bool { true }

        override func scrollWheel(with event: NSEvent) {
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
            let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX
                : event.scrollingDeltaY
            onScroll?(delta * scale)
        }

        override func mouseUp(with event: NSEvent) {
            onTap?(convert(event.locationInWindow, from: nil))
        }
    }
}
