import Foundation
import Testing
@testable import FlotillaCore

// MARK: - Valid files round-trip

@Test func fullyPopulatedFileParsesToExpectedValues() throws {
    let json = """
    {
        "version": 1,
        "machines": [
            { "name": "builder", "image": "alpine:3.22", "cpus": 4, "memory": "8G", "homeMount": "ro" }
        ],
        "containers": [
            {
                "name": "web",
                "image": "docker.io/library/nginx:latest",
                "ports": ["8080:80", "127.0.0.1:9000:9000/tcp"],
                "env": ["KEY=VALUE", "DEBUG=1"],
                "volumes": ["shared-data:/data:ro", "/Users/shared:/host:rw"],
                "cpus": 2,
                "memory": "512M"
            }
        ]
    }
    """
    let file = try Flotillafile.parse(json)

    #expect(file.version == 1)
    #expect(file.machines == [
        MachineSpec(name: "builder", image: "alpine:3.22", cpus: 4, memory: "8G", homeMount: .ro),
    ])
    #expect(file.containers == [
        ContainerSpec(name: "web", image: "docker.io/library/nginx:latest",
                      ports: ["8080:80", "127.0.0.1:9000:9000/tcp"],
                      env: ["KEY=VALUE", "DEBUG=1"],
                      volumes: ["shared-data:/data:ro", "/Users/shared:/host:rw"],
                      cpus: 2, memory: "512M"),
    ])
}

@Test func minimalFileNeedsOnlyVersion() throws {
    let file = try Flotillafile.parse(#"{"version": 1}"#)
    #expect(file.version == 1)
    #expect(file.machines.isEmpty)
    #expect(file.containers.isEmpty)
}

@Test func minimalEntriesNeedOnlyNameAndImage() throws {
    let file = try Flotillafile.parse("""
    {
        "version": 1,
        "machines": [{ "name": "m1", "image": "alpine:3.22" }],
        "containers": [{ "name": "c1", "image": "alpine:3.22" }]
    }
    """)
    #expect(file.machines == [MachineSpec(name: "m1", image: "alpine:3.22", cpus: nil, memory: nil, homeMount: nil)])
    #expect(file.containers == [
        ContainerSpec(name: "c1", image: "alpine:3.22", ports: [], env: [], volumes: [], cpus: nil, memory: nil),
    ])
}

// MARK: - Version handling

@Test func missingVersionIsRefused() {
    #expect(Flotillafile.parseResult(#"{"machines": []}"#) == .failure(.missingVersion))
    #expect(Flotillafile.parseResult(#"{}"#) == .failure(.missingVersion))
}

@Test func newerVersionIsRefusedRatherThanHalfRead() {
    // A "future" file that also has a field this build wouldn't recognise under version
    // 1 — the version check must fire before the unknown-key check does, so the error
    // names the real problem (the version) rather than a confusing "unknown field".
    let json = #"{"version": 2, "machines": [], "containers": [], "networks": []}"#
    #expect(Flotillafile.parseResult(json) == .failure(.unsupportedVersion(found: 2, supported: 1)))
}

@Test func zeroOrNegativeVersionIsRejectedAsInvalidRatherThanUnsupported() {
    if case .failure(.invalidValue(let context, let field, let value, _)) = Flotillafile.parseResult(#"{"version": 0}"#) {
        #expect(context == "Flotillafile")
        #expect(field == "version")
        #expect(value == "0")
    } else {
        Issue.record("expected .invalidValue for version 0")
    }
    if case .failure(.invalidValue) = Flotillafile.parseResult(#"{"version": -1}"#) {
        // ok
    } else {
        Issue.record("expected .invalidValue for a negative version")
    }
}

@Test func versionMustBeAnIntegerNotABooleanOrString() {
    // `true` bridges to `NSNumber` and, via `as? Int`, would silently read back as `1` on
    // both Darwin and Linux Foundation — the exact ambiguity this parser must not fall
    // into. `JSONDecoder` tracks the real JSON token type, so this must be a type error,
    // never a successful parse as version 1.
    guard case .failure(.wrongType) = Flotillafile.parseResult(#"{"version": true}"#) else {
        Issue.record("expected 'version: true' to be a type error, not a silently-accepted version 1")
        return
    }
    guard case .failure(.wrongType) = Flotillafile.parseResult(#"{"version": "1"}"#) else {
        Issue.record("expected a string version to be a type error")
        return
    }
}

