// Negative control: `await` in front of a synchronous call still blocks. check-blocking.sh must fail.
func control(cli: ContainerCLI, id: String) {
    Task {
        _ = try? await cli.stop(id)
    }
}
