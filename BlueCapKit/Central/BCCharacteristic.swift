//
//  BCCharacteristic.swift
//  BlueCap
//
//  Created by Troy Stribling on 6/8/14.
//  Copyright (c) 2014 Troy Stribling. The MIT License (MIT).
//

import Foundation
import CoreBluetooth

// MARK: - IO Parameters -
struct WriteParameters {
    let value : NSData
    let timeout : Double
    let type : CBCharacteristicWriteType
}

struct ReadParameters {
    let timeout : Double
}

// MARK: - BCCharacteristic -
public class BCCharacteristic {

    // MARK: Properties
    static let ioQueue      = Queue("us.gnos.blueCap.characteristic.io")
    static let timeoutQueue = Queue("us.gnos.blueCap.characteristic.timeout")

    private var _notificationStateChangedPromise: Promise<BCCharacteristic>?
    private var _notificationUpdatePromise: StreamPromise<(characteristic: BCCharacteristic, data: NSData?)>?

    private var readPromises    = BCSerialIOArray<Promise<BCCharacteristic>>(BCCharacteristic.ioQueue)
    private var writePromises   = BCSerialIOArray<Promise<BCCharacteristic>>(BCCharacteristic.ioQueue)
    private var readParameters  = BCSerialIOArray<ReadParameters>(BCCharacteristic.ioQueue)
    private var writeParameters = BCSerialIOArray<WriteParameters>(BCCharacteristic.ioQueue)
    
    private weak var _service: BCService?
    
    private let profile: BCCharacteristicProfile

    private var _reading        = false
    private var _writing        = false
    private var _readSequence   = 0
    private var _writeSequence  = 0
    private let defaultTimeout  = 10.0

    public let cbCharacteristic: CBCharacteristic

    private var notificationStateChangedPromise: Promise<BCCharacteristic>? {
        get {
            return BCCharacteristic.ioQueue.sync { return self._notificationStateChangedPromise }
        }
        set {
            BCCharacteristic.ioQueue.sync { self._notificationStateChangedPromise = newValue }
        }
    }

    private var notificationUpdatePromise: StreamPromise<(characteristic: BCCharacteristic, data: NSData?)>? {
        get {
            return BCCharacteristic.ioQueue.sync { return self._notificationUpdatePromise }
        }
        set {
            BCCharacteristic.ioQueue.sync { self._notificationUpdatePromise = newValue }
        }
    }

    private var reading: Bool {
        get {
            return BCCharacteristic.ioQueue.sync { return self._reading }
        }
        set {
            BCCharacteristic.ioQueue.sync{self._reading = newValue}
        }
    }

    private var writing: Bool {
        get {
            return BCCharacteristic.ioQueue.sync { return self._writing }
        }
        set {
            BCCharacteristic.ioQueue.sync{ self._writing = newValue }
        }
    }

    private var readSequence: Int {
        get {
            return BCCharacteristic.ioQueue.sync { return self._readSequence }
        }
        set {
            BCCharacteristic.ioQueue.sync{ self._readSequence = newValue }
        }
    }

    private var writeSequence: Int {
        get {
            return BCCharacteristic.ioQueue.sync { return self._writeSequence }
        }
        set {
            BCCharacteristic.ioQueue.sync{ self._writeSequence = newValue }
        }
    }
    
    public var uuid: CBUUID {
        return self.cbCharacteristic.UUID
    }
    
    public var name: String {
        return self.profile.name
    }
    
    public var isNotifying: Bool {
        return self.cbCharacteristic.isNotifying
    }
    
    public var afterDiscoveredPromise: StreamPromise<BCCharacteristic>? {
        return self.profile.afterDiscoveredPromise
    }
    
    public var canNotify: Bool {
        return self.propertyEnabled(.Notify)                    ||
               self.propertyEnabled(.Indicate)                  ||
               self.propertyEnabled(.NotifyEncryptionRequired)  ||
               self.propertyEnabled(.IndicateEncryptionRequired)
    }
    
