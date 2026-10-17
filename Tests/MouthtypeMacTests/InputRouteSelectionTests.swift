import CoreAudio
import Testing
@testable import MouthtypeMac

@Suite struct InputRouteSelectionTests {
    private let mic = InputDevice(sampleRate: 48_000, channels: 1, id: 42)

    @Test func explicitInputIgnoresUnrelatedSystemDefaultChanges() {
        let snapshot = DeviceWatcher.Snapshot(defaultInput: 99, isAlive: true, device: mic)
        #expect(HALInput.classify(built: mic, current: snapshot, followsDefault: false) == .none)
        #expect(HALInput.classify(built: mic, current: snapshot, followsDefault: true) == .route)
    }

    @Test func explicitInputStillDetectsLossAndFormatChanges() {
        #expect(HALInput.classify(built: mic, current: .init(defaultInput: 99, isAlive: false, device: mic), followsDefault: false) == .route)
        var changed = mic
        changed.sampleRate = 44_100
        #expect(HALInput.classify(built: mic, current: .init(defaultInput: nil, isAlive: true, device: changed), followsDefault: false) == .format(changed))
        changed.channels = 0
        #expect(HALInput.classify(built: mic, current: .init(defaultInput: 99, isAlive: true, device: changed), followsDefault: false) == .route)
    }
}
