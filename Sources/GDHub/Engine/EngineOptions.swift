import Foundation

/// Command-line switches of the engine process (dev aids carry the semantics `DriverManager` had for the GUI).
struct EngineOptions: Equatable {
    var foreground = false                  // --engine-foreground: run without launchd (terminal tests)
    var latencyLog = false                  // --latency-log: meter lines every 2 s instead of every 10 s
    var publishPad: String?                 // --publish-pad <identity>: publish without persisting
    var testPattern = false                 // --test-pattern: loop the pattern once the pad is published
    var unpublishAfter: Double?             // --unpublish-after <s>
    var switchPadAfter: (seconds: Double, identity: String)?    // --switch-pad-after <s> <identity>
    var releasePad = false                  // --release-pad (with --engine-foreground): hello, setForwarding(INERT, RELEASE_PAD), exit

    init() {}

    init(arguments args: [String]) {
        foreground = args.contains("--engine-foreground")
        latencyLog = args.contains("--latency-log")
        testPattern = args.contains("--test-pattern")
        releasePad = args.contains("--release-pad")
        if let i = args.firstIndex(of: "--publish-pad"), i + 1 < args.count { publishPad = args[i + 1] }
        if let i = args.firstIndex(of: "--unpublish-after"), i + 1 < args.count, let s = Double(args[i + 1]) { unpublishAfter = s }
        if let i = args.firstIndex(of: "--switch-pad-after"), i + 2 < args.count, let s = Double(args[i + 1]) {
            switchPadAfter = (s, args[i + 2])
        }
    }

    static func == (l: EngineOptions, r: EngineOptions) -> Bool {
        l.foreground == r.foreground && l.latencyLog == r.latencyLog && l.publishPad == r.publishPad && l.releasePad == r.releasePad
            && l.testPattern == r.testPattern && l.unpublishAfter == r.unpublishAfter
            && l.switchPadAfter?.seconds == r.switchPadAfter?.seconds
            && l.switchPadAfter?.identity == r.switchPadAfter?.identity
    }
}