    public var canRead: Bool {
        return self.propertyEnabled(.Read)
    }
    
    public var canWrite: Bool {
        return self.propertyEnabled(.Write) || self.propertyEnabled(.WriteWithoutResponse)
    }
    
    public var service: BCService? {
        return self._service
    }
    
    public var dataValue: NSData? {
        return self.cbCharacteristic.value
    }
    
    public var stringValues: [String] {
        return self.profile.stringValues
    }

    public var stringValue: [String:String]? {
        return self.stringValue(self.dataValue)
    }
    
    public var properties: CBCharacteristicProperties {
        return self.cbCharacteristic.properties
    }

    // MARK: Initializers
    public init(cbCharacteristic: CBCharacteristic, service: BCService) {
        self.cbCharacteristic = cbCharacteristic
        self._service = service
        if let serviceProfile = BCProfileManager.sharedInstance.services[service.uuid] {
            BCLogger.debug("creating characteristic for service profile: \(service.name):\(service.uuid)")
            if let characteristicProfile = serviceProfile.characteristicProfiles[cbCharacteristic.UUID] {
                BCLogger.debug("charcteristic profile found creating characteristic: \(characteristicProfile.name):\(characteristicProfile.uuid.UUIDString)")
                self.profile = characteristicProfile
            } else {
                BCLogger.debug("no characteristic profile found. Creating characteristic with UUID: \(service.uuid.UUIDString)")
                self.profile = BCCharacteristicProfile(uuid: service.uuid.UUIDString)
            }
        } else {
            BCLogger.debug("no service profile found. Creating characteristic with UUID: \(service.uuid.UUIDString)")
            self.profile = BCCharacteristicProfile(uuid: service.uuid.UUIDString)
        }
    }

    // MARK: Data Access
    public func stringValue(data: NSData?) -> [String:String]? {
        if let data = data {
            return self.profile.stringValue(data)
        } else {
            return nil
        }
    }
    
    public func dataFromStringValue(stringValue: [String: String]) -> NSData? {
        return self.profile.dataFromStringValue(stringValue)
    }
    
    public func propertyEnabled(property:CBCharacteristicProperties) -> Bool {
        return (self.properties.rawValue & property.rawValue) > 0
    }

    public func value<T: BCDeserializable>() -> T? {
        if let data = self.dataValue {
            return T.deserialize(data)
        } else {
            return nil
        }
    }

    public func value<T: BCRawDeserializable where T.RawType: BCDeserializable>() -> T? {
        if let data = self.dataValue {
            return BCSerDe.deserialize(data)
        } else {
            return nil
        }
    }

    public func value<T: BCRawArrayDeserializable where T.RawType: BCDeserializable>() -> T? {
        if let data = self.dataValue {
            return BCSerDe.deserialize(data)
        } else {
            return nil
        }
    }

    public func value<T: BCRawPairDeserializable where T.RawType1: BCDeserializable, T.RawType2: BCDeserializable>() -> T? {
        if let data = self.dataValue {
            return BCSerDe.deserialize(data)
        } else {
            return nil
        }
    }

    public func value<T: BCRawArrayPairDeserializable where T.RawType1: BCDeserializable, T.RawType2: BCDeserializable>() -> T? {
        if let data = self.dataValue {
            return BCSerDe.deserialize(data)
        } else {
            return nil
        }
    }

    // MARK: Notifications
    public func startNotifying() -> Future<BCCharacteristic> {
        let promise = Promise<BCCharacteristic>()
        if self.canNotify {
            self.notificationStateChangedPromise = promise
            self.setNotifyValue(true)
        } else {
            promise.failure(BCError.characteristicNotifyNotSupported)
        }
        return promise.future
    }

    public func stopNotifying() -> Future<BCCharacteristic> {
        let promise = Promise<BCCharacteristic>()
        if self.canNotify {
            self.notificationStateChangedPromise = promise
            self.setNotifyValue(false)
        } else {
            promise.failure(BCError.characteristicNotifyNotSupported)
        }
        return promise.future
    }

