import Foundation

/// Per-event latency, controller to pad: for every edge the receiver showed, how long the virtual pad took to show it.
/// Pure, like the judge. The definitions follow `scuf-envision/tools/latency/padlat.swift` (kernel timestamps on both
/// sides) with the thresholds the plan fixes (docs/plans/developer-mode-plan.md, "Judging"):
///
/// **Receiver edges** are found in the receiver frames after they went through `PassthroughPadMapper` and the sink's
/// dead band (so they are what the pad is supposed to show, not raw controller bytes):
/// - digital: each press and each release of each watched pad item (a button, a D-pad direction, Guide);
/// - trigger: each pull (the value rises to `triggerEdge`, 0.5, or more) and the release that follows it (the value
///   falls to `triggerRelease`, 0.05, or less); a pull is armed again only after a release;
/// - stick: each *onset*: the stick leaves the dead zone (radius `deadZone`, 12 %) after it was inside. As in padlat a
///   stick counts as having come back only after `onsetRestMs` (60 ms) inside, so the wobble of a spring-back is one
///   event, not several. The first frame of a step counts as coming from rest.
///
/// **Match**: an edge is answered by the first pad report at or after its kernel timestamp that *changed* the pad's
/// state into the edge's state (item down / item up, trigger at or above 0.5 / at or below 0.05, stick outside the dead
/// zone after being inside) and arrived before the next receiver edge of the same kind. The difference of the two
/// kernel timestamps is that edge's latency. An edge with no such report is `unmatched`: the pad really did not follow.
enum DevLatency {
    struct Config: Equatable {
        var deadZone = 0.12
        var triggerEdge = 0.5
        var triggerRelease = 0.05
        var onsetRestMs = 60.0
    }

    /// What a step watches.
    struct Watch: Equatable {
        var items: Set<PadItem> = []
        var triggers: [PadTrigger] = []
        var stick: PadStick?
    }

    enum Kind: Hashable {
        case press(PadItem), release(PadItem)
        case pull(PadTrigger), letGo(PadTrigger)
        case onset(PadStick)
    }

    struct Edge: Equatable {
        var tNs: UInt64
        var kind: Kind
    }

    /// One state of the pad's held-state timeline: the state after the report at `tNs`, and whether that report changed it.
    struct PadSample {
        var tNs: UInt64
        var state: PadDecodedState
        var changed: Bool
    }

    struct Result: Equatable {
        /// One per answered edge, milliseconds, in edge order.
        var latenciesMs: [Double] = []
        var unmatched = 0
        var edges: Int { latenciesMs.count + unmatched }
    }

    // MARK: Receiver edges

    static func magnitude(_ x: Double, _ y: Double) -> Double { (x * x + y * y).squareRoot() }

    /// Indices of the samples where a stick leaves the dead zone after having been inside (see the type comment).
    /// `startArmed`: whether the stick counts as resting before the first sample.
    static func onsetIndices(times: [UInt64], magnitudes: [Double], deadZone: Double, restMs: Double, startArmed: Bool) -> [Int] {
        var out: [Int] = []
        var armed = startArmed
        var insideSince: UInt64? = startArmed ? times.first : nil
        let restNs = UInt64(restMs * 1e6)
        for i in times.indices {
            let t = times[i]
            if magnitudes[i] > deadZone {
                if !armed, let s = insideSince, t >= s, t - s >= restNs { armed = true }
                insideSince = nil
                if armed { out.append(i); armed = false }
            } else {
                if insideSince == nil { insideSince = t }
                if !armed, let s = insideSince, t >= s, t - s >= restNs { armed = true }
            }
        }
        return out
    }

