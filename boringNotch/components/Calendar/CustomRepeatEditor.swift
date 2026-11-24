//
//  CustomRepeatEditor.swift
//  boringNotch
//
//  The rows under Repeat once "Custom…" is picked in the new-event box:
//  every N days/weeks/months/years, which weekdays, and when it ends.
//

import SwiftUI

struct CustomRepeatEditor: View {
    let start: Date
    @Binding var custom: CustomRepeat

    private static let defaultCount = 10
    private static let defaultEndMonths = 1

    private var calendar: Calendar { .current }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                label("Every")
                counter($custom.interval, max: CustomRepeat.maxInterval)
                unitMenu
            }
            if custom.unit == .week {
                HStack(spacing: 6) {
                    label("On")
                    weekdayButtons
                }
            }
            HStack(spacing: 6) {
                label("Ends")
                endMenu
                switch custom.end {
                case .never:
                    EmptyView()
                case .on:
                    DatePicker("Ends on", selection: endDay, in: start..., displayedComponents: .date)
                        .datePickerStyle(.field)
                        .labelsHidden()
                        .controlSize(.small)
                        .environment(\.colorScheme, .dark)
                        .fixedSize()
                case .after:
                    counter(endCount, max: CustomRepeat.maxCount)
                    label(endCount.wrappedValue == 1 ? "time" : "times")
                }
            }
        }
        .padding(.leading, 18)
    }

    // MARK: - Pieces

    private var unitMenu: some View {
        Menu {
            ForEach(CustomRepeat.Unit.allCases, id: \.self) { unit in
                Button(unit.name(plural: custom.interval != 1)) { setUnit(unit) }
            }
        } label: {
            menuPill(custom.unit.name(plural: custom.interval != 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Weeks start on the user's own first weekday.
    private var weekdayButtons: some View {
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        return HStack(spacing: 2) {
            ForEach(order, id: \.self) { weekday in
                let isOn = custom.weekdays.contains(weekday)
                Button { toggle(weekday) } label: {
                    Text(calendar.veryShortWeekdaySymbols[weekday - 1])
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isOn ? .white : .white.opacity(0.6))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(isOn ? Color.accentColor : .white.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(calendar.weekdaySymbols[weekday - 1])
            }
        }
    }

    private var endMenu: some View {
        Menu {
            Button("Never") { custom.end = .never }
            Button("On a date") {
                let day = calendar.date(byAdding: .month, value: Self.defaultEndMonths, to: start) ?? start
                custom.end = .on(day)
            }
            Button("After a number of times") { custom.end = .after(Self.defaultCount) }
        } label: {
            menuPill(endName)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var endName: String {
        switch custom.end {
        case .never: "Never"
        case .on: "On"
        case .after: "After"
        }
    }

    /// − 2 +, kept between 1 and `max`.
    private func counter(_ value: Binding<Int>, max: Int) -> some View {
        HStack(spacing: 2) {
            stepButton("minus", enabled: value.wrappedValue > 1) { value.wrappedValue -= 1 }
            Text("\(value.wrappedValue)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 16)
            stepButton("plus", enabled: value.wrappedValue < max) { value.wrappedValue += 1 }
        }
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white.opacity(enabled ? 0.8 : 0.3))
                .frame(width: 16, height: 16)
                .background(Circle().fill(.white.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func menuPill(_ text: String) -> some View {
        HStack(spacing: 4) {
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

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: Self.labelWidth, alignment: .leading)
    }

    /// "Every", "On" and "Ends" line their controls up.
    private static let labelWidth: CGFloat = 30

    // MARK: - Changes

    private func setUnit(_ unit: CustomRepeat.Unit) {
        var next = custom
        next.unit = unit
        // Switching to weeks starts on the event's own weekday.
        if unit == .week && next.weekdays.isEmpty {
            next.weekdays = [calendar.component(.weekday, from: start)]
        }
        custom = next
    }

    /// At least one weekday stays on.
    private func toggle(_ weekday: Int) {
        var next = custom
        if next.weekdays.contains(weekday) {
            guard next.weekdays.count > 1 else { return }
            next.weekdays.remove(weekday)
        } else {
            next.weekdays.insert(weekday)
        }
        custom = next
    }

    private var endDay: Binding<Date> {
        Binding(
            get: { if case .on(let day) = custom.end { return day } else { return start } },
            set: { custom.end = .on($0) }
        )
    }

    private var endCount: Binding<Int> {
        Binding(
            get: { if case .after(let count) = custom.end { return count } else { return Self.defaultCount } },
            set: { custom.end = .after($0) }
        )
    }
}
