import Foundation

/// Entry of the headless engine (`GDHub --engine`). Never creates an application object.
enum EngineMain {
    static let label = "com.interlinked.gdhub.engine"
    private static var service: EngineService?          // strong reference for the process lifetime

    /// True when launchd started this process as the engine job. launchd sets XPC_SERVICE_NAME to the job label; a
    /// LaunchServices launch (`open GDHub.app --args --engine`) has `application.…` there, and getppid() == 1 would
    /// not tell the two apart.
    static func startedByLaunchd(environment: [String: String]) -> Bool {
        environment["XPC_SERVICE_NAME"] == label
    }

    static func run() -> Never {
        let args = CommandLine.arguments
        let options = EngineOptions(arguments: args)
        guard startedByLaunchd(environment: ProcessInfo.processInfo.environment) || options.foreground else {
            FileHandle.standardError.write(Data("GDHub --engine must be started by launchd (or pass --engine-foreground)\n".utf8))
            EngineService.log.error("refused to run: not started by launchd (XPC_SERVICE_NAME=\(ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? "-", privacy: .public))")
            exit(64)
        }
        if options.releasePad {
            // Only with --engine-foreground (checked above): remove a pinned pad that nobody owns, then exit. Never started by launchd.
            exit(ReleasePadTool.run())
        }
        let s = EngineService(options: options)
        service = s
        s.start()
        dispatchMain()
    }
}
