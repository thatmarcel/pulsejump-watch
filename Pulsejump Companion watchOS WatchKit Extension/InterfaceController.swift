//
//  InterfaceController.swift
//  Pulsejump Companion watchOS WatchKit Extension
//
//  Created by Marcel Braun on 09.12.20.
//

import WatchKit
import Foundation
import HealthKit
import PubNub

class InterfaceController: WKInterfaceController {
    
    @IBOutlet weak var toggleButton: WKInterfaceButton!
    @IBOutlet weak var statusLabel: WKInterfaceLabel!
    
    var isWorkoutActive = false {
        didSet {
            toggleButton.setTitle(isWorkoutActive ? "Beenden" : "Starten")
        }
    }
    
    var pubnub: PubNub!
    var healthStore: HKHealthStore!
    var session: HKWorkoutSession!
    let heartRateUnit = HKUnit(from: "count/min")
    
    var firstActivation = true
    
    var statusText: String = "Wird geladen..." {
        didSet {
            DispatchQueue.main.async {
                self.statusLabel.setText(self.statusText)
            }
        }
    }

    override func awake(withContext context: Any?) {
        // Configure interface objects here.
    }
    
    override func willActivate() {
        guard firstActivation else {
            return
        }
        
        firstActivation = false
        
        healthStore = HKHealthStore()
        
        guard HKHealthStore.isHealthDataAvailable() else {
            self.statusText = "Gesundheitsdaten nicht verfügbar"
            return
        }
        
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: HKQuantityTypeIdentifier.heartRate) else {
            self.statusText = "Berechtigung fehlt"
            return
        }
        
        healthStore.requestAuthorization(toShare: nil, read: Set(arrayLiteral: quantityType)) { (success, error) -> Void in
            if success {
                self.statusText = "Idle"
                self.connect()
            } else {
                self.statusText = "Berechtigung fehlt"
            }
        }
    }
    
    func connect() {
        pubnub = PubNub(configuration: PubNubConfiguration(
            publishKey: "pub-c-1b9d9b9d-5b17-4df5-aebb-0cbc9dac1149",
            subscribeKey: "sub-c-45eb9030-3a50-11eb-ab29-9acd6868450b",
            uuid: WKInterfaceDevice.current().identifierForVendor?.uuidString ?? "default"
        ))
        
        let sl = SubscriptionListener()
        sl.didReceiveStatus = { (statusEvent) in
            guard let status = try? statusEvent.get() else {
                return
            }
            
            self.statusText = status.isConnected ? "Verbunden" : "Verbindung unterbrochen"
        }
        
        pubnub.add(sl)
        
        self.statusText = "Verbindung läuft..."
        pubnub.subscribe(to: ["heartrates"], withPresence: true)
    }
    
    @IBAction func toggle() {
        if isWorkoutActive {
            session.end()
            WKExtension.shared().isAutorotating = false
        } else {
            let workoutConfiguration = HKWorkoutConfiguration()
            workoutConfiguration.activityType = .other
            workoutConfiguration.locationType = .unknown
                    
            session = try! HKWorkoutSession(healthStore: healthStore, configuration: workoutConfiguration)
            session.delegate = self
            
            session.startActivity(with: Date())
            
            WKExtension.shared().isAutorotating = true
        }
        
        isWorkoutActive = !isWorkoutActive
    }
    
    func update(with samples: [HKQuantitySample]) {
        DispatchQueue.main.async {
            guard let sample = samples.first else{return}
            let bpm = Int(sample.quantity.doubleValue(for: self.heartRateUnit))
            self.pubnub.publish(channel: "heartrates", message: String(bpm), completion: nil)
        }
    }
    
    var heartRateQuery: HKAnchoredObjectQuery!

    func startQuerying() {
        guard let quantityType = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier.heartRate) else {
            toggle()
            return
        }
        
        let datePredicate = HKQuery.predicateForSamples(withStart: session.startDate, end: nil, options: .strictEndDate)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [datePredicate])
        heartRateQuery = HKAnchoredObjectQuery(type: quantityType, predicate: predicate, anchor: nil, limit: Int(HKObjectQueryNoLimit)) { (query, sampleObjects, deletedObjects, newAnchor, error) -> Void in
            self.update(with: sampleObjects as? [HKQuantitySample] ?? [])
        }
                
        heartRateQuery.updateHandler = {(query, samples, deleteObjects, newAnchor, error) -> Void in
            self.update(with: samples as? [HKQuantitySample] ?? [])
        }
        
        print("executing")
        healthStore.execute(heartRateQuery)
    }
}

extension InterfaceController: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        print("new state: \(toState)")
        if toState == .running {
            self.startQuerying()
        }
    }
    
    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        print("failed with error: \(error)")
    }
}
