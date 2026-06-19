//
//  HRPeripheralAdvertiser.swift
//  AirHRM-DIY
//
//  Lato Core Bluetooth: pubblica il GATT Heart Rate Service come peripheral,
//  gestisce advertising, sottoscrittori, ritrasmissione su transmit queue piena,
//  e state restoration in background.
//
//  Il manager viene creato in bootstrap() ANCHE quando il ponte è fermo: serve
//  early in app launch perché iOS possa ri-consegnare willRestoreState. L'effettivo
//  advertising è gated da shouldAdvertise e viene abilitato solo da resumeAdvertising().
//

import Foundation
import CoreBluetooth
import os

@MainActor
final class HRPeripheralAdvertiser: NSObject {

    enum State: Equatable {
        case idle
        case waitingForBluetooth
        case advertising
        case bluetoothOff
        case bluetoothDenied
        case bluetoothUnavailable
        case bluetoothResetting
        case restoredFromBackground
    }

    /// Callback su MainActor a ogni cambio di stato BLE rilevante.
    var onStateChange: ((State) -> Void)?
    /// Callback su MainActor a ogni cambio sottoscrittori (true = central attaccato).
    var onSubscriberChange: ((Bool) -> Void)?

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    private var manager: CBPeripheralManager?
    private var hrCharacteristic: CBMutableCharacteristic?
    private var lastPacket: Data?
    private var hasPendingResend: Bool = false
    /// Gate: solo quando true pubblichiamo servizio e advertise.
    private var shouldAdvertise: Bool = false

    private let log = Logger(subsystem: "com.tuonome.airhrmdiy", category: "ble")

    /// Crea il peripheral manager con restoreIdentifier. Necessario early in app launch
    /// per ricevere willRestoreState al relancio in background. Non avvia advertising.
    func bootstrap() {
        guard manager == nil else { return }
        state = .waitingForBluetooth
        let options: [String: Any] = [
            CBPeripheralManagerOptionRestoreIdentifierKey: HRGatt.restoreIdentifier
        ]
        manager = CBPeripheralManager(delegate: self, queue: nil, options: options)
    }

    /// Abilita la pubblicazione e l'advertising. Idempotente.
    func resumeAdvertising() {
        shouldAdvertise = true
        bootstrap()
        if let mgr = manager, mgr.state == .poweredOn {
            publishService()
        }
    }

    /// Disabilita advertising e rimuove il servizio. Il manager resta vivo per la
    /// state restoration; non lo distruggiamo.
    func stop() {
        shouldAdvertise = false
        manager?.stopAdvertising()
        manager?.removeAllServices()
        hrCharacteristic = nil
        lastPacket = nil
        hasPendingResend = false
        onSubscriberChange?(false)
        state = .idle
    }

    /// Pubblica il prossimo BPM. Ignora valori <= 0 (silenzio reale per "contact lost").
    func broadcast(bpm: Int) {
        guard bpm > 0 else { return }
        let clamped = UInt8(max(0, min(255, bpm)))
        // Formato Heart Rate Measurement: byte0 = flags, byte1 = HR (uint8). Flags 0x00.
        let packet = Data([0x00, clamped])
        lastPacket = packet

        guard let mgr = manager, let char = hrCharacteristic else { return }
        let ok = mgr.updateValue(packet, for: char, onSubscribedCentrals: nil)
        if ok {
            hasPendingResend = false
        } else {
            hasPendingResend = true
            log.debug("updateValue in coda (transmit queue piena), attendo isReady")
        }
    }

    /// Da chiamare al ritorno in foreground: se il manager è acceso ma non advertise
    /// pur dovendo, ripubblica.
    func reassertIfNeeded() {
        guard shouldAdvertise else { return }
        guard let mgr = manager, mgr.state == .poweredOn else { return }
        if !mgr.isAdvertising { publishService() }
    }

    // MARK: - Internals

    private func publishService() {
        guard shouldAdvertise else { return }
        guard let mgr = manager, mgr.state == .poweredOn else { return }

        // Se il sistema ha già ripristinato il servizio via willRestoreState,
        // la characteristic è già agganciata: salta il re-add e advertise subito.
        if hrCharacteristic != nil {
            startAdvertising()
            return
        }

        // Heart Rate Service (0x180D)
        // NOTA: il Device Information Service (0x180A) NON è pubblicabile da un
        // CBPeripheralManager su iOS — il sistema lo rifiuta con "The specified
        // UUID is not allowed for this operation". iOS gestisce il DIS a livello
        // di OS, quindi il central (Garmin) lo trova comunque a livello di
        // sistema; il nostro app deve esporre solo HRS.
        let hrChar = CBMutableCharacteristic(
            type: HRGatt.heartRateMeasurementUUID,
            properties: [.notify, .read],
            value: nil,
            permissions: [.readable]
        )
        let bodyLoc = CBMutableCharacteristic(
            type: HRGatt.bodySensorLocationUUID,
            properties: [.read],
            value: Data([HRGatt.bodySensorLocationChest]),
            permissions: [.readable]
        )
        let hrService = CBMutableService(type: HRGatt.serviceUUID, primary: true)
        hrService.characteristics = [hrChar, bodyLoc]
        hrCharacteristic = hrChar

        mgr.removeAllServices()
        mgr.add(hrService)
    }

