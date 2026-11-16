import CoreAudio
import Foundation

func audioProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> T {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<T>.size)
    let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { value.deallocate() }
    try checkAudio(AudioObjectGetPropertyData(object, &address, 0, nil, &size, value))
    return value.move()
}

func checkAudio(_ status: OSStatus) throws {
    guard status == noErr else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}

/// A private aggregate device reading `tap`, clocked by (and able to play to) the default output device.
func makeTapAggregateDevice(name: String, tap: UUID) throws -> AudioObjectID {
    let outputID: AudioObjectID = try audioProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
    let outputUID: CFString = try audioProperty(outputID, kAudioDevicePropertyDeviceUID)

    let aggregate: [String: Any] = [
        kAudioAggregateDeviceNameKey: name,
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceMainSubDeviceKey: outputUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
        kAudioAggregateDeviceTapListKey: [[
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapUIDKey: tap.uuidString,
        ]],
    ]
    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    try checkAudio(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))
    return aggregateID
}