    public func recieveNotificationUpdates(capacity: Int? = nil) -> FutureStream<(characteristic: BCCharacteristic, data: NSData?)> {
        let promise = StreamPromise<(characteristic: BCCharacteristic, data: NSData?)>(capacity:capacity)
        if self.canNotify {
            self.notificationUpdatePromise = promise
        } else {
            promise.failure(BCError.characteristicNotifyNotSupported)
        }
        return promise.future
    }
    
    public func stopNotificationUpdates() {
        self.notificationUpdatePromise = nil
    }

    // MARK: Read Data
    public func read(timeout: Double = 10.0) -> Future<BCCharacteristic> {
        let promise = Promise<BCCharacteristic>()
        if self.canRead {
            self.readPromises.append(promise)
            self.readParameters.append(ReadParameters(timeout:timeout))
            self.readNext()
        } else {
            promise.failure(BCError.characteristicReadNotSupported)
        }
        return promise.future
    }

    // MARK: Write Data
    public func writeData(value: NSData, timeout: Double = 10.0, type: CBCharacteristicWriteType = .WithResponse) -> Future<BCCharacteristic> {
        let promise = Promise<BCCharacteristic>()
        if self.canWrite {
            self.writePromises.append(promise)
            self.writeParameters.append(WriteParameters(value: value, timeout: timeout, type: type))
            self.writeNext()
        } else {
            promise.failure(BCError.characteristicWriteNotSupported)
        }
        return promise.future
    }

    public func writeString(stringValue: [String: String], timeout: Double = 10.0, type: CBCharacteristicWriteType = .WithResponse) -> Future<BCCharacteristic> {
        if let value = self.dataFromStringValue(stringValue) {
            return self.writeData(value, timeout: timeout, type: type)
        } else {
            let promise = Promise<BCCharacteristic>()
            promise.failure(BCError.characteristicNotSerilaizable)
            return promise.future
        }
    }

    public func write<T: BCDeserializable>(value:T, timeout: Double = 10.0, type: CBCharacteristicWriteType = .WithResponse) -> Future<BCCharacteristic> {
        return self.writeData(BCSerDe.serialize(value), timeout: timeout, type: type)
    }
    
    public func write<T: BCRawDeserializable>(value:T, timeout: Double = 10.0, type: CBCharacteristicWriteType = .WithResponse) -> Future<BCCharacteristic> {
        return self.writeData(BCSerDe.serialize(value), timeout: timeout, type: type)
    }

    public func write<T: BCRawArrayDeserializable>(value: T, timeout: Double = 10.0, type: CBCharacteristicWriteType = .WithResponse) -> Future<BCCharacteristic> {
        return self.writeData(BCSerDe.serialize(value), timeout: timeout, type: type)
    }

    public func write<T: BCRawPairDeserializable>(value: T, timeout: Double = 10.0, type: CBCharacteristicWriteType = .WithResponse) -> Future<BCCharacteristic> {
        return self.writeData(BCSerDe.serialize(value), timeout: timeout, type: type)
    }
    
    public func write<T: BCRawArrayPairDeserializable>(value: T, timeout: Double = 10.0, type: CBCharacteristicWriteType = .WithResponse) -> Future<BCCharacteristic> {
        return self.writeData(BCSerDe.serialize(value), timeout: timeout, type: type)
    }

    // MARK: CBPeripheralDelegate
    internal func didUpdateNotificationState(error: NSError?) {
        guard let notificationStateChangedPromise = self.notificationStateChangedPromise else {
            return
        }
        if let error = error {
            BCLogger.debug("failed uuid=\(self.uuid.UUIDString), name=\(self.name)")
            notificationStateChangedPromise.failure(error)
        } else {
            BCLogger.debug("success:  uuid=\(self.uuid.UUIDString), name=\(self.name)")
            notificationStateChangedPromise.success(self)
        }
    }
    
