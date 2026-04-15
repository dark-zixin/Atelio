import ArgumentParser

struct AtelioCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "atelio",
        abstract: "Atelio 終端管理 CLI",
        subcommands: [
            OpenCommand.self,
            DispatchCommand.self,
            StatusCommand.self,
            CloseCommand.self,
            ScreenCommand.self,
            WaitCommand.self,
            ListCommand.self,
            NotifyCommand.self,
        ]
    )
}

AtelioCLI.main()
