//
//  HRGatt.swift
//  AirHRM-DIY
//
//  Costanti del profilo GATT Heart Rate (Bluetooth SIG) che usiamo come peripheral.
//

import Foundation
import CoreBluetooth

enum HRGatt {
    static let serviceUUID                = CBUUID(string: "180D") // Heart Rate Service
    static let heartRateMeasurementUUID   = CBUUID(string: "2A37") // Heart Rate Measurement
    static let bodySensorLocationUUID     = CBUUID(string: "2A38") // Body Sensor Location

    // Device Information Service — alcuni firmware Garmin lo richiedono per
    // accettare un sensore HR di terze parti, altrimenti si disconnettono prima
    // di sottoscrivere le notifiche.
    static let deviceInfoServiceUUID      = CBUUID(string: "180A") // Device Information
    static let manufacturerNameUUID       = CBUUID(string: "2A29") // Manufacturer Name String
    static let modelNumberUUID            = CBUUID(string: "2A24") // Model Number String

    // Body Sensor Location: "Ear Lobe"
    static let bodySensorLocationEarLobe: UInt8 = 0x05

    static let localName         = "AirHRM-DIY"
    static let manufacturerName  = "AirHRM-DIY"
    static let modelNumber       = "AirPods HR Bridge"
    static let restoreIdentifier = "airhrmdiy.peripheral"
}
