import Testing
import Foundation
import SwiftData
import TaskTickCore
@testable import TaskTickApp

/// Issue #55: the Notification and Push tabs each decide on their own. These
/// pin down the rules both tabs promise, and — the part that touches existing
/// user data — that a task upgraded from before the split alerts exactly as it
/// did, until the user saves it with push-side settings of its own.
@Suite("Completion alert rules")
@MainActor
struct CompletionAlertRulesTests {

    private typealias Rule = CompletionAlertRules.Rule

    @Test("单条规则：成功看成功开关和有无输出，失败只看失败开关")
    func ruleTruthTable() {
        let all = Rule(onSuccess: true, onFailure: true, onlyWhenOutput: false)
        #expect(all.fires(succeeded: true, hasOutput: false))
        #expect(all.fires(succeeded: false, hasOutput: false))

        let failuresOnly = Rule(onSuccess: false, onFailure: true, onlyWhenOutput: false)
        #expect(!failuresOnly.fires(succeeded: true, hasOutput: true))
        #expect(failuresOnly.fires(succeeded: false, hasOutput: true))

        let successesOnly = Rule(onSuccess: true, onFailure: false, onlyWhenOutput: false)
        #expect(successesOnly.fires(succeeded: true, hasOutput: false))
        #expect(!successesOnly.fires(succeeded: false, hasOutput: true))

        let quiet = Rule(onSuccess: true, onFailure: true, onlyWhenOutput: true)
        #expect(!quiet.fires(succeeded: true, hasOutput: false))
        #expect(quiet.fires(succeeded: true, hasOutput: true))
        // An empty failure still alerts — no output is often why it failed.
        #expect(quiet.fires(succeeded: false, hasOutput: false))
    }

    @Test("没开远程推送的任务不推送")
    func pushOffMeansNoPushRule() {
        let task = ScheduledTask(name: "t")
        #expect(CompletionAlertRules(task: task).push == nil)
    }

    @Test("升级来的任务：关掉成功/失败通知也照旧推送，和拆分前一致")
    func upgradedTaskKeepsPushingOnEveryRun() {
        let task = ScheduledTask(name: "t", notifyOnSuccess: false, notifyOnFailure: false)
        task.pushEnabled = true
        let rules = CompletionAlertRules(task: task)
        #expect(!rules.notification.fires(succeeded: true, hasOutput: true))
        #expect(!rules.notification.fires(succeeded: false, hasOutput: true))
        #expect(rules.push?.fires(succeeded: true, hasOutput: true) == true)
        #expect(rules.push?.fires(succeeded: false, hasOutput: true) == true)
    }

    @Test("只在失败时推送：成功不推，系统通知不受影响")
    func pushFailuresOnly() {
        let task = ScheduledTask(name: "t")
        task.pushEnabled = true
        task.pushOnSuccess = false
        let rules = CompletionAlertRules(task: task)
        #expect(rules.push?.fires(succeeded: true, hasOutput: true) == false)
        #expect(rules.push?.fires(succeeded: false, hasOutput: true) == true)
        #expect(rules.notification.fires(succeeded: true, hasOutput: true))
    }

    @Test("通知的开关不影响推送，推送的开关不影响通知")
    func sidesAreIndependent() {
        let task = ScheduledTask(name: "t", notifyOnSuccess: true, notifyOnFailure: false)
        task.pushEnabled = true
        task.pushOnSuccess = false
        task.pushOnFailure = true
        let rules = CompletionAlertRules(task: task)
        #expect(rules.notification.fires(succeeded: true, hasOutput: true))
        #expect(!rules.notification.fires(succeeded: false, hasOutput: true))
        #expect(rules.push?.fires(succeeded: true, hasOutput: true) == false)
        #expect(rules.push?.fires(succeeded: false, hasOutput: true) == true)
    }

    @Test("「仅在有输出时」：推送端没设过就沿用通知端，设过之后各管各的")
    func onlyWhenOutputFallsBackUntilSet() {
        let task = ScheduledTask(name: "t")
        task.pushEnabled = true
        task.notifyOnlyWhenOutput = true
        // Before the split this switch silenced the empty-run push too.
        #expect(task.pushOnlyWhenOutputOverride == nil)
        #expect(task.pushOnlyWhenOutput)
        #expect(CompletionAlertRules(task: task).push?.fires(succeeded: true, hasOutput: false) == false)

        task.pushOnlyWhenOutput = false
        let rules = CompletionAlertRules(task: task)
        #expect(rules.push?.fires(succeeded: true, hasOutput: false) == true)
        #expect(!rules.notification.fires(succeeded: true, hasOutput: false))

        // Once set, the notification side no longer drags push along.
        task.notifyOnlyWhenOutput = false
        task.pushOnlyWhenOutput = true
        #expect(task.pushOnlyWhenOutput)
        #expect(!task.notifyOnlyWhenOutput)
    }