// MARK: - Unknown keys

@Test func unknownTopLevelKeyIsRefused() {
    #expect(
        Flotillafile.parseResult(#"{"version": 1, "networks": []}"#)
            == .failure(.unknownField(context: "Flotillafile", field: "networks"))
    )
}

@Test func unknownMachineKeyIsRefused() {
    let json = #"{"version": 1, "machines": [{"name": "m1", "image": "alpine:3.22", "arch": "arm64"}]}"#
    #expect(
        Flotillafile.parseResult(json) == .failure(.unknownField(context: "machines[0]", field: "arch"))
    )
}

@Test func unknownContainerKeyIsRefused() {
    let json = #"{"version": 1, "containers": [{"name": "c1", "image": "alpine:3.22", "labels": []}]}"#
    #expect(
        Flotillafile.parseResult(json) == .failure(.unknownField(context: "containers[0]", field: "labels"))
    )
}

// MARK: - Required fields

@Test func machineWithoutNameIsRefused() {
    let json = #"{"version": 1, "machines": [{"image": "alpine:3.22"}]}"#
    #expect(
        Flotillafile.parseResult(json) == .failure(.missingField(context: "machines[0]", field: "name"))
    )
}

@Test func containerWithoutImageIsRefused() {
    let json = #"{"version": 1, "containers": [{"name": "c1"}]}"#
    #expect(
        Flotillafile.parseResult(json) == .failure(.missingField(context: "containers[0]", field: "image"))
    )
}

// MARK: - Per-field shape validation

@Test func machineNameMustBeAValidIdentifier() {
    let json = #"{"version": 1, "machines": [{"name": "not a name", "image": "alpine:3.22"}]}"#
    #expect(
        Flotillafile.parseResult(json)
            == .failure(.invalidValue(context: "machines[0]", field: "name", value: "not a name",
                                       rule: ValueShape.identifier.rule))
    )
}

@Test func imageReferenceRejectsPathTraversal() {
    let json = #"{"version": 1, "containers": [{"name": "c1", "image": "../../etc/passwd"}]}"#
    #expect(
        Flotillafile.parseResult(json)
            == .failure(.invalidValue(context: "containers[0]", field: "image", value: "../../etc/passwd",
                                       rule: ValueShape.imageReference.rule))
    )
}

@Test func cpusOutOfRangeIsRejected() {
    for bad in [0, -1, 2000] {
        let json = #"{"version": 1, "machines": [{"name": "m1", "image": "alpine:3.22", "cpus": \#(bad)}]}"#
        #expect(
            Flotillafile.parseResult(json)
                == .failure(.invalidValue(context: "machines[0]", field: "cpus", value: String(bad),
                                           rule: ValueShape.count.rule)),
            "expected cpus \(bad) to be rejected"
        )
    }
}

@Test func cpusMustBeAnIntegerNotABoolean() {
    let json = #"{"version": 1, "machines": [{"name": "m1", "image": "alpine:3.22", "cpus": true}]}"#
    guard case .failure(.wrongType) = Flotillafile.parseResult(json) else {
        Issue.record("expected 'cpus: true' to be a type error")
        return
    }
}

@Test func memoryShapeIsValidated() {
    // A bare digit string ("512") is a valid `memorySize` per `Allowlist.ValueShape` — it
    // reads as bytes, the same as the CLI's own shape — so it is deliberately not in
    // this bad list.
    for bad in ["512X", "", "GG", "-5M"] {
        let json = #"{"version": 1, "machines": [{"name": "m1", "image": "alpine:3.22", "memory": "\#(bad)"}]}"#
        #expect(
            Flotillafile.parseResult(json)
                == .failure(.invalidValue(context: "machines[0]", field: "memory", value: bad,
                                           rule: ValueShape.memorySize.rule)),
            "expected memory '\(bad)' to be rejected"
        )
    }
    for good in ["512M", "8G", "1T", "1P", "1B"] {
        let json = #"{"version": 1, "machines": [{"name": "m1", "image": "alpine:3.22", "memory": "\#(good)"}]}"#
        #expect(throws: Never.self, "expected memory '\(good)' to be accepted") {
            try Flotillafile.parse(json)
        }
    }
}

