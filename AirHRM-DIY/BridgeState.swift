//
//  BridgeState.swift
//  AirHRM-DIY
//
//  Stato durevole del ponte HR. La view legge displayText anziché stringhe sparse.
//

import Foundation

enum BridgeState: Equatable {
    case idle                       // app pronta, ponte fermo
    case starting                   // auth HealthKit + creazione sessione in corso
    case waitingForSensor           // sessione attiva ma nessun sample HR ancora
    case broadcasting               // sample in arrivo e notifiche BLE attive
    case contactLost                // nessun sample HR oltre la soglia
    case sessionRecovered           // sessione recuperata dal background
    case bluetoothOff               // BT spento dall'utente
    case bluetoothDenied            // permesso BT negato
    case bluetoothUnavailable       // dispositivo senza BT LE o in errore permanente
    case bluetoothResetting         // BT in reset transitorio
    case error(String)

    var displayText: String {
        switch self {
        case .idle:                 return "Ready"
        case .starting:             return "Starting workout session…"
        case .waitingForSensor:     return "Session active — put on the AirPods"
        case .broadcasting:         return "Broadcasting as \(HRGatt.localName)"
        case .contactLost:          return "Contact lost — receiver falling back to wrist"
        case .sessionRecovered:     return "Workout session recovered from background"
        case .bluetoothOff:         return "Bluetooth off"
        case .bluetoothDenied:      return "Bluetooth permission denied"
        case .bluetoothUnavailable: return "Bluetooth not supported"
        case .bluetoothResetting:   return "Bluetooth resetting…"
        case .error(let msg):       return msg
        }
    }
}
