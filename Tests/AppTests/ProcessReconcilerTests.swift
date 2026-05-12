import Testing
import Foundation
@testable import TaskTickCore

@Suite("ProcessReconciler Tests")
struct ProcessReconcilerTests {

    @Test("isAlive returns true for self pid")
    func selfIsAlive() {
        let pid = getpid()
        #expect(ProcessReconciler.isAlive(pid: pid) == true)
    }

    @Test("isAlive returns false for an obviously-dead pid")
    func reapedProcessIsNotAlive() throws {
        // Spawn /usr/bin/true, wait for it, then probe its pid.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try proc.run()
        proc.waitUntilExit()
        let pid = proc.processIdentifier
        // /usr/bin/true exits immediately; pid is reaped by the time waitUntilExit returns.
        #expect(ProcessReconciler.isAlive(pid: pid) == false)
    }

    @Test("startTime returns non-empty string for live pid")
    func startTimeForSelfIsNonEmpty() {
        let pid = getpid()
        let s = ProcessReconciler.startTime(pid: pid)
        #expect(s != nil)
        #expect(s?.isEmpty == false)
    }

    @Test("startTime returns nil for a dead pid")
    func startTimeForDeadPidIsNil() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try proc.run()
        proc.waitUntilExit()
        let pid = proc.processIdentifier
        #expect(ProcessReconciler.startTime(pid: pid) == nil)
    }

    @Test("startTime is stable across calls for the same live process")
    func startTimeIsStable() {
        let pid = getpid()
        let a = ProcessReconciler.startTime(pid: pid)
        let b = ProcessReconciler.startTime(pid: pid)
        #expect(a != nil)
        #expect(a == b)
    }
}