@Test func homeMountAcceptsOnlyTheThreeCLIValues() throws {
    for good in ["ro", "rw", "none"] {
        let json = #"{"version": 1, "machines": [{"name": "m1", "image": "alpine:3.22", "homeMount": "\#(good)"}]}"#
        let file = try Flotillafile.parse(json)
        #expect(file.machines[0].homeMount == HomeMountMode(rawValue: good))
    }
    let json = #"{"version": 1, "machines": [{"name": "m1", "image": "alpine:3.22", "homeMount": "off"}]}"#
    guard case .failure(.invalidValue(_, let field, let value, _)) = Flotillafile.parseResult(json) else {
        Issue.record("expected 'off' to be an invalid homeMount value")
        return
    }
    #expect(field == "homeMount")
    #expect(value == "off")
}

@Test func portMappingShapeIsValidated() {
    for bad in ["9998", "70000:80", "8080:", ":8080", "8080:80/sctp"] {
        let json = #"{"version": 1, "containers": [{"name": "c1", "image": "alpine:3.22", "ports": ["\#(bad)"]}]}"#
        #expect(
            Flotillafile.parseResult(json)
                == .failure(.invalidValue(context: "containers[0].ports", field: "ports", value: bad,
                                           rule: ValueShape.portMapping.rule)),
            "expected port '\(bad)' to be rejected"
        )
    }
}

@Test func envAssignmentShapeIsValidated() {
    for bad in ["NOVALUE", "1START=bad", "has space=bad"] {
        let json = #"{"version": 1, "containers": [{"name": "c1", "image": "alpine:3.22", "env": ["\#(bad)"]}]}"#
        #expect(
            Flotillafile.parseResult(json)
                == .failure(.invalidValue(context: "containers[0].env", field: "env", value: bad,
                                           rule: ValueShape.envAssignment.rule)),
            "expected env '\(bad)' to be rejected"
        )
    }
}

@Test func volumeSpecShapeIsValidated() {
    for bad in ["nodest", "data:relative/path", "data:/dest:bogus", "/:/dest", "data:/"] {
        let json = #"{"version": 1, "containers": [{"name": "c1", "image": "alpine:3.22", "volumes": ["\#(bad)"]}]}"#
        #expect(
            Flotillafile.parseResult(json)
                == .failure(.invalidValue(context: "containers[0].volumes", field: "volumes", value: bad,
                                           rule: ValueShape.mountSpec.rule)),
            "expected volume '\(bad)' to be rejected"
        )
    }
}

@Test func volumeSpecRejectsPathTraversalInDestination() {
    let json = #"{"version": 1, "containers": [{"name": "c1", "image": "alpine:3.22", "volumes": ["data:/../etc"]}]}"#
    guard case .failure(.invalidValue) = Flotillafile.parseResult(json) else {
        Issue.record("expected a traversing destination to be rejected")
        return
    }
}

// MARK: - Duplicate names

@Test func duplicateMachineNamesAreRejected() {
    let json = """
    {"version": 1, "machines": [
        {"name": "m1", "image": "alpine:3.22"},
        {"name": "m1", "image": "alpine:3.23"}
    ]}
    """
    #expect(Flotillafile.parseResult(json) == .failure(.duplicateName(context: "machines", name: "m1")))
}

@Test func duplicateContainerNamesAreRejected() {
    let json = """
    {"version": 1, "containers": [
        {"name": "c1", "image": "alpine:3.22"},
        {"name": "c1", "image": "alpine:3.23"}
    ]}
    """
    #expect(Flotillafile.parseResult(json) == .failure(.duplicateName(context: "containers", name: "c1")))
}

// MARK: - Bounds

@Test func fileOverTheByteLimitFailsBeforeParsing() {
    let json = #"{"version": 1}"#
    let tinyLimit = Flotillafile.Limits(maxFileBytes: json.utf8.count - 1)
    #expect(
        Flotillafile.parseResult(json, limits: tinyLimit)
            == .failure(.fileTooLarge(bytes: json.utf8.count, limit: tinyLimit.maxFileBytes))
    )
}

