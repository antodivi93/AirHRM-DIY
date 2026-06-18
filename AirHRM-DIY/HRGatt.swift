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

    // Body Sensor Location: "Ear Lobe"
    static let bodySensorLocationEarLobe: UInt8 = 0x05

    static let localName         = "AirHRM-DIY"
    static let restoreIdentifier = "airhrmdiy.peripheral"
}
