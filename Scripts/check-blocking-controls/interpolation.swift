// Negative control: a blocking call inside a string interpolation. check-blocking.sh must fail.
func control(cli: ContainerCLI, id: String) {
    Task.detached {
        print("stopped: \(try cli.stop(id))")
    }
}
