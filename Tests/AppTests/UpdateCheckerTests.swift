import Testing
import Foundation
@testable import TaskTickApp

@Suite("UpdateChecker version selection")
struct UpdateCheckerTests {

    private func release(_ tag: String) -> UpdateChecker.ReleaseInfo {
        UpdateChecker.ReleaseInfo(tag_name: tag, name: nil, body: nil, html_url: nil, assets: nil)
    }

    @Test("picks the highest version across mirrors (Gitee lagging behind GitHub)")
    func picksHighestAcrossMirrors() {
        let gitee = release("v1.10.2")   // mirror not yet updated
        let github = release("v1.11.0")  // newer release on the other host
        #expect(UpdateChecker.pickHighestVersionRelease([gitee, github])?.tag_name == "v1.11.0")
        #expect(UpdateChecker.pickHighestVersionRelease([github, gitee])?.tag_name == "v1.11.0")
    }

    @Test("equal versions return one of them, not nil")
    func equalVersions() {
        #expect(UpdateChecker.pickHighestVersionRelease([release("v1.11.0"), release("v1.11.0")])?.tag_name == "v1.11.0")
    }

    @Test("empty input returns nil")
    func empty() {
        #expect(UpdateChecker.pickHighestVersionRelease([]) == nil)
    }

    @Test("isVersionNewer compares semantic parts, tolerant of v prefix")
    func versionCompare() {
        #expect(UpdateChecker.isVersionNewer(remote: "1.11.0", current: "1.10.2") == true)
        #expect(UpdateChecker.isVersionNewer(remote: "1.10.2", current: "1.11.0") == false)
        #expect(UpdateChecker.isVersionNewer(remote: "1.11.0", current: "1.11.0") == false)
    }
}
