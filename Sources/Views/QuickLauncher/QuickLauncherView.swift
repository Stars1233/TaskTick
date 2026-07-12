import SwiftUI
import SwiftData
import TaskTickCore

/// Spotlight-style search panel content. Lists matching tasks and runs the
/// selected one when the user hits Enter.
struct QuickLauncherView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScheduledTask.createdAt, order: .reverse) private var tasks: [ScheduledTask]
    @StateObject private var scheduler = TaskScheduler.shared
    @State private var searchText = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFieldFocused: Bool
    /// Holds the `NSEvent.addLocalMonitorForEvents` reference. We can't rely on
    /// SwiftUI `.onKeyPress` for arrows because the embedded TextField is the
    /// key responder and consumes them before they bubble — installing an
    /// NSEvent monitor at the application level catches them first.
    @State private var keyMonitor: Any?

    let onDismiss: () -> Void

    /// Four-tier ranking, Raycast-style:
    /// 0. Running tasks — surface what's live first
    /// 1. Recently launched (MRU) — sorted by lastUsedAt desc
    /// 2. Manual tasks never launched from here — by createdAt desc
    /// 3. Scheduled tasks never launched from here — by createdAt desc
    private struct RankKey {
        let tier: Int
        let secondary: Date  // descending sort key within tier
    }

    private func rankKey(for task: ScheduledTask) -> RankKey {
        if scheduler.runningTaskIDs.contains(task.id) {
            return RankKey(tier: 0, secondary: .distantFuture)
        }
        // Tier 1 captures any user-initiated recency — Quick Launcher MRU
        // and "manually executed from anywhere" both count, whichever is
        // newer. This way play-button presses in the main window or menu
        // bar bump the task to the top here too, not just QL Enter presses.
        let qlUsed = QuickLauncherUsage.lastUsed(task.id)
        let manualUsed = task.lastManualRunAt
        if let recent = [qlUsed, manualUsed].compactMap({ $0 }).max() {
            return RankKey(tier: 1, secondary: recent)
        }
        if task.isManualOnly {
            return RankKey(tier: 2, secondary: task.createdAt)
        }
        return RankKey(tier: 3, secondary: task.createdAt)
    }

    private var rankedTasks: [ScheduledTask] {
        // Read filter as a snapshot — the panel is recreated on every show()
        // so picking up the latest value at body time is enough. Avoiding
        // @ObservedObject prevents a Combine subscription that races with
        // the show()'s alpha-flash workaround on cold start.
        let filter = QuickLauncherSettings.shared.taskFilter
        let enabled = tasks.filter {
            guard $0.isEnabled else { return false }
            switch filter {
            case .all: return true
            case .scheduledOnly: return !$0.isManualOnly
            case .manualOnly: return $0.isManualOnly
            }
        }
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            return enabled.sorted { lhs, rhs in
                let kl = rankKey(for: lhs), kr = rankKey(for: rhs)
                if kl.tier != kr.tier { return kl.tier < kr.tier }
                return kl.secondary > kr.secondary
            }
        }

        let scored: [(task: ScheduledTask, score: Int)] = enabled.compactMap { task in
            guard let s = FuzzyMatch.score(query: trimmed, candidate: task.name) else { return nil }
            return (task, s)
        }

        return scored
            .sorted { lhs, rhs in
                let kl = rankKey(for: lhs.task), kr = rankKey(for: rhs.task)
                if kl.tier != kr.tier { return kl.tier < kr.tier }
                // Within the same tier, fuzzy score wins over recency for
                // typed queries (the user is actively narrowing — relevance
                // beats history).
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return kl.secondary > kr.secondary
            }
            .map(\.task)
    }

    /// Hard-cap the result list at 8 — Spotlight-feel. More rows would push
    /// the panel into the territory of a window, not a launcher. If a user
    /// has so many tasks that the top 8 isn't enough, they can refine the
    /// query.
    private static let maxVisibleResults = 8

    /// Visible card width — kept as a typed constant so the controller can
    /// size the host window to match without inferring from intrinsic layout.
    static let cardWidth: CGFloat = 580

    private var visibleTasks: [ScheduledTask] {
        Array(rankedTasks.prefix(Self.maxVisibleResults))
    }

    private var selectedTask: ScheduledTask? {
        guard selectedIndex < visibleTasks.count else { return nil }
        return visibleTasks[selectedIndex]
    }

    private var isSelectedRunning: Bool {
        guard let task = selectedTask else { return false }
        return scheduler.runningTaskIDs.contains(task.id)
    }

    var body: some View {
        VStack(spacing: 6) {
            searchBar

            if !visibleTasks.isEmpty {
                resultsList
            } else if !searchText.isEmpty {
                emptyHint(L10n.tr("quick_launcher.empty.no_match"))
            }
            // No "no_tasks" empty state — when the user hasn't typed anything
            // and there are no enabled tasks, the panel collapses to just
            // search bar + footer. Avoids dead vertical space on first launch.

            footerHints
        }
        .padding(14)
        .frame(width: Self.cardWidth)
        // Background + rounded corners + native window shadow are all
        // applied by QuickLauncherController: an NSVisualEffectView
        // (windowBackground material, behindWindow blending) fills the
        // wrapper NSView underneath SwiftUI, and a CALayer cornerRadius
        // on the wrapper clips the whole thing to Apple's squircle shape.
        // A SwiftUI `.background(Color.windowBackgroundColor)` here would
        // make the surface fully opaque again — and then NSThemeFrame's
        // chrome would peek through the wrapper's rounded corner cut-outs
        // as square edges at the bottom.
        .ignoresSafeArea()
        .onAppear {
            installKeyMonitor()
            // Focus immediately while the panel is still at alpha=0 (the
            // controller delays alpha→1 by 100ms specifically to cover this
            // window). On first launch, NSTextField's first focus spawns
            // CursorUIViewService — an XPC-hosted remote view that flashes
            // a default-background frame as it boots. Doing it under alpha=0
            // makes that flash invisible to the user.
            searchFieldFocused = true
        }
        .onDisappear { removeKeyMonitor() }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only intercept while our launcher panel is up — otherwise the
            // monitor would steal arrows everywhere else in the app.
            guard NSApp.keyWindow is QuickLauncherPanel else { return event }

            // IME guard: when the user is mid-composition (e.g. typing pinyin
            // and the Chinese candidate panel is showing), the field editor
            // has marked text. Enter/space/numbers are part of the IME's
            // candidate-selection contract — must NOT be intercepted, or we
            // run the task while the user was just trying to commit "你好".
            // Cast to NSTextView (the concrete field-editor type) since the
            // base NSText doesn't expose `hasMarkedText()`.
            if let editor = NSApp.keyWindow?.fieldEditor(false, for: nil) as? NSTextView,
               editor.hasMarkedText() {
                return event
            }

            let cmdHeld = event.modifierFlags.contains(.command)
            switch Int(event.keyCode) {
            case 126: moveSelection(-1); return nil // up
            case 125: moveSelection(1); return nil  // down
            case 36, 76: runSelected(); return nil   // return / numpad enter
            case 15 where cmdHeld:                   // ⌘R — restart
                restartSelected(); return nil
            case 31 where cmdHeld:                   // ⌘O — reveal in main window
                revealSelected(); return nil
            case 43 where cmdHeld:                   // ⌘, — open Settings
                openSettings(); return nil
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.accentColor)

            TextField(L10n.tr("quick_launcher.placeholder"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFieldFocused)
                // Suppress macOS's focus-time suggestion popovers
                // (autocorrect / spell / AutoFill hints). Without these the
                // first time the field gains focus right after panel reveal,
                // the system flashes a small completion card under the
                // search box and immediately dismisses it — looking like a
                // bug in the launcher itself.
                .autocorrectionDisabled(true)
                .textContentType(.none)
                .onChange(of: searchText) { _, _ in selectedIndex = 0 }
                .onSubmit { runSelected() }

            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(4)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            // `Color.black.opacity(0.18)` was tuned for dark mode and turned
            // light mode into a heavy gray box. `.primary.opacity(0.04)`
            // adapts: 4% black on light = barely there, 4% white on dark =
            // gentle inset hint. The blue focus ring still does the heavy
            // lifting of telegraphing where focus is.
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
        )
    }

    // MARK: - Results

    private var resultsList: some View {
        // Cap the height at ~7 rows so the panel doesn't grow into a wall when
        // 20 tasks match. Beyond that the user scrolls.
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(Array(visibleTasks.enumerated()), id: \.element.id) { index, task in
                        QuickLauncherRow(
                            task: task,
                            isSelected: index == selectedIndex,
                            isRunning: scheduler.runningTaskIDs.contains(task.id)
                        )
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedIndex = index
                                runSelected()
                            }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selectedIndex) { _, new in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
        }
    }

    private func emptyHint(_ text: String) -> some View {
        HStack {
            Spacer()
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 16)
    }

    // MARK: - Footer

    private var footerHints: some View {
        // The Enter hint flips between "执行" and "停止" based on the selected
        // task's runtime state. ⌘R is always present so users can build muscle
        // memory regardless of the current row.
        HStack(spacing: 12) {
            kbdHint(keys: ["↑", "↓"], label: L10n.tr("quick_launcher.hint.navigate"))
            kbdHint(
                keys: ["↵"],
                label: isSelectedRunning
                    ? L10n.tr("quick_launcher.hint.stop")
                    : L10n.tr("quick_launcher.hint.run")
            )
            kbdHint(keys: ["⌘", "R"], label: L10n.tr("quick_launcher.hint.restart"))
            kbdHint(keys: ["⌘", "O"], label: L10n.tr("quick_launcher.hint.reveal"))
            kbdHint(keys: ["⌘", ","], label: L10n.tr("quick_launcher.hint.settings"))
            kbdHint(keys: ["esc"], label: L10n.tr("quick_launcher.hint.close"))
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    /// Render each key in its own kbd-style chip (1Password renders ⇧ ⌘ space
    /// as three chips, not one combined string). Keeps the visual rhythm
    /// consistent regardless of how many modifiers a hint references.
    private func kbdHint(keys: [String], label: String) -> some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.75))
                    .frame(minWidth: 14)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(0.10))
                    )
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, 1)
        }
    }

    // MARK: - Actions

    private func moveSelection(_ delta: Int) {
        let count = visibleTasks.count
        guard count > 0 else { return }
        selectedIndex = max(0, min(count - 1, selectedIndex + delta))
    }

    /// Primary action — context sensitive. Idle tasks start; running tasks
    /// stop. Mirrors the contract telegraphed by the row's pill text.
    private func runSelected() {
        guard let task = selectedTask else { return }
        let name = task.name
        if scheduler.runningTaskIDs.contains(task.id) {
            ScriptExecutor.shared.cancel(taskId: task.id)
            ActionToast.notify(.stopped(taskName: name), wantsBanner: task.notifyOnAction)
            ToastCenter.shared.stopped(L10n.tr("toast.task.stopped", name))
        } else {
            let context = modelContext
            Task {
                _ = await ScriptExecutor.shared.execute(task: task, modelContext: context)
            }
            QuickLauncherUsage.markUsed(task.id)
            ActionToast.notify(.started(taskName: name), wantsBanner: task.notifyOnAction)
            ToastCenter.shared.running(L10n.tr("toast.task.started", name))
        }
        onDismiss()
    }

    /// ⌘R — restart. If the task is running, cancel and wait briefly for
    /// SIGTERM to take effect before launching a fresh process. The wait is
    /// short on purpose: scripts that ignore SIGTERM will overlap with the
    /// new run for ~200ms, but that's preferable to blocking the UI thread
    /// on `waitUntilExit`.
    private func restartSelected() {
        guard let task = selectedTask else { return }
        let name = task.name
        let context = modelContext
        let wasRunning = scheduler.runningTaskIDs.contains(task.id)
        if wasRunning {
            ScriptExecutor.shared.cancel(taskId: task.id)
        }
        Task {
            if wasRunning {
                try? await Task.sleep(for: .milliseconds(200))
            }
            _ = await ScriptExecutor.shared.execute(task: task, modelContext: context)
        }
        QuickLauncherUsage.markUsed(task.id)
        ActionToast.notify(.restarted(taskName: name), wantsBanner: task.notifyOnAction)
        ToastCenter.shared.restart(L10n.tr("toast.task.restarted", name))
        onDismiss()
    }

    /// ⌘O — close the launcher and surface the selected task inside the main
    /// window. Posts via NotificationCenter so MenuBarExtra (which has
    /// `openWindow` in its environment) can wake the main scene; the main
    /// window then reads `MainWindowSelection.shared.taskToReveal` and
    /// focuses that row.
    private func revealSelected() {
        guard let task = selectedTask else { return }
        MainWindowSelection.shared.taskToReveal = task
        NotificationCenter.default.post(name: .revealTaskInMain, object: nil)
        onDismiss()
    }

    /// ⌘, — close the launcher and open the Settings scene.
    private func openSettings() {
        SettingsWindowOpener.open()
        onDismiss()
    }
}

