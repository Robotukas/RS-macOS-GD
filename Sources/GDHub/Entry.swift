import SwiftUI   // only so GDHubApp.main() resolves; nothing here runs SwiftUI in engine mode

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--engine") {
            EngineMain.run()            // -> Never; calls dispatchMain()
        } else {
            GDHubApp.main()
        }
    }
}