    private func startAdvertising() {
        guard let mgr = manager, mgr.state == .poweredOn else { return }
        // Forza un restart pulito: quando l'advertising è già attivo (es. perché
        // restorato dal sistema o residuo da una sessione precedente con restoreIdentifier)
        // iOS lo mantiene in formato "overflow" non visibile ai central non-iOS.
        // Stoppando e ri-startando in foreground iOS lo riemette nel formato standard.
        if mgr.isAdvertising {
            mgr.stopAdvertising()
            log.notice("[ble] stopAdvertising prima del restart pulito")
        }
        mgr.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [HRGatt.serviceUUID],
            CBAdvertisementDataLocalNameKey: HRGatt.localName
        ])
        state = .advertising
        log.notice("[ble] startAdvertising service=\(HRGatt.serviceUUID) name=\(HRGatt.localName)")
    }

    private func flushPendingPacket() {
        guard hasPendingResend,
              let pkt = lastPacket,
              let mgr = manager,
              let char = hrCharacteristic else { return }
        let ok = mgr.updateValue(pkt, for: char, onSubscribedCentrals: nil)
        if ok { hasPendingResend = false }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension HRPeripheralAdvertiser: CBPeripheralManagerDelegate {

    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager,
                                                          error: Error?) {
        let errDesc = error?.localizedDescription
        let advertising = peripheral.isAdvertising
        Task { @MainActor in
            if let errDesc {
                self.log.error("[ble] startAdvertising REJECTED by iOS: \(errDesc)")
            } else {
                self.log.notice("[ble] iOS confirmed advertising started, isAdvertising=\(advertising)")
            }
        }
    }

    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let rawState = peripheral.state.rawValue
        Task { @MainActor in
            self.log.notice("[ble] didUpdateState raw=\(rawState)")
            switch peripheral.state {
            case .poweredOn:
                self.publishService()
            case .poweredOff:
                self.onSubscriberChange?(false)
                self.state = .bluetoothOff
            case .unauthorized:
                self.state = .bluetoothDenied
            case .unsupported:
                self.state = .bluetoothUnavailable
            case .resetting:
                self.onSubscriberChange?(false)
                self.state = .bluetoothResetting
            case .unknown:
                self.state = .waitingForBluetooth
            @unknown default:
                break
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       didAdd service: CBService,
                                       error: Error?) {
        let uuid = service.uuid
        let addedHR = uuid == HRGatt.serviceUUID
        let errDesc = error?.localizedDescription
        Task { @MainActor in
            if let errDesc {
                self.state = .bluetoothUnavailable
                self.log.error("[ble] add service \(uuid) FAILED: \(errDesc)")
                return
            }
            self.log.notice("[ble] add service \(uuid) OK")
            if addedHR { self.startAdvertising() }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       central: CBCentral,
                                       didSubscribeTo characteristic: CBCharacteristic) {
        let centralID = central.identifier.uuidString.prefix(8)
        let charUUID = characteristic.uuid
        Task { @MainActor in
            self.log.notice("[ble] central \(centralID) didSubscribeTo \(charUUID)")
            self.onSubscriberChange?(true)
            // Push immediato dell'ultimo valore conosciuto: alcuni central (Garmin in
            // particolare) si disconnettono se non ricevono dati entro pochi secondi
            // dalla subscribe. Se non abbiamo ancora un BPM, mandiamo un placeholder a
            // 60 BPM così la connessione resta viva finché HealthKit non emette un sample.
            guard let char = self.hrCharacteristic else { return }
            let pkt = self.lastPacket ?? Data([0x00, 60])
            let ok = peripheral.updateValue(pkt, for: char, onSubscribedCentrals: [central])
            self.log.notice("[ble] initial push to central \(centralID) ok=\(ok)")
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       central: CBCentral,
                                       didUnsubscribeFrom characteristic: CBCharacteristic) {
        let centralID = central.identifier.uuidString.prefix(8)
        Task { @MainActor in
            self.log.notice("[ble] central \(centralID) didUnsubscribe")
            self.onSubscriberChange?(false)
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       didReceiveRead request: CBATTRequest) {
        let centralID = request.central.identifier.uuidString.prefix(8)
        let charUUID = request.characteristic.uuid
        Task { @MainActor in
            self.log.notice("[ble] central \(centralID) didReceiveRead \(charUUID)")
        }
        peripheral.respond(to: request, withResult: .success)
    }

    // Transmit queue libera: rispediamo il pacchetto più recente.
    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        Task { @MainActor in self.flushPendingPacket() }
    }

    // State restoration: ricolleghiamo la nostra CBMutableCharacteristic dai servizi
    // che il sistema teneva pubblicati per nostro conto. Il sistema ci ha rilanciato
    // proprio perché c'era un central interessato: riattiviamo l'advertising.
    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       willRestoreState dict: [String : Any]) {
        let restored = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService]
        Task { @MainActor in
            if let services = restored {
                for svc in services where svc.uuid == HRGatt.serviceUUID {
                    for c in svc.characteristics ?? [] where c.uuid == HRGatt.heartRateMeasurementUUID {
                        if let mutable = c as? CBMutableCharacteristic {
                            self.hrCharacteristic = mutable
                        }
                    }
                }
            }
            self.shouldAdvertise = true
            self.state = .restoredFromBackground
            // L'advertising riprenderà appena peripheralManagerDidUpdateState
            // riporterà lo stato a .poweredOn → publishService().
        }
    }
}
