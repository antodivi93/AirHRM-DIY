//
//  HealthKitHRSource.swift
//  AirHRM-DIY
//
//  Lato HealthKit: autorizzazione, HKWorkoutSession + HKLiveWorkoutBuilder per
//  "accendere" il sensore HR (es. AirPods Pro 3 / Apple Watch), classificazione
//  della sorgente del campione, e recovery della sessione attiva dal background.
//

import Foundation
import HealthKit
import os

@MainActor
final class HealthKitHRSource: NSObject {

    /// Callback su MainActor: nuovo BPM valido in arrivo.
    var onBPM: ((Int) -> Void)?
    /// Callback su MainActor: etichetta della sorgente HK ("Apple Watch", "AirPods", …).
    var onSourceLabel: ((String) -> Void)?
    /// Callback su MainActor: errore o messaggio diagnostico.
    var onError: ((String) -> Void)?

    private(set) var isRunning: Bool = false

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var anchoredHRQuery: HKAnchoredObjectQuery?
    private let bpmUnit = HKUnit.count().unitDivided(by: .minute())
    private let log = Logger(subsystem: "com.tuonome.airhrmdiy", category: "hk-source")

    // MARK: - Public lifecycle

    func start(completion: @escaping (Bool) -> Void) {
        guard !isRunning else { completion(true); return }
        guard HKHealthStore.isHealthDataAvailable() else {
            onError?("HealthKit non disponibile su questo dispositivo")
            completion(false)
            return
        }
        requestAuthorization { [weak self] ok in
            guard let self else { completion(false); return }
            guard ok else {
                self.onError?("Autorizzazione HealthKit negata")
                completion(false)
                return
            }
            self.startSession(completion: completion)
        }
    }

    func stop() {
        session?.end()
        builder?.endCollection(withEnd: Date()) { _, _ in }
        if let q = anchoredHRQuery { healthStore.stop(q) }
        anchoredHRQuery = nil
        session = nil
        builder = nil
        isRunning = false
    }

    /// Tenta il recovery di un'eventuale sessione workout attiva (es. dopo state
    /// restoration di Core Bluetooth o crash recovery). `onRecovered` è invocato
    /// solo se è stata effettivamente recuperata una sessione.
    func recoverActiveSession(onRecovered: @escaping () -> Void) {
        guard session == nil else { return }
        healthStore.recoverActiveWorkoutSession { [weak self] recovered, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.log.error("Recover: \(error.localizedDescription)")
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
                self.isRunning = true
                self.startSourceMonitor()
                onRecovered()
            }
        }
    }

    // MARK: - Internals

    private func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        let hr = HKQuantityType(.heartRate)
        let energy = HKQuantityType(.activeEnergyBurned)
        let dist = HKQuantityType(.distanceWalkingRunning)
        let workout = HKObjectType.workoutType()

        let share: Set = [hr, energy, dist, workout]
        let read: Set<HKObjectType> = [hr, energy, dist, workout]

        healthStore.requestAuthorization(toShare: share, read: read) { [weak self] ok, err in
            if let err { self?.log.error("Auth error: \(err.localizedDescription)") }
            Task { @MainActor in completion(ok) }
        }
    }

    private func startSession(completion: @escaping (Bool) -> Void) {
        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = .unknown

        do {
            let s = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let b = s.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore,
                                                   workoutConfiguration: config)
            s.delegate = self
            b.delegate = self

            self.session = s
            self.builder = b

            s.startActivity(with: Date())
            b.beginCollection(withStart: Date()) { [weak self] ok, err in
                Task { @MainActor in
                    guard let self else { return }
                    if ok {
                        self.isRunning = true
                        self.startSourceMonitor()
                        completion(true)
                    } else {
                        self.onError?("Errore avvio sessione: \(err?.localizedDescription ?? "?")")
                        completion(false)
                    }
                }
            }
        } catch {
            onError?("Impossibile creare la sessione: \(error.localizedDescription)")
            log.error("Session error: \(error.localizedDescription)")
            completion(false)
        }
    }

    private func startSourceMonitor() {
        if let q = anchoredHRQuery { healthStore.stop(q) }
        let hrType = HKQuantityType(.heartRate)
        let predicate = HKQuery.predicateForSamples(withStart: Date(), end: nil, options: .strictStartDate)
        let handler: @Sendable (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = { [weak self] _, samples, _, _, _ in
            guard let label = Self.deviceLabel(forLatestIn: samples) else { return }
            Task { @MainActor in self?.onSourceLabel?(label) }
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

// MARK: - HKLiveWorkoutBuilderDelegate

extension HealthKitHRSource: HKLiveWorkoutBuilderDelegate {

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let hrType = HKQuantityType(.heartRate)
        guard collectedTypes.contains(hrType) else { return }
        let stats = workoutBuilder.statistics(for: hrType)
        Task { @MainActor in
            if let q = stats?.mostRecentQuantity() {
                let bpm = Int(q.doubleValue(for: self.bpmUnit).rounded())
                if bpm > 0 { self.onBPM?(bpm) }
            }
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) { }
}

// MARK: - HKWorkoutSessionDelegate

extension HealthKitHRSource: HKWorkoutSessionDelegate {

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) { }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didFailWithError error: Error) {
        Task { @MainActor in
            self.onError?("Sessione fallita: \(error.localizedDescription)")
        }
    }
}
