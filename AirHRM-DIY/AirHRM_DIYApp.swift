//
//  AirHRM_DIYApp.swift
//  AirHRM-DIY
//
//  App minimale: un pulsante per avviare/fermare il ponte e una vista dello stato.
//

import SwiftUI

@main
struct AirHRM_DIYApp: App {
    @StateObject private var bridge = HeartRateBridge()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bridge)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var bridge: HeartRateBridge

    var body: some View {
        VStack(spacing: 28) {
            Text("AirHRM-DIY")
                .font(.largeTitle.bold())

            VStack(spacing: 6) {
                Text(bridge.currentBPM > 0 ? "\(bridge.currentBPM)" : "—")
                    .font(.system(size: 92, weight: .bold, design: .rounded))
                    .foregroundStyle(bridge.contactLost ? Color.secondary : Color.red)
                Text("BPM")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            if bridge.contactLost {
                Label("Contatto perso", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline.weight(.semibold))
            }

            if let source = bridge.currentSource {
                Text("Sorgente: \(source)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Label(bridge.subscriberConnected ? "Garmin collegato" : "Nessun ricevitore",
                  systemImage: bridge.subscriberConnected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(bridge.subscriberConnected ? .green : .secondary)

            Text(bridge.state.displayText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Toggle(isOn: $bridge.autoStartEnabled) {
                Label("Avvio automatico con AirPods", systemImage: "airpods.pro")
                    .font(.subheadline)
            }
            .padding(.horizontal)

            Button {
                bridge.isBroadcasting ? bridge.stop() : bridge.start()
            } label: {
                Text(bridge.isBroadcasting ? "Ferma" : "Avvia ponte HR")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(bridge.isBroadcasting ? .gray : .red)
            .padding(.horizontal)
        }
        .padding()
    }
}

#if DEBUG
#Preview("Idle") {
    let bridge = HeartRateBridge()
    bridge._setPreviewState(state: .idle)
    return ContentView().environmentObject(bridge)
}

#Preview("Waiting for sensor") {
    let bridge = HeartRateBridge()
    bridge._setPreviewState(state: .waitingForSensor, subscriberConnected: true)
    return ContentView().environmentObject(bridge)
}

#Preview("Broadcasting") {
    let bridge = HeartRateBridge()
    bridge._setPreviewState(state: .broadcasting,
                            bpm: 142,
                            source: "AirPods",
                            subscriberConnected: true)
    return ContentView().environmentObject(bridge)
}

#Preview("Contact lost") {
    let bridge = HeartRateBridge()
    bridge._setPreviewState(state: .contactLost,
                            bpm: 142,
                            source: "AirPods",
                            subscriberConnected: true,
                            contactLost: true)
    return ContentView().environmentObject(bridge)
}

#Preview("Bluetooth off") {
    let bridge = HeartRateBridge()
    bridge._setPreviewState(state: .bluetoothOff)
    return ContentView().environmentObject(bridge)
}
#endif
