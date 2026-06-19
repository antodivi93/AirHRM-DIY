//
//  HeartRateBridgeIntents.swift
//  AirHRM-DIY
//
//  App Intents for Start/Stop of the HR bridge.
//
//  These enable:
//   - Siri ("Start HR Bridge" / "Stop HR Bridge")
//   - Action Button on iPhone 15 Pro / Pro Max and newer
//   - Personal Automation in Shortcuts (e.g. "When a Workout starts on
//     Apple Watch -> run Start HR Bridge")
//   - Lock Screen / widget / Spotlight
//

import AppIntents
import Foundation

// MARK: - Start

struct StartHeartRateBridgeIntent: AppIntent {

    static var title: LocalizedStringResource = "Start HR Bridge"

    static var description = IntentDescription(
        "Starts broadcasting the AirPods heart rate as a BLE chest strap.",
        categoryName: "Workout"
    )

    // The app MUST be brought to foreground to keep the process alive: the
    // background modes (workout-processing + bluetooth-peripheral) only hold
    // the session while the app is running. If the intent ran out-of-process
    // the bridge would die as soon as perform() returns.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        HeartRateBridge.shared.start()
        return .result(dialog: "HR bridge started.")
    }
}

// MARK: - Stop

struct StopHeartRateBridgeIntent: AppIntent {

    static var title: LocalizedStringResource = "Stop HR Bridge"

    static var description = IntentDescription(
        "Stops broadcasting the heart rate.",
        categoryName: "Workout"
    )

    // Stop is fire-and-forget: no need to open the app.
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        HeartRateBridge.shared.stop()
        return .result(dialog: "HR bridge stopped.")
    }
}

// MARK: - Shortcuts

struct AirHRMShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartHeartRateBridgeIntent(),
            phrases: [
                "Start the HR bridge with \(.applicationName)",
                "Begin HR bridge with \(.applicationName)",
                "Turn on \(.applicationName)"
            ],
            shortTitle: "Start HR Bridge",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: StopHeartRateBridgeIntent(),
            phrases: [
                "Stop the HR bridge with \(.applicationName)",
                "Turn off \(.applicationName)"
            ],
            shortTitle: "Stop HR Bridge",
            systemImageName: "heart.slash"
        )
    }
}
