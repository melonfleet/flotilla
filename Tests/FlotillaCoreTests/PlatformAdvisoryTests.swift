import Foundation
import Testing
@testable import FlotillaCore

@Suite("Platform advisories: macOS and the container kernel")
struct PlatformAdvisoryTests {
    private func fixture(_ name: String = "vulnerability-report-platform") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func platform() throws -> VulnerabilityReport.Platform {
        try #require(VulnerabilityReport.decode(fixture()).platform)
    }

    /// The captured report, as JSON, with its platform section changed.
    private func mutated(_ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        var section = try #require(object["platform"] as? [String: Any])
        change(&section)
        object["platform"] = section
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func refused(_ change: (inout [String: Any]) -> Void, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let data = try mutated(change)
        #expect(throws: VulnerabilityReport.Failure.self, sourceLocation: sourceLocation) { try VulnerabilityReport.decode(data) }
    }

    private func kernelChange(_ change: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) -> Void {
        { section in
            var kernel = section["kernel"] as! [String: Any]
            change(&kernel)
            section["kernel"] = kernel
        }
    }

    private func olderChange(_ change: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) -> Void {
        kernelChange { kernel in
            var list = kernel["kernels"] as! [[String: Any]]
            change(&list[0])
            kernel["kernels"] = list
        }
    }

    private func releaseChange(_ change: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) -> Void {
        { section in
            var macOS = section["macOS"] as! [String: Any]
            var list = macOS["releases"] as! [[String: Any]]
            let index = list.firstIndex { ($0["version"] as? String) == "26.7.1" }!
            change(&list[index])
            macOS["releases"] = list
            section["macOS"] = macOS
        }
    }

    // MARK: The captured section

    @Test func theCapturedSectionDecodes() throws {
        let report = try VulnerabilityReport.decode(fixture())
        #expect(report.schema == 1)
        #expect(report.images.count == 2)
        let platform = try #require(report.platform)
        #expect(platform.macOS?.current == ["27.0.1", "26.7.1"])
        #expect(platform.kernel?.container == "1.5.0")
        #expect(platform.kernel?.recommended == .init(release: "6.18.35", binary: "vmlinux-6.18.35-197-debug"))
        let older = try #require(platform.kernel?.kernels.first)
        #expect(older.release == "6.18.15")
        #expect(older.top.count == VulnerabilityReport.Platform.maxKernelTop)
        #expect(older.top.map(\.score) == older.top.map(\.score).sorted(by: >))
    }

    @Test func aReportWithoutTheSectionIsAWholeReport() throws {
        let report = try VulnerabilityReport.decode(fixture("vulnerability-report"))
        #expect(report.platform == nil)
    }

    @Test func aKeyThisVersionDoesNotKnowIsIgnoredWhichIsHowOlderAppsReadThisOne() throws {
        // An older app's `VulnerabilityReport` has no `platform`, and ignores it the same way.
        var object = try #require(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        object["somethingNewer"] = ["a": 1]
        let report = try VulnerabilityReport.decode(JSONSerialization.data(withJSONObject: object))
        #expect(report.platform != nil)
        object.removeValue(forKey: "platform")
        #expect(try VulnerabilityReport.decode(JSONSerialization.data(withJSONObject: object)).images
                == report.images)
    }

    // MARK: macOS, matched here

