import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum ScriptSource: String, CaseIterable {
    case inline
    case file

    var label: String {
        switch self {
        case .inline: L10n.tr("editor.script.source.inline")
        case .file: L10n.tr("editor.script.source.file")
        }
    }
}

struct TaskEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let task: ScheduledTask?

    @State private var name = ""
    @State private var scheduleType: ScheduleType = .interval
    @State private var cronExpression = "* * * * *"
    @State private var intervalSeconds = 60
    @State private var shell = "/bin/zsh"
    @State private var scriptBody = ""
    @State private var scriptSource: ScriptSource = .inline
    @State private var scriptFilePath = ""
    @State private var workingDirectory = ""
    @State private var timeoutSeconds = 300
    @State private var notifyOnSuccess = false
    @State private var notifyOnFailure = true
    @State private var isEnabled = true

    var isEditing: Bool { task != nil }

    var canSave: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespaces).isEmpty
        let hasScript: Bool
        if scriptSource == .inline {
            hasScript = !scriptBody.trimmingCharacters(in: .whitespaces).isEmpty
        } else {
            hasScript = !scriptFilePath.isEmpty && FileManager.default.fileExists(atPath: scriptFilePath)
        }
        return hasName && hasScript
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.tr("editor.section.basic")) {
                    TextField(L10n.tr("editor.name"), text: $name, prompt: Text(L10n.tr("editor.name.placeholder")))
                    Toggle(L10n.tr("editor.enabled"), isOn: $isEnabled)
                }

                Section(L10n.tr("editor.section.schedule")) {
                    Picker(L10n.tr("editor.schedule_type"), selection: $scheduleType) {
                        ForEach(ScheduleType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }

                    if scheduleType == .cron {
                        CronEditorView(expression: $cronExpression)
                    } else {
                        LabeledContent(L10n.tr("editor.interval")) {
                            HStack(spacing: 6) {
                                TextField("", value: $intervalSeconds, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80)
                                    .multilineTextAlignment(.trailing)
                                Text(L10n.tr("editor.interval.seconds"))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section(L10n.tr("editor.section.script")) {
                    // Script source picker
                    Picker(L10n.tr("editor.script.source"), selection: $scriptSource) {
                        ForEach(ScriptSource.allCases, id: \.self) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)

                    if scriptSource == .inline {
                        ScriptEditorView(scriptBody: $scriptBody)
                    } else {
                        // File picker
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.secondary)
                                if scriptFilePath.isEmpty {
                                    Text(L10n.tr("editor.script.no_file"))
                                        .foregroundStyle(.tertiary)
                                } else {
                                    Text(scriptFilePath)
                                        .font(.system(.body, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Button(L10n.tr("editor.script.choose_file")) {
                                    chooseFile()
                                }
                                .pointerCursor()
                            }

                            // Show file preview if selected
                            if !scriptFilePath.isEmpty {
                                if let content = try? String(contentsOfFile: scriptFilePath, encoding: .utf8) {
                                    Text(content.prefix(500) + (content.count > 500 ? "\n..." : ""))
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .padding(10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(.black.opacity(0.03))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(.separator, lineWidth: 0.5)
                                        )
                                }
                            }
                        }
                    }

                    Picker(L10n.tr("editor.shell"), selection: $shell) {
                        Text("/bin/zsh").tag("/bin/zsh")
                        Text("/bin/bash").tag("/bin/bash")
                        Text("/bin/sh").tag("/bin/sh")
                    }

                    TextField(L10n.tr("editor.working_dir"), text: $workingDirectory, prompt: Text(L10n.tr("editor.working_dir.placeholder")))

                    LabeledContent(L10n.tr("editor.timeout")) {
                        HStack(spacing: 6) {
                            TextField("", value: $timeoutSeconds, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                            Text(L10n.tr("editor.timeout.seconds"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section(L10n.tr("editor.section.notification")) {
                    Toggle(L10n.tr("editor.notify_success"), isOn: $notifyOnSuccess)
                    Toggle(L10n.tr("editor.notify_failure"), isOn: $notifyOnFailure)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 520, minHeight: 560)
            .navigationTitle(isEditing ? L10n.tr("editor.title.edit") : L10n.tr("editor.title.new"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("editor.cancel")) { dismiss() }
                        .pointerCursor()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("editor.save")) { save() }
                        .pointerCursor()
                        .disabled(!canSave)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .onAppear(perform: loadTask)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .shellScript, .pythonScript,
            .plainText, .sourceCode,
            UTType(filenameExtension: "sh")!,
            UTType(filenameExtension: "zsh") ?? .plainText,
            UTType(filenameExtension: "rb") ?? .plainText,
            UTType(filenameExtension: "js") ?? .plainText,
        ]
        panel.message = L10n.tr("editor.script.choose_file")

        if panel.runModal() == .OK, let url = panel.url {
            scriptFilePath = url.path(percentEncoded: false)
        }
    }

    private func loadTask() {
        guard let task else { return }
        name = task.name
        scheduleType = task.schedule
        cronExpression = task.cronExpression ?? "* * * * *"
        intervalSeconds = task.intervalSeconds ?? 60
        shell = task.shell
        scriptBody = task.scriptBody
        workingDirectory = task.workingDirectory ?? ""
        timeoutSeconds = task.timeoutSeconds
        notifyOnSuccess = task.notifyOnSuccess
        notifyOnFailure = task.notifyOnFailure
        isEnabled = task.isEnabled

        if let filePath = task.scriptFilePath, !filePath.isEmpty {
            scriptSource = .file
            scriptFilePath = filePath
        } else {
            scriptSource = .inline
        }
    }

    private func save() {
        let target = task ?? ScheduledTask()

        target.name = name.trimmingCharacters(in: .whitespaces)
        target.schedule = scheduleType
        target.cronExpression = scheduleType == .cron ? cronExpression : nil
        target.intervalSeconds = scheduleType == .interval ? intervalSeconds : nil
        target.shell = shell
        target.workingDirectory = workingDirectory.isEmpty ? nil : workingDirectory
        target.timeoutSeconds = timeoutSeconds
        target.notifyOnSuccess = notifyOnSuccess
        target.notifyOnFailure = notifyOnFailure
        target.isEnabled = isEnabled
        target.updatedAt = Date()

        if scriptSource == .file {
            target.scriptFilePath = scriptFilePath
            target.scriptBody = "" // clear inline content
        } else {
            target.scriptFilePath = nil
            target.scriptBody = scriptBody
        }

        if isEnabled {
            target.nextRunAt = TaskScheduler.shared.computeNextRunDate(for: target)
        }

        if task == nil {
            modelContext.insert(target)
        }

        try? modelContext.save()
        TaskScheduler.shared.rebuildSchedule()
        dismiss()
    }
}