    /// Every edge of the watched controls in the receiver frames, in time order.
    static func receiverEdges(frames: [DevJudge.Reference.Frame], watch: Watch, config c: Config) -> [Edge] {
        var edges: [Edge] = []
        if !watch.items.isEmpty {
            var prev: Set<PadItem> = []
            for f in frames {
                let cur = DevExpectation.pad(from: f.pad).intersection(watch.items)
                for item in cur.subtracting(prev).sorted() { edges.append(Edge(tNs: f.tNs, kind: .press(item))) }
                for item in prev.subtracting(cur).sorted() { edges.append(Edge(tNs: f.tNs, kind: .release(item))) }
                prev = cur
            }
        }
        for trig in watch.triggers {
            var pulled = false
            for f in frames {
                let v = trig == .left ? f.pad.lt : f.pad.rt
                if !pulled, v >= c.triggerEdge { pulled = true; edges.append(Edge(tNs: f.tNs, kind: .pull(trig))) }
                else if pulled, v <= c.triggerRelease { pulled = false; edges.append(Edge(tNs: f.tNs, kind: .letGo(trig))) }
            }
        }
        if let stick = watch.stick {
            let mags = frames.map { stick == .left ? magnitude($0.pad.lx, $0.pad.ly) : magnitude($0.pad.rx, $0.pad.ry) }
            for i in onsetIndices(times: frames.map(\.tNs), magnitudes: mags, deadZone: c.deadZone, restMs: c.onsetRestMs, startArmed: true) {
                edges.append(Edge(tNs: frames[i].tNs, kind: .onset(stick)))
            }
        }
        return edges.enumerated().sorted { ($0.element.tNs, $0.offset) < ($1.element.tNs, $1.offset) }.map(\.element)
    }

    // MARK: Matching

    /// Whether `s` shows the state the edge leads to.
    static func reflects(_ kind: Kind, _ s: PadDecodedState, _ c: Config) -> Bool {
        switch kind {
        case .press(let item): return s.items.contains(item)
        case .release(let item): return !s.items.contains(item)
        case .pull(let t): return s.value(of: t) >= c.triggerEdge
        case .letGo(let t): return s.value(of: t) <= c.triggerRelease
        case .onset(let st):
            let p = s.position(of: st)
            return magnitude(p.x, p.y) > c.deadZone
        }
    }

    static func measure(frames: [DevJudge.Reference.Frame], pad: [PadSample], watch: Watch, config c: Config = Config()) -> Result {
        let edges = receiverEdges(frames: frames, watch: watch, config: c)
        var byKind: [Kind: [Int]] = [:]
        for (i, e) in edges.enumerated() { byKind[e.kind, default: []].append(i) }
        var result = Result()
        for (i, e) in edges.enumerated() {
            let sameKind = byKind[e.kind] ?? []
            let next = sameKind.first { $0 > i }.map { edges[$0].tNs }
            var answer: UInt64?
            for j in pad.indices where j >= 1 && pad[j].tNs >= e.tNs {
                if let next, pad[j].tNs >= next { break }
                if pad[j].changed, reflects(e.kind, pad[j].state, c), !reflects(e.kind, pad[j - 1].state, c) {
                    answer = pad[j].tNs
                    break
                }
            }
            if let answer { result.latenciesMs.append(Double(answer - e.tNs) / 1e6) } else { result.unmatched += 1 }
        }
        return result
    }

    // MARK: Numbers

    /// padlat's percentile: nearest rank on the sorted list, `index = Int((n - 1) * p + 0.5)`.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))]
    }

    /// `lat.n`, `lat.unmatched` always; the percentiles and the maximum when at least one edge was answered.
    static func values(_ r: Result) -> [String: Double] {
        var v: [String: Double] = ["lat.n": Double(r.latenciesMs.count), "lat.unmatched": Double(r.unmatched)]
        if !r.latenciesMs.isEmpty {
            let s = r.latenciesMs.sorted()
            v["lat.p50Ms"] = percentile(s, 0.50)
            v["lat.p95Ms"] = percentile(s, 0.95)
            v["lat.p99Ms"] = percentile(s, 0.99)
            v["lat.maxMs"] = s[s.count - 1]
        }
        return v
    }

    /// "latency p50 0.12 ms (n=20, p99 0.31, max 0.40)"; unanswered edges are named in the brackets.
    static func text(_ r: Result) -> String {
        if r.edges == 0 { return "latency: no receiver edge to measure." }
        if r.latenciesMs.isEmpty { return "latency: none of \(r.edges) receiver edges was answered by the pad." }
        let s = r.latenciesMs.sorted()
        func f(_ v: Double) -> String { String(format: "%.2f", v) }
        var inner = "n=\(s.count), p99 \(f(percentile(s, 0.99))), max \(f(s[s.count - 1]))"
        if r.unmatched > 0 { inner += ", \(r.unmatched) unanswered" }
        return "latency p50 \(f(percentile(s, 0.50))) ms (\(inner))."
    }
}
