//
//  AudioRouteMonitor.swift
//  AirHRM-DIY
//
//  Osserva l'audio route per rilevare gli AirPods come uscita attiva e notifica
//  il coordinator. Riapre la valutazione anche al ritorno in foreground.
//

import Foundation
import AVFoundation
import UIKit

@MainActor
final class AudioRouteMonitor {

    private(set) var isAirPodsActive: Bool = false

    /// Callback invocato su MainActor a ogni cambio di stato (true = AirPods come uscita).
    var onChange: ((Bool) -> Void)?

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(routeChanged(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appBecameActive(_:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        // Valutazione iniziale (gli AirPods potrebbero essere già attivi).
        isAirPodsActive = Self.isAirPodsCurrentOutput()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Forza una rivalutazione del route (es. dopo un eventuale BLE restart).
    func reevaluate() { evaluate() }

    @objc nonisolated private func routeChanged(_ notification: Notification) {
        Task { @MainActor in self.evaluate() }
    }

    @objc nonisolated private func appBecameActive(_ notification: Notification) {
        Task { @MainActor in self.evaluate() }
    }

    private func evaluate() {
        let active = Self.isAirPodsCurrentOutput()
        guard active != isAirPodsActive else { return }
        isAirPodsActive = active
        onChange?(active)
    }

    private static func isAirPodsCurrentOutput() -> Bool {
        let route = AVAudioSession.sharedInstance().currentRoute
        for output in route.outputs {
            let isBluetooth =
                output.portType == .bluetoothA2DP ||
                output.portType == .bluetoothHFP ||
                output.portType == .bluetoothLE
            if isBluetooth && output.portName.range(of: "airpods", options: .caseInsensitive) != nil {
                return true
            }
        }
        return false
    }
}
