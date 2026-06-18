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
        case .idle:                 return "Pronto"
        case .starting:             return "Avvio sessione di allenamento…"
        case .waitingForSensor:     return "Sessione attiva — indossa gli AirPods"
        case .broadcasting:         return "In trasmissione come \(HRGatt.localName)"
        case .contactLost:          return "Contatto perso — Garmin in fallback al polso"
        case .sessionRecovered:     return "Sessione workout recuperata dal background"
        case .bluetoothOff:         return "Bluetooth spento"
        case .bluetoothDenied:      return "Permesso Bluetooth negato"
        case .bluetoothUnavailable: return "Bluetooth non supportato"
        case .bluetoothResetting:   return "Bluetooth in reset…"
        case .error(let msg):       return msg
        }
    }
}
