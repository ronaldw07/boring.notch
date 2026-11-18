//
//  SearchCard.swift
//  boringNotch
//
//  Search from the calendar header: type, and events from a year back to a
//  year ahead that match show below. Clicking one opens its day and its
//  details. Escape or a click outside closes it.
//

import SwiftUI

struct SearchCard: View {
    /// Everything searchable, fetched once when the card opens.
    let events: [EventModel]?
    let onPick: (EventModel) -> Void
    let onClose: () -> Void

    @State private var query: String
    @State private var keyMonitor: Any?
    @State private var showsAllUpcoming = false
    @State private var showsAllPast = false
    @State private var scroll = ScrollMetrics()
    @FocusState private var isFieldFocused: Bool

    private static let escapeKey: UInt16 = 53
    private static let resultsHeight: CGFloat = 132
    /// Rows a section shows until "Show all".
    private static let previewCount = 3
    private static let scrollSpace = "searchResults"

    init(events: [EventModel]?, query: String = "", onPick: @escaping (EventModel) -> Void, onClose: @escaping () -> Void) {
        self.events = events
        self.onPick = onPick
        self.onClose = onClose
        _query = State(initialValue: query)
    }

    private var isEmptyQuery: Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var sections: (upcoming: [EventModel], past: [EventModel]) {
        EventSearch.sections(for: query, in: events ?? [])
    }

    private var firstResult: EventModel? {
        let found = sections
        return found.upcoming.first ?? found.past.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                TextField("", text: $query, prompt: Text("Search events").foregroundStyle(.white.opacity(0.35)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .focused($isFieldFocused)
                    .onSubmit { if let first = firstResult { onPick(first) } }
            }
            if isEmptyQuery {
                note("Titles, places and descriptions, a year back to a year ahead")
            } else if events == nil {
                note("Loading…")
            } else if firstResult == nil {
                note("No events match")
            } else {
                let found = sections
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        section("Upcoming", found.upcoming, showsAll: $showsAllUpcoming)
                        section("Past", found.past, showsAll: $showsAllPast)
                    }
                    .padding(.trailing, 8)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(
                            key: ScrollMetrics.Key.self,
                            value: ScrollMetrics(contentHeight: proxy.size.height, offset: -proxy.frame(in: .named(Self.scrollSpace)).minY)
                        )
                    })
                }
                .coordinateSpace(name: Self.scrollSpace)
                .onPreferenceChange(ScrollMetrics.Key.self) { scroll = $0 }
                .frame(height: Self.resultsHeight)
                .overlay(alignment: .topTrailing) { scrollPill }
            }
        }
        .padding(12)
        .frame(width: 440, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(CardBackground())
        .onAppear {
            NotchKeyboardFocus.begin()
            DispatchQueue.main.async { isFieldFocused = true }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { key in
                guard key.keyCode == Self.escapeKey else { return key }
                onClose()
                return nil
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            NotchKeyboardFocus.end()
        }
    }

    /// A titled list that shows a few rows, with "Show all" for the rest.
    @ViewBuilder
    private func section(_ title: String, _ list: [EventModel], showsAll: Binding<Bool>) -> some View {
        if !list.isEmpty {
            HStack {
                Text("\(title) · \(list.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.gray)
                Spacer()
                if list.count > Self.previewCount {
                    Button(showsAll.wrappedValue ? "Show less" : "Show all") { showsAll.wrappedValue.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)
            ForEach(showsAll.wrappedValue ? list : Array(list.prefix(Self.previewCount)), id: \.searchKey) { event in
                row(event)
            }
        }
    }

    /// A thin pill at the right edge showing where the list is scrolled to;
    /// only there when there's more than fits.
    @ViewBuilder
    private var scrollPill: some View {
        let viewport = Self.resultsHeight
        if scroll.contentHeight > viewport + 1 {
            let length = max(18, viewport * viewport / scroll.contentHeight)
            let progress = min(max(scroll.offset / (scroll.contentHeight - viewport), 0), 1)
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: 3, height: length)
                .offset(y: progress * (viewport - length))
                .padding(.trailing, 1)
                .allowsHitTesting(false)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.gray)
            .padding(.vertical, 2)
    }

    /// "Tue, Nov 17", with the year when it isn't this year.
    private func dateText(_ date: Date) -> String {
        let format = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        return Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
            ? date.formatted(format)
            : date.formatted(format.year())
    }

    /// "Tue, Nov 17  ▍ gym  2:00 PM"
    private func row(_ event: EventModel) -> some View {
        Button { onPick(event) } label: {
            HStack(spacing: 8) {
                Text(dateText(event.start))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.gray)
                    .monospacedDigit()
                    .frame(width: 92, alignment: .leading)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(nsColor: event.calendar.color))
                    .frame(width: 3, height: 12)
                Text(event.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .monospacedDigit()
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension EventModel {
    /// Occurrences of a repeating event share an id, so the start tells them apart.
    var searchKey: String { "\(id)|\(start.timeIntervalSince1970)" }
}

/// How tall the results are and how far they've scrolled, for the pill.
private struct ScrollMetrics: Equatable {
    var contentHeight: CGFloat = 0
    var offset: CGFloat = 0

    struct Key: PreferenceKey {
        static let defaultValue = ScrollMetrics()
        static func reduce(value: inout ScrollMetrics, nextValue: () -> ScrollMetrics) { value = nextValue() }
    }
}
