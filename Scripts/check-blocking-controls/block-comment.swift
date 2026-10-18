// Negative control: a brace in a block comment ends nothing. check-blocking.sh must fail.
func control(cli: ContainerCLI, id: String) {
    Task.detached {
        /* } */
        _ = try? cli.stop(id)
    }
}
