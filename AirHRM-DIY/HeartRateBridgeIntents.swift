//
//  HeartRateBridgeIntents.swift
//  AirHRM-DIY
//
//  App Intents per Start/Stop del ponte HR.
//
//  Sbloccano:
//   - Siri ("Avvia ponte HR" / "Ferma ponte HR")
//   - Action Button su iPhone 15 Pro / Pro Max e successivi
//   - Personal Automation in Shortcuts (es. "Quando inizia un Allenamento
//     su Apple Watch -> esegui Avvia ponte HR")
//   - Lock Screen / widget / Spotlight
//

import AppIntents
import Foundation

// MARK: - Start

struct StartHeartRateBridgeIntent: AppIntent {

    static var title: LocalizedStringResource = "Avvia ponte HR"

    static var description = IntentDescription(
        "Avvia la trasmissione della frequenza cardiaca degli AirPods come fascia BLE.",
        categoryName: "Allenamento"
    )

    // L'app DEVE essere portata in foreground per mantenere vivo il processo:
    // i background modes (workout-processing + bluetooth-peripheral) reggono
    // la sessione solo se l'app e' viva. Se l'intent gira fuori-processo, il
    // ponte morirebbe appena perform() ritorna.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        HeartRateBridge.shared.start()
        return .result(dialog: "Ponte HR avviato.")
    }
}

// MARK: - Stop

struct StopHeartRateBridgeIntent: AppIntent {

    static var title: LocalizedStringResource = "Ferma ponte HR"

    static var description = IntentDescription(
        "Interrompe la trasmissione della frequenza cardiaca.",
        categoryName: "Allenamento"
    )

    // Stop e' fire-and-forget: non serve aprire l'app.
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        HeartRateBridge.shared.stop()
        return .result(dialog: "Ponte HR fermato.")
    }
}

// MARK: - Shortcuts

struct AirHRMShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartHeartRateBridgeIntent(),
            phrases: [
                "Avvia il ponte HR con \(.applicationName)",
                "Inizia ponte HR con \(.applicationName)",
                "Accendi \(.applicationName)"
            ],
            shortTitle: "Avvia ponte HR",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: StopHeartRateBridgeIntent(),
            phrases: [
                "Ferma il ponte HR con \(.applicationName)",
                "Spegni \(.applicationName)"
            ],
            shortTitle: "Ferma ponte HR",
            systemImageName: "heart.slash"
        )
    }
}
