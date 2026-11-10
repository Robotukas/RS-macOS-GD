import Foundation

/// What a template needs from the mapping before Start is worth pressing. Pure: a template, the mapping in force and the
/// layout in, owner-readable words out. It reuses the comparison the runner skips steps with
/// (`DevResolvedStep.requirementMisses`), so the two can never disagree about what "unmet" means.
enum DevRequirementCheck {
    /// Every `requires.mapping` entry the mapping does not meet, across all steps, once each, in the owner's words
    /// ("G1 → Y", "G2 → Nothing", "G4 at its built-in function"), in step order and control order within a step.
    static func unmet(template: DevTemplate, mapping: ControlMapping, layout: ControlLayout) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for step in template.steps {
            for miss in DevResolvedStep.requirementMisses(step, mapping: mapping) {
                let item = describe(miss, layout: layout)
                if seen.insert(item).inserted { out.append(item) }
            }
        }
        return out
    }

    /// True when every step of the template would be skipped for an unmet mapping requirement, so a run would record
    /// nothing but skips. A template with a step that has no requirement, or a met one, is not blocked.
    static func everyStepUnmet(template: DevTemplate, mapping: ControlMapping) -> Bool {
        !template.steps.isEmpty && template.steps.allSatisfy { !DevResolvedStep.requirementMisses($0, mapping: mapping).isEmpty }
    }

    /// The Start block for a template whose every step would be skipped for the mapping; nil otherwise (some steps unmet
    /// still run, and the others are recorded as skipped with their reason).
    static func startBlock(template: DevTemplate, mapping: ControlMapping, layout: ControlLayout) -> String? {
        guard everyStepUnmet(template: template, mapping: mapping) else { return nil }
        let needs = unmet(template: template, mapping: mapping, layout: layout)
        guard !needs.isEmpty else { return nil }
        return "Needs \(needs.joined(separator: "; ")): set it in Mapping first (leave Developer mode, press Mapping, pick, Done)"
    }

    private static func describe(_ miss: DevResolvedStep.RequirementMiss, layout: ControlLayout) -> String {
        let who = DevResolvedStep.label(miss.control, layout)
        guard let output = miss.output else { return "\(who) → \"\(miss.value)\"" }
        if output == .builtIn { return "\(who) at its built-in function" }
        return "\(who) → \(DevResolvedStep.label(output, layout))"
    }
}