    @Test func anOlderTahoeHasEveryLaterFixCountedOnce() throws {
        let platform = try platform()
        let advice = try #require(platform.macOSAdvice(for: "26.0.1"))
        // Independently: the distinct CVEs of every 26.x release after 26.0.1.
        let later = try #require(platform.macOS).releases.filter {
            let v = VulnerabilityReport.Platform.macOSVersion($0.version)!
            return v[0] == 26 && [26, 0, 1].lexicographicallyPrecedes(v)
        }
        #expect(advice.newer == "26.7.1")
        #expect(advice.fixes == Set(later.flatMap(\.cves)).count)
        #expect(advice.exploited == 4)  // 26.2's two, 26.3's one, 26.7.1's one
        #expect(advice.nextMajor == "27.0.1")
        #expect(advice.summary == "26.7.1 fixes \(advice.fixes) security issues, 4 actively exploited.")
        #expect(advice.asOf != nil)
    }

    @Test func oneReleaseBehind() throws {
        let advice = try #require(try platform().macOSAdvice(for: "26.7"))
        #expect(advice.newer == "26.7.1")
        #expect(advice.summary == "26.7.1 fixes 1 security issue, 1 actively exploited.")
    }

    @Test func upToDateAndNewerWithNoFixes() throws {
        let platform = try platform()
        let current = try #require(platform.macOSAdvice(for: "27.0.1"))
        #expect(current.newer == nil)
        #expect(current.nextMajor == nil)
        #expect(current.summary == "The newest release of macOS 27.")
        // 27.0.1 has no published CVE entries.
        let previous = try #require(platform.macOSAdvice(for: "27.0"))
        #expect(previous.summary == "27.0.1 is available. Apple lists no security fixes in it.")
        // Newer than anything Apple lists (a beta): nothing is waiting.
        #expect(try #require(platform.macOSAdvice(for: "27.1")).newer == nil)
    }

    @Test func versionsOutsideTheReportAreNotJudged() throws {
        let platform = try platform()
        for version in ["15.7.4", "14", "", "26.0.1\n", "26..1", "26.0.1.1", "٢٦", "28"] {
            #expect(platform.macOSAdvice(for: version) == nil, "\(version.debugDescription)")
        }
    }

    // MARK: The kernel, matched here

    @Test func kernelAdviceIsAnExactMatch() throws {
        let platform = try platform()
        let recommended = try #require(platform.kernel?.recommended)
        #expect(platform.kernelAdvice(forRelease: "6.18.35") == .recommended(recommended))
        guard case .older(let older, _)? = platform.kernelAdvice(forRelease: "6.18.15") else {
            Issue.record("expected the older kernel"); return
        }
        #expect(older.serious == older.critical + older.high)
        #expect(platform.kernelAdvice(forRelease: "6.18.15")?.summary
                == "The recommended 6.18.35 fixes \(older.serious) high-severity issues in 6.18.15 (\(older.critical) critical).")
        // No range is inferred: a kernel the table doesn't list is said to be not covered.
        #expect(platform.kernelAdvice(forRelease: "6.18.20") == .notCovered(release: "6.18.20", recommended: recommended))
        for bad in ["", "6.18.15\n", "6", "vmlinux-6.18.15-186", "6.18.15-debug"] {
            #expect(platform.kernelAdvice(forRelease: bad) == nil, "\(bad.debugDescription)")
        }
    }

    /// The same table as `KERNEL_NAMES` in the library's test_report.py.
    @Test func kernelReleasesFromKataFileNames() {
        let names: [(String, String?)] = [
            ("vmlinux-6.18.35-197-debug", "6.18.35"), ("vmlinux-6.18.15-186", "6.18.15"),
            ("vmlinux-6.12.28-153", "6.12.28"), ("vmlinux-6.19-rc1-200", "6.19-rc1"),
            ("vmlinux-6.18.35", "6.18.35"), ("vmlinux-kvm", nil), ("vmlinux-6.18.35-rt-1", nil),
            ("bzImage-6.18.35", nil), ("vmlinux-6.18.35\n", nil), ("vmlinux-../6.1", nil),
        ]
        for (name, release) in names {
            #expect(VulnerabilityReport.Platform.kernelRelease(fromBinary: name) == release, "\(name.debugDescription)")
        }
    }

    @Test func theScopeSentenceSaysTheFlawStaysInTheVM() {
        #expect(VulnerabilityReport.Platform.kernelScope.contains("its own small Linux VM"))
        #expect(VulnerabilityReport.Platform.kernelScope.contains("not the Mac"))
    }

    // MARK: Structure refuses the file

    @Test func aBadMacOSSectionRefusesTheReport() throws {
        try refused(releaseChange { $0["exploited"] = ["CVE-2026-11111"] })     // not among its CVEs
        try refused(releaseChange { $0["cves"] = ["CVE-2026-86950", "CVE-2026-86950"] })
        try refused(releaseChange { $0["cves"] = ["cve-2026-86950"]; $0["exploited"] = [] })
        try refused(releaseChange { $0["released"] = "2026-02-30" })
        try refused(releaseChange { $0["version"] = "26.7.1 " })
        try refused(releaseChange { $0["version"] = "26.7" })                   // listed twice
        try refused(releaseChange { $0["cves"] = (0...VulnerabilityReport.Platform.maxCVEsPerRelease).map { String(format: "CVE-2026-%05d", $0) } })
        try refused { section in
            var macOS = section["macOS"] as! [String: Any]
            macOS["current"] = []
            section["macOS"] = macOS
        }
        try refused { section in
            var macOS = section["macOS"] as! [String: Any]
            macOS["checked"] = "today"
            section["macOS"] = macOS
        }
        try refused { $0 = [:] }
    }

    @Test func aBadKernelSectionRefusesTheReport() throws {
        try refused(olderChange { $0["critical"] = -1 })
        try refused(olderChange { $0["high"] = VulnerabilityReport.maxCount + 1 })
        try refused(olderChange { $0["release"] = "6.18.16" })                   // not its binary's
        try refused(olderChange { $0["release"] = "6.18.35"; $0["binary"] = "vmlinux-6.18.35-1" }) // the recommended one
        try refused(olderChange { $0["critical"] = 0; $0["high"] = 0 })          // top outnumbers counts
        try refused(olderChange { item in
            var top = item["top"] as! [[String: Any]]
            top[0]["score"] = 6.9
            item["top"] = top
        })
        try refused(olderChange { item in
            var top = item["top"] as! [[String: Any]]
            top[0]["id"] = "GHSA-xxxx-yyyy"
            item["top"] = top
        })
        try refused(olderChange { item in
            var top = item["top"] as! [[String: Any]]
            top.append(top[0])
            item["top"] = top
        })
        try refused(kernelChange { $0["container"] = "1.5" })
        try refused(kernelChange { $0["recommended"] = ["release": "6.18.36", "binary": "vmlinux-6.18.35-197-debug"] })
        try refused(kernelChange { kernel in
            let list = kernel["kernels"] as! [[String: Any]]
            kernel["kernels"] = list + list
        })
    }

    // MARK: Free text is cleaned

    @Test func nastyFreeTextIsReplacedNotRefused() throws {
        for text in VulnerabilityReportTests.nastyText {
            let names = try VulnerabilityReport.decode(mutated(releaseChange { $0["name"] = text }))
            let name = try #require(names.platform?.macOS?.releases.first { $0.version == "26.7.1" }?.name)
            #expect(name.utf8.count <= VulnerabilityReport.maxText && !name.isEmpty, "\(text.debugDescription)")
            #expect(name.unicodeScalars.allSatisfy(VulnerabilityReport.isPlain), "\(text.debugDescription)")
            let summaries = try VulnerabilityReport.decode(mutated(olderChange { item in
                var top = item["top"] as! [[String: Any]]
                top[0]["summary"] = text
                item["top"] = top
            }))
            let summary = try #require(summaries.platform?.kernel?.kernels.first?.top.first?.summary)
            #expect(summary.utf8.count <= VulnerabilityReport.maxText, "\(text.debugDescription)")
            #expect(summary.unicodeScalars.allSatisfy(VulnerabilityReport.isPlain), "\(text.debugDescription)")
        }
    }
}
