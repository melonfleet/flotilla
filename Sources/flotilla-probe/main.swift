import Foundation
import FlotillaCore

// Phase 1 helper. Run on a Mac with `container` installed and the service started
// (`container system start`):  swift run flotilla-probe
//
// Dumps real `--format json` output and runs the typed decoders so you can confirm
// FlotillaCore's models still match the installed CLI version.

let cli = ContainerCLI(host: LocalHost(), wirePolicy: .localOwner)

func dumpRaw(_ title: String, _ args: [String]) {
    print("=== \(title) ===")
    do {
        let result = try cli.host.run(args)
        if !result.ok {
            print("(exit \(result.exitCode)) \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        print(out.isEmpty ? "(no stdout)" : out)
    } catch {
        print("ERROR launching container: \(error)")
        print("Is `container` installed/on PATH and started? (container system start)")
    }
    print("")
}

dumpRaw("system status", ["system", "status", "--format", "json"])
dumpRaw("containers (ls --all)", ["ls", "--all", "--format", "json"])
dumpRaw("images (image list)", ["image", "list", "--format", "json"])

print("=== typed decode ===")
do {
    let status = try cli.systemStatus()
    print("service: \(status.status)")
    let containers = try cli.listContainers()
    print("containers: \(containers.count)")
    for c in containers { print("  - \(c.name)  [\(c.status.state)]  \(c.imageReference)") }
    let images = try cli.listImages()
    print("images: \(images.count)")
    for i in images { print("  - \(i.reference)  \(i.displaySize.map { "\($0) B" } ?? "?")") }
} catch {
    print("decode failed — models may need updating for this CLI version:")
    print("  \(error)")
}