// MARK: - Row

private struct QuickLauncherRow: View {
    let task: ScheduledTask
    let isSelected: Bool
    let isRunning: Bool

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            // Icon chip — running tasks override the static icon with a green
            // spinner, so the user can spot live tasks at a glance even
            // without reading the subtitle.
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(iconTint.opacity(0.22))
                if isRunning {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.green)
                } else {
                    Image(systemName: task.isManualOnly ? "hand.tap.fill" : "clock.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(iconTint)
                }
            }
            .frame(width: 22, height: 22)

            // Single-line "title — subtitle" layout, like Raycast's command
            // rows. Text colors stay primary/secondary regardless of
            // selection — the selection cue is the soft background tint, not
            // an inverted color scheme.
            HStack(spacing: 5) {
                Text(task.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if isSelected {
                let stopColor = Color(red: 0.78, green: 0.32, blue: 0.30)
                Text(isRunning
                     ? L10n.tr("quick_launcher.action.stop")
                     : L10n.tr("quick_launcher.action.run"))
                    .font(.system(size: 10.5, weight: .semibold))
                    // Tone down the stop red — system `.red` blasts out in
                    // light mode against the soft panel surface. A muted
                    // brick reads as "warning" without the eye strain.
                    .foregroundStyle(isRunning ? stopColor : Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.primary.opacity(0.08))
                    )
            } else if isRunning {
                // While a task is mid-flight the "X minutes ago" label is
                // misleading — that's the *last completed* run, not the live
                // one. Show elapsed time since the current run started, ticking
                // every second. Shares its data source (running ExecutionLog's
                // startedAt) with the detail-page schedule card.
                if let startedAt = RunningDuration.startedAt(for: task) {
                    TimelineView(.periodic(from: .now, by: 1.0)) { context in
                        Text(L10n.tr(
                            "quick_launcher.meta.running_for",
                            RunningDuration.format(since: startedAt, now: context.date)
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                        .monospacedDigit()
                    }
                } else {
                    // Fallback for the brief race where runningTaskIDs has
                    // already been flipped but the ExecutionLog hasn't
                    // hit disk yet.
                    Text(L10n.tr("quick_launcher.meta.running"))
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
            } else if let lastRun = task.lastRunAt {
                // Right-edge meta: "Xm ago". Only shown for unselected rows
                // so the action pill on the selected row stays the visual
                // anchor — same trick Raycast / Spotlight use.
                // TimelineView + "just now" short-circuit: see TaskListView
                // for the rationale (formatter quantization + stale render).
                TimelineView(.periodic(from: .now, by: 60)) { ctx in
                    let diff = ctx.date.timeIntervalSince(lastRun)
                    if diff >= 0 && diff < 60 {
                        Text(L10n.tr("time.just_now"))
                    } else {
                        Text(Self.relativeFormatter.localizedString(for: lastRun, relativeTo: ctx.date))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                // Soft, near-neutral tint instead of saturated accent — the
                // Raycast / macOS Spotlight pattern. Text stays readable in
                // both light and dark mode without color inversion gymnastics.
                .fill(isSelected ? Color.primary.opacity(0.08) : .clear)
        )
    }

    private var iconTint: Color {
        if isRunning { return .green }
        return task.isManualOnly ? .orange : .blue
    }

    private var subtitle: String {
        if isRunning { return L10n.tr("quick_launcher.subtitle.running") }
        return task.isManualOnly ? L10n.tr("schedule.manual_only") : task.repeatDisplayName
    }
}