@Test func aPathologicallyLargeFileFailsFastRatherThanBeingParsed() {
    // Stand-in for "a 4 GB Flotillafile must fail fast": the byte-count gate runs before
    // any JSON parsing is attempted, so this large-but-not-actually-4GB payload proves
    // the same code path without the test itself needing gigabytes of memory.
    let hugeJSON = "{\"version\": 1, \"containers\": [" +
        (0..<200_000).map { "{\"name\": \"c\($0)\", \"image\": \"alpine:3.22\"}" }.joined(separator: ",") + "]}"
    #expect(hugeJSON.utf8.count > Flotillafile.Limits.default.maxFileBytes)
    #expect(
        Flotillafile.parseResult(hugeJSON)
            == .failure(.fileTooLarge(bytes: hugeJSON.utf8.count, limit: Flotillafile.Limits.default.maxFileBytes))
    )
}

@Test func tooManyMachinesIsRejected() {
    let limits = Flotillafile.Limits(maxMachines: 2)
    let json = """
    {"version": 1, "machines": [
        {"name": "m1", "image": "alpine:3.22"},
        {"name": "m2", "image": "alpine:3.22"},
        {"name": "m3", "image": "alpine:3.22"}
    ]}
    """
    #expect(
        Flotillafile.parseResult(json, limits: limits) == .failure(.tooManyEntries(context: "machines", limit: 2))
    )
}

@Test func tooManyContainersIsRejected() {
    let limits = Flotillafile.Limits(maxContainers: 1)
    let json = """
    {"version": 1, "containers": [
        {"name": "c1", "image": "alpine:3.22"},
        {"name": "c2", "image": "alpine:3.22"}
    ]}
    """
    #expect(
        Flotillafile.parseResult(json, limits: limits) == .failure(.tooManyEntries(context: "containers", limit: 1))
    )
}

@Test func tooManyPortsPerContainerIsRejected() {
    let limits = Flotillafile.Limits(maxPortsPerContainer: 1)
    let json = #"{"version": 1, "containers": [{"name": "c1", "image": "alpine:3.22", "ports": ["80:80", "81:81"]}]}"#
    #expect(
        Flotillafile.parseResult(json, limits: limits)
            == .failure(.tooManyEntries(context: "containers[0].ports", limit: 1))
    )
}

@Test func tooManyEnvPerContainerIsRejected() {
    let limits = Flotillafile.Limits(maxEnvPerContainer: 1)
    let json = #"{"version": 1, "containers": [{"name": "c1", "image": "alpine:3.22", "env": ["A=1", "B=2"]}]}"#
    #expect(
        Flotillafile.parseResult(json, limits: limits) == .failure(.tooManyEntries(context: "containers[0].env", limit: 1))
    )
}

@Test func tooManyVolumesPerContainerIsRejected() {
    let limits = Flotillafile.Limits(maxVolumesPerContainer: 1)
    let json = """
    {"version": 1, "containers": [{"name": "c1", "image": "alpine:3.22", \
    "volumes": ["a:/x", "b:/y"]}]}
    """
    #expect(
        Flotillafile.parseResult(json, limits: limits)
            == .failure(.tooManyEntries(context: "containers[0].volumes", limit: 1))
    )
}

// MARK: - Malformed input

@Test func malformedJSONIsRejected() {
    guard case .failure(.malformedJSON) = Flotillafile.parseResult("{not json at all") else {
        Issue.record("expected malformed JSON to be rejected")
        return
    }
}

@Test func topLevelArrayIsRejected() {
    guard case .failure = Flotillafile.parseResult("[]") else {
        Issue.record("expected a top-level JSON array to be rejected")
        return
    }
}

@Test func machinesEntryThatIsNotAnObjectIsRejected() {
    let json = #"{"version": 1, "machines": ["not-an-object"]}"#
    guard case .failure = Flotillafile.parseResult(json) else {
        Issue.record("expected a non-object machines entry to be rejected")
        return
    }
}

// MARK: - No file inclusion

@Test func volumeSourcesAreValidatedAsStringsOnlyNeverReadFromDisk() throws {
    // There is no include/URL mechanism in v1: an absolute-looking source is checked as
    // a string shape only. This does not (and must not) touch the filesystem — proven
    // here by pointing at a path that does not exist and still getting a clean parse.
    let json = """
    {"version": 1, "containers": [
        {"name": "c1", "image": "alpine:3.22", "volumes": ["/no/such/path/on/this/machine:/data:ro"]}
    ]}
    """
    let file = try Flotillafile.parse(json)
    #expect(file.containers[0].volumes == ["/no/such/path/on/this/machine:/data:ro"])
}
