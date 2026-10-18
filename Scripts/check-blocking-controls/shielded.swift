// Positive control: every form above, under `Blocking.run`. check-blocking.sh must pass this one.
func control(cli: ContainerCLI, id: String) {
    Task<Void, Never> {
        /* } */
        _ = try? await Blocking.run { try cli.stop(id) }
        _ = await Blocking.run { "stopped: \(String(describing: try? cli.stop(id)))" }
        print("Task { cli.stop(id) } is only words")
    }
}
