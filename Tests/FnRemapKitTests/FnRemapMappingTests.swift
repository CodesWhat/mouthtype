import FnRemapKit
import Foundation
import Testing

@Suite struct FnRemapMappingTests {
    private let ours = FnRemapMapping.entry()
    private let capsToEscape: FnRemapMapping.Entry = [FnRemapMapping.srcKey: 0x7_0000_0039, FnRemapMapping.dstKey: 0x7_0000_0029]

    @Test func usageValuesAreThePageShiftedLeft32() {
        #expect(FnRemapMapping.fnSource == 0xFF_0000_0003)
        #expect(FnRemapMapping.fnDestination == 0x7_0000_006E)
        #expect(ours == [FnRemapMapping.srcKey: 0xFF_0000_0003, FnRemapMapping.dstKey: 0x7_0000_006E])
    }

    @Test func mergeKeepsTheUsersMapping() {
        #expect(FnRemapMapping.merging(existing: [capsToEscape], ours: ours) == [capsToEscape, ours])
        #expect(FnRemapMapping.merging(existing: [], ours: ours) == [ours])
    }

    @Test func mergeDisplacesAnExistingMappingOfTheSameSource() {
        let theirFn: FnRemapMapping.Entry = [FnRemapMapping.srcKey: FnRemapMapping.fnSource, FnRemapMapping.dstKey: 0x7_0000_0039]
        #expect(FnRemapMapping.merging(existing: [theirFn, capsToEscape], ours: ours) == [capsToEscape, ours])
    }

    @Test func restoreRemovesOnlyOurEntry() {
        #expect(FnRemapMapping.restoring(current: [capsToEscape, ours], ours: ours, original: [capsToEscape]) == [capsToEscape])
        #expect(FnRemapMapping.restoring(current: [ours], ours: ours, original: []) == [])
    }

    @Test func restorePutsBackADisplacedEntryAndKeepsLaterAdditions() {
        let theirFn: FnRemapMapping.Entry = [FnRemapMapping.srcKey: FnRemapMapping.fnSource, FnRemapMapping.dstKey: 0x7_0000_0039]
        let addedLater: FnRemapMapping.Entry = [FnRemapMapping.srcKey: 1, FnRemapMapping.dstKey: 2]
        let restored = FnRemapMapping.restoring(current: [capsToEscape, ours, addedLater], ours: ours, original: [theirFn, capsToEscape])
        #expect(restored == [capsToEscape, addedLater, theirFn])
    }
}
