import SwiftUI
import TaskTickCore

/// Display helpers for schedule time zones (issue #41), shared by the editor
/// row and the task detail view.
enum TimeZoneDisplay {
    /// "GMT+8" / "GMT-4:30" style offset for a zone, DST-aware for `date`.
    static func gmtOffset(_ tz: TimeZone, at date: Date = Date()) -> String {
        let seconds = tz.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        let hours = magnitude / 3600
        let minutes = (magnitude % 3600) / 60
        return minutes == 0
            ? "GMT\(sign)\(hours)"
            : String(format: "GMT%@%d:%02d", sign, hours, minutes)
    }

    /// Compact label for a selection: nil → "System (Asia/Shanghai)",
    /// otherwise "Asia/Tokyo (GMT+9)".
    static func label(for identifier: String?) -> String {
        guard let identifier, let tz = TimeZone(identifier: identifier) else {
            return L10n.tr("schedule.timezone.system", TimeZone.current.identifier)
        }
        return "\(identifier) (\(gmtOffset(tz)))"
    }
}

/// Form row with the current selection; tapping opens a searchable list of
/// every identifier the tz database knows (never a hardcoded subset).
/// `onUserChange(old, new)` fires only for explicit user picks — the editor
/// uses it to re-anchor wall-clock times without racing programmatic loads.
struct TimeZonePickerRow: View {
    @Binding var selection: String?
    var onUserChange: ((String?, String?) -> Void)? = nil
    @State private var showingPicker = false

    var body: some View {
        LabeledContent {
            Button {
                showingPicker.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(TimeZoneDisplay.label(for: selection))
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(selection == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
                TimeZonePickerList(selection: $selection, isPresented: $showingPicker, onUserChange: onUserChange)
            }
        } label: {
            Label(L10n.tr("schedule.timezone"), systemImage: "globe")
        }
    }
}

private struct ZoneEntry {
    let id: String
    /// Localized zone name in the app's language (e.g. "中国标准时间"), so
    /// users don't have to decode raw IANA identifiers.
    let localizedName: String?
    let offset: String
}

private struct TimeZonePickerList: View {
    @Binding var selection: String?
    @Binding var isPresented: Bool
    var onUserChange: ((String?, String?) -> Void)?
    @State private var search = ""

    /// Zone catalog with localized names, built once per app language.
    /// Localizing 400+ names goes through ICU — too slow to redo per keystroke.
    @MainActor private static var cache: [String: [ZoneEntry]] = [:]

    @MainActor private static func entries() -> [ZoneEntry] {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        let code = (AppLanguage(rawValue: saved) ?? .system).resolvedCode
        if let cached = cache[code] { return cached }
        let locale = Locale(identifier: code)
        let built = TimeZone.knownTimeZoneIdentifiers.sorted().compactMap { id -> ZoneEntry? in
            guard let tz = TimeZone(identifier: id) else { return nil }
            return ZoneEntry(
                id: id,
                localizedName: tz.localizedName(for: .generic, locale: locale),
                offset: TimeZoneDisplay.gmtOffset(tz)
            )
        }
        cache[code] = built
        return built
    }

    private var matches: [ZoneEntry] {
        let all = Self.entries()
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { entry in
            entry.id.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || entry.localizedName?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || entry.offset.range(of: query, options: [.caseInsensitive]) != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField(L10n.tr("schedule.timezone.search"), text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(10)

            Divider()

            List {
                row(
                    identifier: nil,
                    title: L10n.tr("schedule.timezone.system", TimeZone.current.identifier),
                    subtitle: TimeZone.current.localizedName(for: .generic, locale: .current),
                    offset: nil
                )

                ForEach(matches, id: \.id) { entry in
                    row(identifier: entry.id, title: entry.id, subtitle: entry.localizedName, offset: entry.offset)
                }
            }
            .listStyle(.plain)
        }
        .frame(width: 360, height: 400)
    }

    private func row(identifier: String?, title: String, subtitle: String?, offset: String?) -> some View {
        Button {
            let old = selection
            selection = identifier
            if old != identifier {
                onUserChange?(old, identifier)
            }
            isPresented = false
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if let offset {
                    Text(offset)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "checkmark")
                    .imageScale(.small)
                    .foregroundStyle(Color.accentColor)
                    .opacity(selection == identifier ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
