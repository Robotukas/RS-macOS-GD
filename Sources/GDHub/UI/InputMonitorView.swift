import SwiftUI

struct InputMonitorView: View {
    @ObservedObject var device: EnvisionProDevice

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private var rawLine: String {
        let f = device.frame
        return "x \(f.x) y \(f.y) z \(f.z) rz \(f.rz) lt \(f.lt) rt \(f.rt) hat \(f.hat) "
            + "btn \(String(f.buttons, radix: 2).leftPadded(to: 19)) "
            + "extra \(String(f.extra, radix: 2).leftPadded(to: 13))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Input monitor").font(.headline)
                Spacer()
                Button("Clear") { device.clearLog() }
            }
            Text(rawLine)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            List(device.eventLog) { e in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Self.timeFormatter.string(from: e.time))
                        .foregroundStyle(.secondary)
                    Text(e.text)
                }
                .font(.system(.caption, design: .monospaced))
            }
            .listStyle(.plain)
        }
        .padding(10)
    }
}
