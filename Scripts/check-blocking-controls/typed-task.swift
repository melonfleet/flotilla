// Negative control: an explicitly typed `Task`. check-blocking.sh must fail.
func control(cli: ContainerCLI, id: String) {
    let task = Task<Void, Never> {
        _ = try? cli.stop(id)
    }
    _ = task
}
