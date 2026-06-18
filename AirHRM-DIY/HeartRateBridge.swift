//
//  HeartRateBridge.swift
//  AirHRM-DIY
//
//  Legge l'HR degli AirPods Pro 3 tramite una sessione di allenamento iOS (HealthKit)
//  e lo ri-emette come sensore cardiaco BLE standard (GATT Heart Rate Service 0x180D),
//  così un Garmin / Wahoo / Peloton lo vede come una fascia toracica.
//
//  Requisiti runtime: AirPods Pro 3 + iPhone con iOS 26+.
//  Capability necessarie (disponibili anche con free provisioning):
//    - HealthKit
//    - Background Modes: "Workout processing" + "Acts as a Bluetooth LE accessory"
//

import Foundation
import HealthKit
import CoreBluetooth
import AVFoundation
import UIKit
import os

@MainActor
final class HeartRateBridge: NSObject, ObservableObject {

    // Stato osservabile dalla UI
    @Published var currentBPM: Int = 0
    @Published var isBroadcasting: Bool = false
    @Published var subscriberConnected: Bool = false
    @Published var statusText: String = "Pronto"
    @Published var contactLost: Bool = false
    @Published var currentSource: String? = nil

    // Auto-start quando vengono rilevati gli AirPods come uscita audio.
    @Published var autoStartEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoStartEnabled, forKey: Self.autoStartDefaultsKey)
            if autoStartEnabled { evaluateAutoStart() }
        }
    }

    private static let autoStartDefaultsKey = "autoStartEnabled"
    // Se non arriva un sample HR valido entro questa soglia, dichiariamo "contatto perso"
    // e SMETTIAMO di notificare il valore al central (Garmin) per ottenere un dropout reale.
    private static let contactLostThreshold: TimeInterval = 5.0
    private static let contactWatchdogInterval: TimeInterval = 1.0

    private var isStarting = false
    private var lastSampleAt: Date?
    private var contactWatchdog: Timer?
    private var anchoredHRQuery: HKAnchoredObjectQuery?
    // Ultimo pacchetto HR pubblicato e flag di ritrasmissione pendente: quando la
    // transmit queue di Core Bluetooth è piena, updateValue ritorna false e dobbiamo
    // attendere peripheralManagerIsReady(toUpdateSubscribers:) per riprovare.
    private var lastPacket: Data?
    private var hasPendingResend: Bool = false

    private let log = Logger(subsystem: "com.tuonome.airhrmdiy", category: "bridge")

    override init() {
        let stored = UserDefaults.standard.object(forKey: Self.autoStartDefaultsKey) as? Bool
        self.autoStartEnabled = stored ?? true
        super.init()
        setupAudioRouteMonitor()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - HealthKit
    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private let bpmUnit = HKUnit.count().unitDivided(by: .minute())

    // MARK: - CoreBluetooth (ruolo peripheral)
    private var peripheralManager: CBPeripheralManager?
    private var hrCharacteristic: CBMutableCharacteristic?

    private let hrServiceUUID  = CBUUID(string: "180D") // Heart Rate Service
    private let hrMeasUUID     = CBUUID(string: "2A37") // Heart Rate Measurement
    private let bodyLocUUID    = CBUUID(string: "2A38") // Body Sensor Location
    private let localName      = "AirHRM-DIY"           // nome che vedrai sul Garmin

    // MARK: - Avvio / Stop

    func start() {
        guard !isStarting, session == nil else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            statusText = "HealthKit non disponibile su questo dispositivo"
            return
        }
        isStarting = true
        requestAuthorization { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.isStarting = false
                self.statusText = "Autorizzazione HealthKit negata"
                return
            }
            self.setupPeripheral()
            self.startWorkoutSession()
            self.isStarting = false
        }
    }

    func stop() {
        session?.end()
        builder?.endCollection(withEnd: Date()) { _, _ in }
        peripheralManager?.stopAdvertising()
        if let mgr = peripheralManager { mgr.removeAllServices() }
        contactWatchdog?.invalidate()
        contactWatchdog = nil
        if let q = anchoredHRQuery { healthStore.stop(q) }
        anchoredHRQuery = nil
        session = nil
        builder = nil
        isBroadcasting = false
        subscriberConnected = false
        currentBPM = 0
        contactLost = false
        currentSource = nil
        lastSampleAt = nil
        lastPacket = nil
        hasPendingResend = false
        statusText = "Fermato"
    }

    // MARK: - Auto-start su rilevamento AirPods

    private func setupAudioRouteMonitor() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive(_:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        // Valuta subito lo stato del route (gli AirPods potrebbero essere già attivi).
        evaluateAutoStart()
    }

    @objc nonisolated private func handleAppDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            self.evaluateAutoStart()
            // Se la sessione è viva e il BT è acceso ma non stiamo trasmettendo
            // (es. dopo un periodo in background con BT spento e riacceso), ripubblica.
            if let mgr = self.peripheralManager,
               mgr.state == .poweredOn,
               self.session != nil,
               !self.isBroadcasting {
                self.publishService()
            }
        }
    }

    @objc nonisolated private func handleRouteChange(_ notification: Notification) {
        Task { @MainActor in
            self.evaluateAutoStart()
        }
    }

    private func evaluateAutoStart() {
        guard autoStartEnabled else { return }
        let airpodsActive = isAirPodsActiveOutput()
        if airpodsActive {
            if session == nil && !isStarting {
                statusText = "AirPods rilevati — avvio automatico"
                start()
            }
        } else {
            if session != nil || isBroadcasting {
                statusText = "AirPods disconnessi — arresto automatico"
                stop()
            }
        }
    }

    private func isAirPodsActiveOutput() -> Bool {
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

    // MARK: - HealthKit: autorizzazione

    private func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        let hr = HKQuantityType(.heartRate)
        let energy = HKQuantityType(.activeEnergyBurned)
        let dist = HKQuantityType(.distanceWalkingRunning)
        let workout = HKObjectType.workoutType()

        // Servono i permessi di scrittura perche' il live builder raccoglie/salva i campioni.
        let share: Set = [hr, energy, dist, workout]
        let read:  Set<HKObjectType> = [hr, energy, dist, workout]

        healthStore.requestAuthorization(toShare: share, read: read) { ok, err in
            if let err { self.log.error("Auth error: \(err.localizedDescription)") }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    // MARK: - HealthKit: sessione di allenamento (e' cio' che "accende" gli AirPods)

    private func startWorkoutSession() {
        let config = HKWorkoutConfiguration()
        config.activityType = .running       // cambia se preferisci .other / .cycling
        config.locationType = .unknown

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore,
                                                         workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self

            self.session = session
            self.builder = builder

            session.startActivity(with: Date())
            builder.beginCollection(withStart: Date()) { [weak self] ok, err in
                Task { @MainActor in
                    guard let self else { return }
                    if ok {
                        self.statusText = "Sessione attiva — indossa gli AirPods"
                        self.startContactWatchdog()
                        self.startHRSourceMonitor()
                    } else {
                        self.statusText = "Errore avvio sessione: \(err?.localizedDescription ?? "?")"
                    }
                }
            }
        } catch {
            statusText = "Impossibile creare la sessione: \(error.localizedDescription)"
            log.error("Session error: \(error.localizedDescription)")
        }
    }

    // MARK: - CoreBluetooth: setup peripheral

    private func setupPeripheral() {
        guard peripheralManager == nil else { return }
        // restoreIdentifier abilita la state restoration in background
        let options: [String: Any] = [CBPeripheralManagerOptionRestoreIdentifierKey: "airhrmdiy.peripheral"]
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil, options: options)
    }

    private func publishService() {
        guard let mgr = peripheralManager, mgr.state == .poweredOn else { return }

        // Se il sistema ha già ripristinato il nostro servizio via willRestoreState,
        // la characteristic è già agganciata: saltiamo il re-add e ripartiamo dall'advertising.
        if hrCharacteristic != nil {
            startAdvertising()
            return
        }

        // Heart Rate Measurement (notify)
        let hrChar = CBMutableCharacteristic(
            type: hrMeasUUID,
            properties: [.notify, .read],
            value: nil,
            permissions: [.readable]
        )

        // Body Sensor Location = "Ear Lobe" (0x05)
        let bodyLoc = CBMutableCharacteristic(
            type: bodyLocUUID,
            properties: [.read],
            value: Data([0x05]),
            permissions: [.readable]
        )

        let service = CBMutableService(type: hrServiceUUID, primary: true)
        service.characteristics = [hrChar, bodyLoc]
        self.hrCharacteristic = hrChar

        mgr.removeAllServices()
        mgr.add(service)
    }

    private func startAdvertising() {
        guard let mgr = peripheralManager, mgr.state == .poweredOn else { return }
        mgr.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [hrServiceUUID],
            CBAdvertisementDataLocalNameKey: localName
        ])
        isBroadcasting = true
        statusText = "In trasmissione come \(localName)"
    }

    // MARK: - Emissione del pacchetto HR

    private func broadcast(bpm: Int) {
        // Ignora valori non plausibili (gli AirPods, quando perdono contatto, smettono di
        // inviare campioni; un eventuale 0 sarebbe rumore da non ritrasmettere).
        guard bpm > 0 else { return }

        lastSampleAt = Date()
        if contactLost {
            contactLost = false
            statusText = "Contatto ripreso"
        }
        currentBPM = bpm

        // Formato Heart Rate Measurement: byte0 = flags, byte1 = HR (uint8)
        // flags 0x00 => valore HR a 8 bit, nessun campo extra.
        let clamped = UInt8(max(0, min(255, bpm)))
        let packet = Data([0x00, clamped])
        lastPacket = packet

        guard let mgr = peripheralManager, let char = hrCharacteristic else { return }

        let ok = mgr.updateValue(packet, for: char, onSubscribedCentrals: nil)
        if !ok {
            hasPendingResend = true
            log.debug("updateValue in coda (transmit queue piena), attendo isReady")
        } else {
            hasPendingResend = false
        }
    }

    // Ritrasmette l'ultimo pacchetto disponibile se ne avevamo uno in attesa.
    // Usa lastPacket (non quello che ha fallito) così il central riceve il valore più recente.
    private func flushPendingPacket() {
        guard hasPendingResend,
              let pkt = lastPacket,
              let mgr = peripheralManager,
              let char = hrCharacteristic else { return }
        let ok = mgr.updateValue(pkt, for: char, onSubscribedCentrals: nil)
        if ok { hasPendingResend = false }
    }

    // MARK: - Contact-lost watchdog

    private func startContactWatchdog() {
        contactWatchdog?.invalidate()
        // Resetta il timestamp così che il watchdog non scatti subito senza dati.
        lastSampleAt = nil
        contactLost = false
        contactWatchdog = Timer.scheduledTimer(withTimeInterval: Self.contactWatchdogInterval,
                                               repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkContactTimeout() }
        }
    }

    private func checkContactTimeout() {
        guard let last = lastSampleAt else { return }
        let elapsed = Date().timeIntervalSince(last)
        guard elapsed > Self.contactLostThreshold else { return }
        if !contactLost {
            contactLost = true
            statusText = "Contatto perso — Garmin in fallback al polso"
            log.debug("contact-lost dopo \(elapsed, format: .fixed(precision: 1))s")
        }
    }

    // MARK: - Sorgente HealthKit (Watch / AirPods) per trasparenza in UI

    private func startHRSourceMonitor() {
        if let q = anchoredHRQuery { healthStore.stop(q) }
        let hrType = HKQuantityType(.heartRate)
        let predicate = HKQuery.predicateForSamples(withStart: Date(), end: nil, options: .strictStartDate)
        let handler: @Sendable (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = { [weak self] _, samples, _, _, _ in
            guard let label = HeartRateBridge.deviceLabel(forLatestIn: samples) else { return }
            Task { @MainActor in self?.currentSource = label }
        }
        let q = HKAnchoredObjectQuery(type: hrType,
                                      predicate: predicate,
                                      anchor: nil,
                                      limit: HKObjectQueryNoLimit,
                                      resultsHandler: handler)
        q.updateHandler = handler
        healthStore.execute(q)
        anchoredHRQuery = q
    }

    private nonisolated static func deviceLabel(forLatestIn samples: [HKSample]?) -> String? {
        guard let samples, !samples.isEmpty else { return nil }
        let latest = samples
            .compactMap { $0 as? HKQuantitySample }
            .max(by: { $0.endDate < $1.endDate })
        guard let device = latest?.device else { return nil }
        let blob = ((device.model ?? "") + " "
                    + (device.name ?? "") + " "
                    + (device.localIdentifier ?? "")).lowercased()
        if blob.contains("watch") { return "Apple Watch" }
        if blob.contains("airpods") { return "AirPods" }
        if blob.contains("iphone") { return "iPhone" }
        return device.name ?? device.model
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate (HR live in arrivo)

extension HeartRateBridge: HKLiveWorkoutBuilderDelegate {

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let hrType = HKQuantityType(.heartRate)
        guard collectedTypes.contains(hrType) else { return }
        let stats = workoutBuilder.statistics(for: hrType)
        Task { @MainActor in
            if let q = stats?.mostRecentQuantity() {
                let bpm = Int(q.doubleValue(for: self.bpmUnit).rounded())
                self.broadcast(bpm: bpm)
            }
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) { }
}

// MARK: - HKWorkoutSessionDelegate

extension HeartRateBridge: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) { }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didFailWithError error: Error) {
        Task { @MainActor in self.statusText = "Sessione fallita: \(error.localizedDescription)" }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension HeartRateBridge: CBPeripheralManagerDelegate {

    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            switch peripheral.state {
            case .poweredOn:
                self.publishService()
            case .poweredOff:
                self.isBroadcasting = false
                self.subscriberConnected = false
                self.statusText = "Bluetooth spento"
            case .unauthorized:
                self.statusText = "Permesso Bluetooth negato"
            case .unsupported:
                self.statusText = "Bluetooth non supportato"
            case .resetting:
                self.isBroadcasting = false
                self.subscriberConnected = false
                self.statusText = "Bluetooth in reset…"
            case .unknown:
                self.statusText = "Bluetooth in inizializzazione…"
            @unknown default:
                break
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       didAdd service: CBService,
                                       error: Error?) {
        Task { @MainActor in
            if let error { self.statusText = "Errore add service: \(error.localizedDescription)" }
            else { self.startAdvertising() }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       central: CBCentral,
                                       didSubscribeTo characteristic: CBCharacteristic) {
        Task { @MainActor in
            self.subscriberConnected = true
            self.statusText = "Dispositivo collegato (es. Garmin)"
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       central: CBCentral,
                                       didUnsubscribeFrom characteristic: CBCharacteristic) {
        Task { @MainActor in self.subscriberConnected = false }
    }

    // State restoration: il sistema rilancia l'app in background passandoci i servizi
    // che teneva pubblicati per nostro conto. Ricolleghiamo la nostra characteristic
    // e proviamo a recuperare la sessione workout, così possiamo riprendere a notificare.
    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       willRestoreState dict: [String : Any]) {
        let restoredServices = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService]
        Task { @MainActor in
            if let services = restoredServices {
                for svc in services where svc.uuid == self.hrServiceUUID {
                    let chars = svc.characteristics ?? []
                    for c in chars where c.uuid == self.hrMeasUUID {
                        if let mutable = c as? CBMutableCharacteristic {
                            self.hrCharacteristic = mutable
                        }
                    }
                }
            }
            self.statusText = "Stato BLE ripristinato dal sistema"
            self.recoverWorkoutSessionIfNeeded()
            // L'advertising verrà ripreso quando peripheralManagerDidUpdateState
            // riporterà lo stato a .poweredOn (publishService() farà il giusto).
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       didReceiveRead request: CBATTRequest) {
        peripheral.respond(to: request, withResult: .success)
    }

    // Transmit queue di CB di nuovo libera: rispediamo il pacchetto più recente.
    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        Task { @MainActor in self.flushPendingPacket() }
    }
}

// MARK: - Recovery sessione workout (background / restart)

extension HeartRateBridge {

    fileprivate func recoverWorkoutSessionIfNeeded() {
        guard session == nil else { return }
        healthStore.recoverActiveWorkoutSession { [weak self] recovered, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.log.error("Recover session: \(error.localizedDescription)")
                    return
                }
                guard let s = recovered else { return }
                let b = s.associatedWorkoutBuilder()
                if b.dataSource == nil {
                    b.dataSource = HKLiveWorkoutDataSource(healthStore: self.healthStore,
                                                           workoutConfiguration: s.workoutConfiguration)
                }
                s.delegate = self
                b.delegate = self
                self.session = s
                self.builder = b
                self.startContactWatchdog()
                self.startHRSourceMonitor()
                self.statusText = "Sessione workout recuperata dal background"
            }
        }
    }
}