    internal func didUpdate(error: NSError?) {
        if self.isNotifying {
            self.didNotify(error)
        } else {
            self.didRead(error)
        }
    }
    
    internal func didWrite(error: NSError?) {
        guard let promise = self.shiftPromise(&self.writePromises) where !promise.completed else {
            return
        }
        if let error = error {
            BCLogger.debug("failed:  uuid=\(self.uuid.UUIDString), name=\(self.name)")
            promise.failure(error)
        } else {
            BCLogger.debug("success:  uuid=\(self.uuid.UUIDString), name=\(self.name)")
            promise.success(self)
        }
        self.writing = false
        self.writeNext()
    }

    private func didRead(error: NSError?) {
        guard let promise = self.shiftPromise(&self.readPromises) where !promise.completed else {
            return
        }
        if let error = error {
            promise.failure(error)
        } else {
            promise.success(self)
        }
        self.reading = false
        self.readNext()
    }


    private func didNotify(error: NSError?) {
        guard let notificationUpdatePromise = self.notificationUpdatePromise else {
            return
        }
        if let error = error {
            notificationUpdatePromise.failure(error)
        } else {
            notificationUpdatePromise.success((self, self.dataValue.flatmap{ $0.copy() as? NSData}))
        }
    }

    // MARK: IO Timeout
    private func timeoutRead(sequence: Int, timeout: Double) {
        BCLogger.debug("sequence \(sequence), timeout:\(timeout))")
        BCCharacteristic.timeoutQueue.delay(timeout) {
            if sequence == self.readSequence && self.reading {
                BCLogger.debug("timing out sequence=\(sequence), current readSequence=\(self.readSequence)")
                self.didUpdate(BCError.characteristicReadTimeout)
            } else {
                BCLogger.debug("timeout expired")
            }
        }
    }
    
    private func timeoutWrite(sequence: Int, timeout: Double) {
        BCLogger.debug("sequence \(sequence), timeout:\(timeout)")
        BCCharacteristic.timeoutQueue.delay(timeout) {
            if sequence == self.writeSequence && self.writing {
                BCLogger.debug("timing out sequence=\(sequence), current writeSequence=\(self.writeSequence)")
                self.didWrite(BCError.characteristicWriteTimeout)
            } else {
                BCLogger.debug("timeout expired")
            }
        }
    }

    // MARK: Peripheral Delegates
    private func setNotifyValue(state: Bool) {
        self.service?.peripheral?.setNotifyValue(state, forCharacteristic: self)
    }
    
    private func readValueForCharacteristic() {
        self.service?.peripheral?.readValueForCharacteristic(self)
    }
    
    private func writeValue(value: NSData, type: CBCharacteristicWriteType = .WithResponse) {
        self.service?.peripheral?.writeValue(value, forCharacteristic: self, type: type)
    }

    // MARK: Utilities
    private func writeNext() {
        guard let parameters = self.writeParameters.first where self.writing == false else {
            return
        }
        BCLogger.debug("write characteristic value=\(parameters.value.hexStringValue()), uuid=\(self.uuid.UUIDString)")
        self.writeParameters.removeAtIndex(0)
        self.writing = true
        self.writeValue(parameters.value, type: parameters.type)
        ++self.writeSequence
        self.timeoutWrite(self.writeSequence, timeout: parameters.timeout)
    }
    
    private func readNext() {
        guard let parameters = self.readParameters.first where self.reading == false else {
            return
        }
        BCLogger.debug("read characteristic \(self.uuid.UUIDString)")
        self.readParameters.removeAtIndex(0)
        self.readValueForCharacteristic()
        self.reading = true
        ++self.readSequence
        self.timeoutRead(self.readSequence, timeout: parameters.timeout)
    }
    
    private func shiftPromise(inout promises: BCSerialIOArray<Promise<BCCharacteristic>>) -> Promise<BCCharacteristic>? {
        if let item = promises.first {
            promises.removeAtIndex(0)
            return item
        } else {
            return nil
        }
    }
}
