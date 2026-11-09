import SwiftUI   // only so GDHubApp.main() resolves; nothing here runs SwiftUI in engine mode

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--engine") {
            EngineMain.run()            // -> Never; calls dispatchMain()
        }
        // T0 probe (deleted in T0.5): `--dev-probe-dext activate|deactivate` is a launch mode of its own, like --engine.
        switch ProbeExtensionRequester.parse(arguments: args) {
        case .notRequested: GDHubApp.main()
        case .run(let mode): ProbeExtensionRequester.run(mode)           // -> Never
        case .usage(let text): ProbeExtensionRequester.printUsageAndExit(text)
        }
    }
}