    @Test("推送内容：推送端没设过就沿用通知内容，设过之后互不影响")
    func pushTemplateFallsBackUntilSet() {
        let task = ScheduledTask(name: "t")
        task.notificationTemplateEnabled = true
        task.notificationTemplate = "done: {{lastLine}}"
        #expect(task.pushTemplateEnabled)
        #expect(task.pushTemplate == "done: {{lastLine}}")

        task.pushTemplateEnabled = false
        task.pushTemplate = "push: {{status}}"
        #expect(!task.pushTemplateEnabled)
        #expect(task.pushTemplate == "push: {{status}}")
        #expect(task.notificationTemplateEnabled)
        #expect(task.notificationTemplate == "done: {{lastLine}}")

        // An explicitly empty push template stays empty rather than falling back.
        task.pushTemplate = ""
        #expect(task.pushTemplate == "")
    }

    @Test("新字段存进 SwiftData 再读回：没设过仍是 nil，设过的值原样保留")
    func overridesSurviveAStoreRoundTrip() throws {
        let schema = Schema([ScheduledTask.self, ExecutionLog.self])
        let cfg = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [cfg])
        let ctx = container.mainContext

        let untouched = ScheduledTask(name: "untouched")
        let set = ScheduledTask(name: "set")
        set.pushOnSuccess = false
        set.pushOnlyWhenOutput = false
        set.pushTemplateEnabled = false
        set.pushTemplate = ""
        ctx.insert(untouched)
        ctx.insert(set)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<ScheduledTask>())
        let a = try #require(fetched.first { $0.name == "untouched" })
        #expect(a.pushOnSuccess && a.pushOnFailure)
        #expect(a.pushOnlyWhenOutputOverride == nil)
        #expect(a.pushTemplateEnabledOverride == nil)
        #expect(a.pushTemplateOverride == nil)

        let b = try #require(fetched.first { $0.name == "set" })
        #expect(!b.pushOnSuccess)
        #expect(b.pushOnlyWhenOutputOverride == false)
        #expect(b.pushTemplateEnabledOverride == false)
        #expect(b.pushTemplateOverride == "")
    }

    @Test("备份导出再导入：推送端设置原样还原，没设过的仍然沿用通知端")
    func exportRoundTripKeepsPushSettings() throws {
        let set = ScheduledTask(name: "set")
        set.pushOnSuccess = false
        set.pushOnlyWhenOutput = false
        set.pushTemplateEnabled = true
        set.pushTemplate = "push: {{status}}"
        let untouched = ScheduledTask(name: "untouched")
        untouched.notifyOnlyWhenOutput = true

        func roundTrip(_ task: ScheduledTask) throws -> ScheduledTask {
            let data = try JSONEncoder().encode(TaskExporter.makeExported(task))
            let item = try JSONDecoder().decode(TaskExporter.ExportedTask.self, from: data)
            return TaskExporter.makeTask(from: item)
        }

        let a = try roundTrip(set)
        #expect(!a.pushOnSuccess && a.pushOnFailure)
        #expect(a.pushOnlyWhenOutputOverride == false)
        #expect(a.pushTemplateEnabledOverride == true)
        #expect(a.pushTemplateOverride == "push: {{status}}")

        let b = try roundTrip(untouched)
        #expect(b.pushOnlyWhenOutputOverride == nil)
        #expect(b.pushOnlyWhenOutput)
    }

    @Test("拆分前的老备份：推送默认成功失败都推，其余沿用通知端")
    func preSplitBackupRestoresOldBehavior() throws {
        let json = """
        {"name":"old","scriptBody":"echo","shell":"/bin/zsh","repeatType":"daily",
         "endRepeatType":"never","timeoutSeconds":300,"notifyOnSuccess":false,
         "notifyOnFailure":true,"isEnabled":true,"notifyOnlyWhenOutput":true,
         "barkPushEnabled":true,"notificationTemplateEnabled":true,
         "notificationTemplate":"hi {{name}}"}
        """
        let item = try JSONDecoder().decode(TaskExporter.ExportedTask.self, from: Data(json.utf8))
        let task = TaskExporter.makeTask(from: item)
        #expect(task.pushOnSuccess && task.pushOnFailure)
        #expect(task.pushOnlyWhenOutput)
        #expect(task.pushTemplateEnabled)
        #expect(task.pushTemplate == "hi {{name}}")
    }

    @Test("只有空白的 stdout 算没输出")
    func whitespaceIsNoOutput() {
        #expect(!CompletionAlertRules.hasOutput(stdout: ""))
        #expect(!CompletionAlertRules.hasOutput(stdout: " \n\t\n"))
        #expect(CompletionAlertRules.hasOutput(stdout: "\nok\n"))
    }
}
