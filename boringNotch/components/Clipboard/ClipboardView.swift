//
//  ClipboardView.swift
//  boringNotch
//
//  Recently copied items, newest first. Clicking one puts it back on the
//  pasteboard.
//

import SwiftUI

struct ClipboardView: View {
    @ObservedObject private var clipboard = ClipboardManager.shared
    @State private var justCopiedID: UUID?

    var body: some View {
        Group {
            if clipboard.items.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(clipboard.items) { item in
                            ClipboardRow(item: item, isConfirming: justCopiedID == item.id)
                                .contentShape(Rectangle())
                                .onTapGesture { copy(item) }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clipboard")
                .font(.system(size: 26))
                .foregroundStyle(.gray)
            Text("Nothing copied yet")
                .font(.caption)
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copy(_ item: ClipboardItem) {
        clipboard.copy(item)
        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)) {
            justCopiedID = item.id
        }
        Task {
            try? await Task.sleep(for: .seconds(1))
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)) {
                justCopiedID = nil
            }
        }
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    let isConfirming: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            thumbnail

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isConfirming {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? Color(nsColor: .secondarySystemFill) : .clear)
        )
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(red: 28/255, green: 28/255, blue: 30/255))
            .frame(width: 34, height: 26)
            .overlay {
                if let data = item.imageData, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: item.isImage ? "photo" : "doc.text")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                }
            }
    }

    private var title: String {
        guard let text = item.text else { return "Image" }
        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
    }

    private var subtitle: String {
        "\(item.isImage ? "Image" : "Text") · Copied \(Self.copiedDescription(item.copiedAt))"
    }

    /// Times today, "yesterday" for the day before, dates beyond that — the
    /// shortest phrasing that is still unambiguous.
    private static func copiedDescription(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "yesterday"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

#Preview {
    ClipboardView()
        .frame(width: 400, height: 180)
        .background(.black)
}
