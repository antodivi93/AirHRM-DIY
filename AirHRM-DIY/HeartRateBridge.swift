//
//  HeartRateBridge.swift
//  AirHRM-DIY
//
//  Coordinator del ponte HR. Compone i tre componenti specializzati e tiene
//  lo stato osservabile dalla UI:
//    - HealthKitHRSource:       legge l'HR (AirPods Pro 3 / Apple Watch via HK).
//    - HRPeripheralAdvertiser:  ri-emette i sample come Heart Rate BLE GATT.
//    - AudioRouteMonitor:       auto-start/stop quando rileva AirPods come uscita.
//
//  Inoltre gestisce il watchdog di "contact lost" (~5s senza sample) e la
//  persistenza della preferenza di auto-start.
//

import Foundation
import UIKit
import os

@MainActor
final class HeartRateBridge: ObservableObject {

    // MARK: - Stato osservabile dalla UI

    @Published private(set) var state: BridgeState = .idle
    @Published private(set) var currentBPM: Int = 0
    @Published private(set) var subscriberConnected: Bool = false
    @Published private(set) var currentSource: String? = nil
    @Published private(set) var contactLost: Bool = false

    /// Preferenza utente. Persistita in UserDefaults.
    @Published var autoStartEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoStartEnabled, forKey: Self.autoStartDefaultsKey)
            if autoStartEnabled { evaluateAutoStart() }
        }
    }

    var isBroadcasting: Bool { hkSource.isRunning }

    // MARK: - Costanti

    private static let autoStartDefaultsKey               = "autoStartEnabled"
    private static let contactLostThreshold: TimeInterval = 5.0
    private static let contactWatchdogInterval: TimeInterval = 1.0

    // MARK: - Componenti

    private let hkSource     = HealthKitHRSource()
    private let advertiser   = HRPeripheralAdvertiser()
    private let routeMonitor = AudioRouteMonitor()

    // MARK: - Stato interno

    private var isStarting: Bool = false
    private var lastSampleAt: Date?
    private var contactWatchdog: Timer?
    private var didBecomeActiveObserver: NSObjectProtocol?

    private let log = Logger(subsystem: "com.tuonome.airhrmdiy", category: "bridge")

    // MARK: - Init / deinit

    init() {
        let stored = UserDefaults.standard.object(forKey: Self.autoStartDefaultsKey) as? Bool
        self.autoStartEnabled = stored ?? true

        wireCallbacks()

        // Crea early il peripheral manager (per ricevere willRestoreState al
        // relancio in background) ma NON avvia advertising.
        advertiser.bootstrap()

        // Foreground hook: riasserta advertising se serve (es. dopo BT off→on).
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advertiser.reassertIfNeeded()
            }
        }

        // Valuta l'auto-start (gli AirPods potrebbero essere già attivi).
        evaluateAutoStart()
    }

    deinit {
        if let obs = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Lifecycle pubblico

    func start() {
        guard !isStarting, !hkSource.isRunning else { return }
        isStarting = true
        state = .starting
        hkSource.start { [weak self] ok in
            guard let self else { return }
            self.isStarting = false
            guard ok else { return } // onError ha già impostato state = .error(...)
            self.state = .waitingForSensor
            self.startContactWatchdog()
            self.advertiser.resumeAdvertising()
        }
    }

    func stop() {
        hkSource.stop()
        advertiser.stop()
        stopContactWatchdog()
        currentBPM = 0
        contactLost = false
        currentSource = nil
        lastSampleAt = nil
        subscriberConnected = false
        state = .idle
    }

    // MARK: - Wiring dei componenti

    private func wireCallbacks() {
        // BPM in arrivo dalla sorgente HealthKit.
        hkSource.onBPM = { [weak self] bpm in
            self?.handleNewBPM(bpm)
        }
        hkSource.onSourceLabel = { [weak self] label in
            self?.currentSource = label
        }
        hkSource.onError = { [weak self] msg in
            self?.state = .error(msg)
        }

        // Solo i casi BT "problema" e la recovery dal background.
        advertiser.onStateChange = { [weak self] s in
            self?.handleAdvertiserState(s)
        }
        advertiser.onSubscriberChange = { [weak self] connected in
            self?.subscriberConnected = connected
        }

        // Auto-start/stop basato su AirPods come uscita audio.
        routeMonitor.onChange = { [weak self] airpodsActive in
            self?.evaluateAutoStart(airpodsActive: airpodsActive)
        }
    }

    private func handleNewBPM(_ bpm: Int) {
        guard bpm > 0 else { return }
        lastSampleAt = Date()
        if contactLost { contactLost = false }
        currentBPM = bpm
        advertiser.broadcast(bpm: bpm)
        if !isInTerminalBluetoothState() {
            state = .broadcasting
        }
    }

    private func handleAdvertiserState(_ s: HRPeripheralAdvertiser.State) {
        switch s {
        case .bluetoothOff:         state = .bluetoothOff
        case .bluetoothDenied:      state = .bluetoothDenied
        case .bluetoothUnavailable: state = .bluetoothUnavailable
        case .bluetoothResetting:   state = .bluetoothResetting
        case .restoredFromBackground:
            // Il sistema ci ha rilanciato in background: prova a recuperare anche
            // l'eventuale sessione HK attiva, così riprendiamo a notificare.
            hkSource.recoverActiveSession { [weak self] in
                guard let self else { return }
                self.startContactWatchdog()
                self.state = .sessionRecovered
            }
        case .idle, .waitingForBluetooth, .advertising:
            // Lo stato UI in questi casi è guidato da hkSource/BPM/contactLost.
            break
        }
    }

    private func isInTerminalBluetoothState() -> Bool {
        switch state {
        case .bluetoothOff, .bluetoothDenied, .bluetoothUnavailable, .bluetoothResetting:
            return true
        default:
            return false
        }
    }

    // MARK: - Auto-start AirPods

    private func evaluateAutoStart(airpodsActive: Bool? = nil) {
        guard autoStartEnabled else { return }
        let active = airpodsActive ?? routeMonitor.isAirPodsActive
        if active {
            if !hkSource.isRunning && !isStarting { start() }
        } else {
            if hkSource.isRunning { stop() }
        }
    }

    // MARK: - Contact-lost watchdog

    private func startContactWatchdog() {
        stopContactWatchdog()
        lastSampleAt = nil
        contactLost = false
        contactWatchdog = Timer.scheduledTimer(withTimeInterval: Self.contactWatchdogInterval,
                                               repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkContactTimeout() }
        }
    }

    private func stopContactWatchdog() {
        contactWatchdog?.invalidate()
        contactWatchdog = nil
    }

    private func checkContactTimeout() {
        guard let last = lastSampleAt else { return }
        let elapsed = Date().timeIntervalSince(last)
        guard elapsed > Self.contactLostThreshold else { return }
        if !contactLost {
            contactLost = true
            state = .contactLost
            log.debug("contact-lost dopo \(elapsed, format: .fixed(precision: 1))s")
        }
    }

    #if DEBUG
    /// Solo per i `#Preview` di SwiftUI: forza lo stato pubblicato.
    /// Non chiamare in produzione.
    func _setPreviewState(state: BridgeState,
                          bpm: Int = 0,
                          source: String? = nil,
                          subscriberConnected: Bool = false,
                          contactLost: Bool = false) {
        self.state = state
        self.currentBPM = bpm
        self.currentSource = source
        self.subscriberConnected = subscriberConnected
        self.contactLost = contactLost
    }
    #endif
}
