import Foundation

@main struct PreparationChecks {
    static func main() {
        precondition(AssistiveTouchObservedState.enabled.allowsStartup)
        precondition(AssistiveTouchObservedState.unknown.allowsStartup)
        precondition(!AssistiveTouchObservedState.disabled.allowsStartup)
        var checks = 3
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label)
            checks += 1
        }
        func snapshot(model: Bool = true, consent: Bool = true,
                      toolsOnly: Bool = false, tools: Bool = true,
                      preview: Bool = false, assistiveTouch: Bool = true,
                      device: Bool = true, calibration: Bool = true,
                      screen: Bool = true) -> AutomaticPreparationSnapshot {
            AutomaticPreparationSnapshot(modelReady: model, consentReady: consent,
                toolsOnly: toolsOnly, systemToolsEnabled: tools, previewOnly: preview,
                assistiveTouchReady: assistiveTouch, deviceReady: device,
                calibrationReady: calibration, fullScreenReady: screen)
        }

        func savedConfiguration(model: Bool = true, consent: Bool = true,
                                toolsOnly: Bool = false, tools: Bool = true,
                                preview: Bool = false, accessory: Bool = true,
                                calibration: Bool = true) -> SavedPreparationConfiguration {
            SavedPreparationConfiguration(modelReady: model, consentReady: consent,
                toolsOnly: toolsOnly, systemToolsEnabled: tools, previewOnly: preview,
                accessoryConfigured: accessory, calibrationConfigured: calibration)
        }

        // Home configuration status describes reusable saved setup. Removing
        // credentials, changing recipients, or changing modes must expose the
        // newly missing requirement without granting runtime readiness.
        let savedScenarios: [(String, SavedPreparationConfiguration, AutomaticPreparationStep)] = [
            ("fresh configuration starts with model", savedConfiguration(model: false,
                consent: false, tools: false, accessory: false, calibration: false), .model),
            ("deleted API key exposes model setup", savedConfiguration(model: false), .model),
            ("recipient credential mismatch exposes model setup", savedConfiguration(model: false,
                consent: false), .model),
            ("new recipient requires its own consent", savedConfiguration(consent: false), .consent),
            ("revoked recipient consent exposes authorization", savedConfiguration(consent: false,
                toolsOnly: true), .consent),
            ("control setup needs a saved accessory", savedConfiguration(accessory: false,
                calibration: false), .device),
            ("retained calibration cannot replace a removed accessory", savedConfiguration(accessory: false), .device),
            ("saved accessory needs usable calibration", savedConfiguration(calibration: false), .calibration),
            ("changed accessory invalidates previous calibration", savedConfiguration(calibration: false), .calibration),
            ("invalid saved calibration needs configuration", savedConfiguration(calibration: false), .calibration),
            ("saved control setup is configured", savedConfiguration(), .ready),
            ("visual control does not require system tools", savedConfiguration(tools: false), .ready),
            ("tools mode only needs its saved capability", savedConfiguration(toolsOnly: true,
                accessory: false, calibration: false), .ready),
            ("disabling tools exposes configuration in tools mode", savedConfiguration(toolsOnly: true,
                tools: false), .systemTools),
            ("preview saved setup does not need control hardware", savedConfiguration(preview: true,
                accessory: false, calibration: false), .ready),
            ("preview still needs model credentials", savedConfiguration(model: false, preview: true), .model),
            ("preview still needs recipient consent", savedConfiguration(consent: false, preview: true), .consent),
            ("switching from preview to control exposes accessory setup", savedConfiguration(preview: false,
                accessory: false, calibration: false), .device),
            ("switching from tools to control exposes calibration", savedConfiguration(toolsOnly: false,
                calibration: false), .calibration),
            ("tools mode takes precedence over preview configuration", savedConfiguration(toolsOnly: true,
                tools: false, preview: true), .systemTools)
        ]
        for (label, state, expected) in savedScenarios {
            check(state.configurationStep == expected, label)
            check(state.configured == (expected == .ready), label + " controls the home card")
        }

        let savedControl = savedConfiguration()
        let runtimeLosses: [(String, AutomaticPreparationSnapshot, AutomaticPreparationStep)] = [
            ("screen sharing stopped", snapshot(screen: false), .screen),
            ("accessory disconnected", snapshot(device: false), .device),
            ("AssistiveTouch unverified after relaunch", snapshot(assistiveTouch: false), .assistiveTouch),
            ("current screen no longer matches saved calibration", snapshot(calibration: false), .calibration)
        ]
        for (label, observed, expected) in runtimeLosses {
            check(savedControl.configured, label + " leaves saved configuration complete")
            check(observed.nextStep == expected, label + " still blocks execution")
        }
        check(savedConfiguration(preview: true, accessory: false, calibration: false).configured &&
              snapshot(preview: true, assistiveTouch: false, device: false, calibration: false, screen: false).nextStep == .screen,
              "configured preview does not manufacture live screen sharing")

        // Concrete setup and recovery scenarios. Saved settings cannot replace
        // observations of permission, connection, calibration, or live pixels.
        let scenarios: [(String, AutomaticPreparationSnapshot, AutomaticPreparationStep)] = [
            ("new installation begins with model", snapshot(model: false, consent: false,
                tools: false, assistiveTouch: false, device: false,
                calibration: false, screen: false), .model),
            ("model repair precedes all existing setup", snapshot(model: false), .model),
            ("model complete exposes consent", snapshot(consent: false, tools: false,
                assistiveTouch: false, device: false, calibration: false, screen: false), .consent),
            ("tools mode requires consent", snapshot(consent: false, toolsOnly: true), .consent),
            ("tools mode enables its own capability", snapshot(toolsOnly: true, tools: false,
                assistiveTouch: false, device: false, calibration: false, screen: false), .systemTools),
            ("tools mode works without screen or hardware", snapshot(toolsOnly: true,
                assistiveTouch: false, device: false, calibration: false, screen: false), .ready),
            ("visual mode does not require system tools", snapshot(tools: false), .ready),
            ("control first needs AssistiveTouch", snapshot(assistiveTouch: false,
                device: false, calibration: false, screen: false), .assistiveTouch),
            ("unverified AssistiveTouch cannot certify an otherwise ready setup",
                snapshot(assistiveTouch: false), .assistiveTouch),
            ("device precedes calibration", snapshot(device: false,
                calibration: false, screen: false), .device),
            ("old calibration cannot certify a disconnected device",
                snapshot(device: false), .device),
            ("connected device still needs calibration", snapshot(calibration: false,
                screen: false), .calibration),
            ("an active screen cannot certify calibration", snapshot(calibration: false), .calibration),
            ("saved setup needs a live screen", snapshot(screen: false), .screen),
            ("all observed requirements ready", snapshot(), .ready),
            ("preview skips control setup but needs screen", snapshot(preview: true,
                assistiveTouch: false, device: false, calibration: false, screen: false), .screen),
            ("preview works without control setup", snapshot(preview: true,
                assistiveTouch: false, device: false, calibration: false), .ready),
            ("preview still requires model", snapshot(model: false, preview: true), .model),
            ("preview still requires consent", snapshot(consent: false, preview: true), .consent),
            ("tools mode takes precedence over preview", snapshot(toolsOnly: true,
                tools: false, preview: true), .systemTools)
        ]
        for (label, state, expected) in scenarios {
            check(state.nextStep == expected, label)
        }

        // Repeated preparation reuses valid observed setup. It must not send a
        // configured user back through permissions, pairing, or calibration.
        let configured = snapshot()
        for _ in 0..<3 {
            check(configured.nextStep == .ready, "configured setup is reusable")
        }
        check(!snapshot(screen: false).fullScreenReady,
              "inspecting preparation never manufactures screen availability")
        check(snapshot(screen: false).nextStep == .screen,
              "screen stop is detected even after earlier preparation")
        check(snapshot(device: false).nextStep == .device,
              "device loss is detected even with calibration retained")
        check(snapshot(calibration: false).nextStep == .calibration,
              "invalid calibration is detected even with connection retained")

        // Across every irrelevant hardware/screen state, tools mode stays usable
        // and preview requires only its visual source after model and consent.
        for mask in 0..<16 {
            let assistiveTouch = mask & 1 != 0
            let device = mask & 2 != 0
            let calibration = mask & 4 != 0
            let screen = mask & 8 != 0
            check(snapshot(toolsOnly: true, assistiveTouch: assistiveTouch,
                device: device, calibration: calibration, screen: screen).nextStep == .ready,
                "tools mode ignores control and screen state \(mask)")
            check(snapshot(preview: true, assistiveTouch: assistiveTouch,
                device: device, calibration: calibration, screen: screen).nextStep == (screen ? .ready : .screen),
                "preview ignores control state \(mask)")
        }

        // SDK false is unknown without Guided Access; an authoritative off
        // observation must never be overridden by the manual confirmation.
        check(AssistiveTouchObservedState.observed(reportedRunning: true, guidedAccessEnabled: false) == .enabled,
              "a positive system observation is sufficient without a manual claim")
        check(AssistiveTouchObservedState.observed(reportedRunning: false, guidedAccessEnabled: false) == .unknown,
              "the restricted negative query is unknown, not an off assertion")
        check(AssistiveTouchObservedState.observed(reportedRunning: false, guidedAccessEnabled: true) == .disabled,
              "Guided Access makes a negative observation authoritative")
        check(AssistiveTouchObservedState.observed(reportedRunning: true, guidedAccessEnabled: true) == .enabled,
              "an authoritative positive system observation remains enabled")

        let authorization = UUID(), connection = UUID(), capture = UUID()
        let beginning = AssistiveTouchVerificationContext(preparationID: authorization, accessoryID: nil,
            connectionID: nil, calibrationFingerprint: nil, captureID: nil, captureRunning: false)
        var policy = AssistiveTouchSessionVerification()
        check(!policy.isReady(observation: .unknown, context: beginning), "no user action means no unknown-state authorization")
        check(!policy.confirm(observation: .disabled, context: beginning), "a user cannot override a definite off observation")
        var unauthorized = beginning; unauthorized.preparationID = nil
        check(!policy.confirm(observation: .unknown, context: unauthorized), "manual confirmation needs a live preparation authorization")
        check(policy.confirm(observation: .unknown, context: beginning), "explicit native confirmation starts only the current preparation")
        check(policy.isReady(observation: .unknown, context: beginning), "an initial preparation may acquire its missing actual observations")
        check(snapshot(assistiveTouch: policy.isReady(observation: .unknown, context: beginning), device: false,
                       calibration: false, screen: false).nextStep == .device, "manual confirmation does not certify a disconnected accessory")

        var connected = beginning; connected.accessoryID = "actual-accessory"; connected.connectionID = connection
        check(policy.isReady(observation: .unknown, context: connected), "the authorized preparation binds the actual newly ready connection")
        check(snapshot(assistiveTouch: policy.isReady(observation: .unknown, context: connected), calibration: false,
                       screen: false).nextStep == .calibration, "a connected accessory still requires real calibration")
        var calibrated = connected; calibrated.calibrationFingerprint = Data("actual-calibration-v1".utf8)
        check(policy.isReady(observation: .unknown, context: calibrated), "the same preparation may bind its actual calibration")
        check(snapshot(assistiveTouch: policy.isReady(observation: .unknown, context: calibrated), screen: false).nextStep == .screen,
              "calibration does not manufacture a screen or bypass the system sharing step")
        var complete = calibrated; complete.captureID = capture; complete.captureRunning = true
        check(policy.isReady(observation: .unknown, context: complete), "the current preparation binds its first actual full-screen stream")
        var continuation = complete; continuation.preparationID = nil
        check(policy.isReady(observation: .unknown, context: continuation), "only fully bound observations remain valid after preparation finishes")
        check(snapshot(assistiveTouch: policy.isReady(observation: .unknown, context: continuation)).nextStep == .ready,
              "all independent observed requirements must be ready before control starts")
        check(policy.isReady(observation: .unknown, context: continuation), "ordinary app switching and same-session pause/continue retain the exact bindings")
        var waitingForPixels = continuation; waitingForPixels.captureID = nil
        check(!policy.isReady(observation: .unknown, context: waitingForPixels), "a temporarily missing frame is not affirmative current-stream evidence")
        check(policy.isReady(observation: .unknown, context: continuation), "an independently observed same running stream can recover after a temporary missing frame")

        let mutations: [(String, (inout AssistiveTouchVerificationContext) -> Void)] = [
            ("selected accessory replacement", { $0.accessoryID = "other-accessory" }),
            ("selected accessory disappearance", { $0.accessoryID = nil }),
            ("connection replacement", { $0.connectionID = UUID() }),
            ("connection loss", { $0.connectionID = nil }),
            ("calibration replacement", { $0.calibrationFingerprint = Data("another-calibration".utf8) }),
            ("calibration invalidation", { $0.calibrationFingerprint = nil }),
            ("capture replacement", { $0.captureID = UUID() }),
            ("capture stopped", { $0.captureRunning = false; $0.captureID = nil })
        ]
        for (label, mutate) in mutations {
            var bound = AssistiveTouchSessionVerification()
            check(bound.confirm(observation: .unknown, context: complete), "prepare exact context before " + label)
            var changed = continuation; mutate(&changed)
            check(!bound.isReady(observation: .unknown, context: changed), label + " invalidates the current-session user evidence")
            check(!bound.isReady(observation: .unknown, context: continuation), label + " cannot restore old authority merely by returning old objects")
        }
        var pending = AssistiveTouchSessionVerification()
        _ = pending.confirm(observation: .unknown, context: beginning)
        var differentPreparation = beginning; differentPreparation.preparationID = UUID()
        check(!pending.isReady(observation: .unknown, context: differentPreparation), "incomplete evidence cannot migrate to a new preparation")
        _ = pending.confirm(observation: .unknown, context: beginning)
        check(!pending.isReady(observation: .unknown, context: unauthorized), "incomplete evidence cannot survive preparation completion")
        var relaunched = AssistiveTouchSessionVerification()
        check(!relaunched.isReady(observation: .unknown, context: continuation), "a fresh process has no restored user confirmation")
        policy.invalidate()
        check(!policy.isReady(observation: .unknown, context: continuation), "explicit stop/cancel/state-change invalidation removes all authority")
        _ = policy.confirm(observation: .unknown, context: complete)
        check(!policy.isReady(observation: .disabled, context: continuation), "a definite off observation revokes existing user confirmation")
        check(!policy.isReady(observation: .unknown, context: continuation), "a later unknown observation cannot resurrect a definite-off revocation")
        _ = policy.confirm(observation: .unknown, context: complete)
        check(!policy.confirm(observation: .disabled, context: complete) && !policy.isReady(observation: .unknown, context: continuation),
              "even a direct invalid confirmation attempt clears old authority")
        check(policy.isReady(observation: .enabled, context: unauthorized), "system-positive state does not require a manual confirmation")
        check(!policy.isReady(observation: .unknown, context: continuation), "a positive system reading is not persisted as a later manual claim")
        var malformed = complete; malformed.calibrationFingerprint = Data()
        check(!policy.confirm(observation: .unknown, context: malformed), "empty calibration identity cannot certify current-session evidence")
        print("PASS: \(checks) automatic preparation policy checks (offline)")
    }
}
