#if DEBUG
import SwiftUI

/// Side-by-side preview of candidate layouts for the "Date & Time" section of
/// the task editor. Dev-only — wired into the View menu in `TaskTickApp`.
/// All variants share the same backing state so you can edit values once and
/// see how every layout renders them.
struct ScheduleLayoutDemoView: View {
    @State private var hasDate = true
    @State private var hasTime = true
    @State private var scheduledDate: Date = {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.hour = 9
        c.minute = 0
        return Calendar.current.date(from: c) ?? Date()
    }()

    @State private var extras: [Date] = {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let mk: (Int, Int) -> Date = { h, m in
            var c = cal.dateComponents([.year, .month, .day], from: today)
            c.hour = h
            c.minute = m
            return cal.date(from: c) ?? today
        }
        return [mk(12, 0), mk(18, 0)]
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("调度排版方案 (Demo · v2)")
                    .font(.title).bold()
                Text("4 个方案共享同一组数据。改任意一处会同步到其他方案。")
                    .font(.callout).foregroundStyle(.secondary)

                variantBlock(
                    title: "方案 E · 对称按钮（主行 +，extras 行 −）",
                    desc: "去掉独立的添加按钮 row；主时间行尾自带 +，extras 行尾是 −；视觉对称、操作明确"
                ) { variantE }

                variantBlock(
                    title: "方案 F · 弹出按钮 (.compact)",
                    desc: "macOS 14+ 的 .compact 把 picker 渲染成胶囊按钮，点击弹原生时间选择"
                ) { variantF }

                variantBlock(
                    title: "方案 G · 时间卡片（GroupBox）",
                    desc: "把所有时间用 GroupBox 包成一张子卡片，跟外层 form 视觉分层"
                ) { variantG }

                variantBlock(
                    title: "方案 H · 极简文本 (.field)",
                    desc: "picker 用 .field 风格 → 仅显示文本框，无 stepper 箭头、视觉最轻"
                ) { variantH }
            }
            .padding(24)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 700)
    }

    @ViewBuilder
    private func variantBlock<Content: View>(
        title: String,
        desc: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(desc).font(.caption).foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Variant E: Symmetric +/− buttons (no separate "Add" row)

    private var variantE: some View {
        Form {
            Section {
                dateRow
                timeToggleRow

                if hasTime {
                    // Main row: picker + trailing "+" (adds a new extra).
                    HStack(spacing: 6) {
                        Spacer()
                        DatePicker("", selection: $scheduledDate, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.stepperField)
                            .labelsHidden()
                        Button {
                            let anchor = extras.max() ?? scheduledDate
                            extras.append(Calendar.current.date(byAdding: .hour, value: 1, to: anchor) ?? anchor)
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Color.accentColor)
                                .imageScale(.large)
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(Array(extras.enumerated()), id: \.offset) { idx, _ in
                        HStack(spacing: 6) {
                            Spacer()
                            DatePicker(
                                "",
                                selection: Binding(
                                    get: { extras[idx] },
                                    set: { extras[idx] = $0 }
                                ),
                                displayedComponents: .hourAndMinute
                            )
                            .datePickerStyle(.stepperField)
                            .labelsHidden()
                            Button {
                                extras.remove(at: idx)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .imageScale(.large)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } header: {
                Text("日期与时间")
            } footer: {
                Text("点击主时间右侧 + 添加；每条 − 删除。所有时间共用同一重复规则。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: hasTime ? 320 : 200)
    }

    // MARK: - Variant F: .compact popup-style picker

    private var variantF: some View {
        Form {
            Section {
                dateRow
                timeToggleRow

                if hasTime {
                    VStack(alignment: .trailing, spacing: 8) {
                        HStack(spacing: 6) {
                            Spacer()
                            DatePicker("", selection: $scheduledDate, displayedComponents: .hourAndMinute)
                                .datePickerStyle(.compact)
                                .labelsHidden()
                                .frame(width: 90)
                        }
                        ForEach(Array(extras.enumerated()), id: \.offset) { idx, _ in
                            HStack(spacing: 6) {
                                Spacer()
                                DatePicker(
                                    "",
                                    selection: Binding(
                                        get: { extras[idx] },
                                        set: { extras[idx] = $0 }
                                    ),
                                    displayedComponents: .hourAndMinute
                                )
                                .datePickerStyle(.compact)
                                .labelsHidden()
                                .frame(width: 90)
                                Button {
                                    extras.remove(at: idx)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        HStack {
                            Spacer()
                            Button {
                                let anchor = extras.max() ?? scheduledDate
                                extras.append(Calendar.current.date(byAdding: .hour, value: 1, to: anchor) ?? anchor)
                            } label: {
                                Label("添加时间", systemImage: "plus")
                                    .font(.callout)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.accentColor)
                        }
                        .padding(.top, 4)
                    }
                }
            } header: {
                Text("日期与时间")
            }
        }
        .formStyle(.grouped)
        .frame(height: hasTime ? 320 : 200)
    }

    // MARK: - Variant G: GroupBox card containing the time list

    private var variantG: some View {
        Form {
            Section {
                dateRow
                timeToggleRow

                if hasTime {
                    GroupBox {
                        VStack(alignment: .trailing, spacing: 8) {
                            HStack {
                                Text("09:00").foregroundStyle(.secondary).font(.caption).hidden() // alignment spacer
                                Spacer()
                                DatePicker("", selection: $scheduledDate, displayedComponents: .hourAndMinute)
                                    .datePickerStyle(.stepperField)
                                    .labelsHidden()
                            }
                            ForEach(Array(extras.enumerated()), id: \.offset) { idx, _ in
                                HStack(spacing: 6) {
                                    Spacer()
                                    DatePicker(
                                        "",
                                        selection: Binding(
                                            get: { extras[idx] },
                                            set: { extras[idx] = $0 }
                                        ),
                                        displayedComponents: .hourAndMinute
                                    )
                                    .datePickerStyle(.stepperField)
                                    .labelsHidden()
                                    Button {
                                        extras.remove(at: idx)
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            Divider()
                            HStack {
                                Spacer()
                                Button {
                                    let anchor = extras.max() ?? scheduledDate
                                    extras.append(Calendar.current.date(byAdding: .hour, value: 1, to: anchor) ?? anchor)
                                } label: {
                                    Label("添加时间", systemImage: "plus")
                                        .font(.callout)
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(Color.accentColor)
                            }
                        }
                    } label: {
                        Text("触发时刻").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("日期与时间")
            }
        }
        .formStyle(.grouped)
        .frame(height: hasTime ? 360 : 200)
    }

    // MARK: - Variant H: Minimal .field style (no stepper arrows)

    private var variantH: some View {
        Form {
            Section {
                dateRow
                timeToggleRow

                if hasTime {
                    VStack(alignment: .trailing, spacing: 8) {
                        HStack {
                            Spacer()
                            DatePicker("", selection: $scheduledDate, displayedComponents: .hourAndMinute)
                                .datePickerStyle(.field)
                                .labelsHidden()
                        }
                        ForEach(Array(extras.enumerated()), id: \.offset) { idx, _ in
                            HStack(spacing: 6) {
                                Spacer()
                                DatePicker(
                                    "",
                                    selection: Binding(
                                        get: { extras[idx] },
                                        set: { extras[idx] = $0 }
                                    ),
                                    displayedComponents: .hourAndMinute
                                )
                                .datePickerStyle(.field)
                                .labelsHidden()
                                Button {
                                    extras.remove(at: idx)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        HStack {
                            Spacer()
                            Button {
                                let anchor = extras.max() ?? scheduledDate
                                extras.append(Calendar.current.date(byAdding: .hour, value: 1, to: anchor) ?? anchor)
                            } label: {
                                Label("添加时间", systemImage: "plus")
                                    .font(.callout)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.accentColor)
                        }
                        .padding(.top, 4)
                    }
                }
            } header: {
                Text("日期与时间")
            }
        }
        .formStyle(.grouped)
        .frame(height: hasTime ? 320 : 200)
    }

    // MARK: - Shared rows (date toggle / picker + time toggle)

    private var dateRow: some View {
        Group {
            Toggle(isOn: $hasDate) {
                Label("日期", systemImage: "calendar")
            }
            if hasDate {
                HStack {
                    Spacer()
                    DatePicker("", selection: $scheduledDate, displayedComponents: .date)
                        .datePickerStyle(.stepperField)
                        .labelsHidden()
                }
            }
        }
    }

    private var timeToggleRow: some View {
        Toggle(isOn: $hasTime) {
            Label("时间", systemImage: "clock")
        }
    }
}

#endif
