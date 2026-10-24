import Foundation
import XCTest
@testable import Acouplet

final class LDACSupportTests: XCTestCase {
    func testDecisionHasThreeStates() {
        XCTAssertEqual(LDACSupport.decide(modelImpliesLDAC: false, discovered: true), .supported)
        XCTAssertEqual(LDACSupport.decide(modelImpliesLDAC: false, discovered: false), .unsupported)
        XCTAssertEqual(LDACSupport.decide(modelImpliesLDAC: false, discovered: nil), .unknown)
    }

    func testModelThatOffersLDACIsNeverUnsupported() {
        // A DISCOVER taken with multipoint on lists only SBC and AAC for a WH-1000XM4.
        XCTAssertEqual(LDACSupport.decide(modelImpliesLDAC: true, discovered: false), .supported)
        XCTAssertEqual(LDACSupport.decide(modelImpliesLDAC: true, discovered: nil), .supported)
        XCTAssertTrue(SonyDeviceModel.whXM4.offersLDACOnlyWithoutMultipoint)
        XCTAssertFalse(SonyDeviceModel.wfC710N.offersLDACOnlyWithoutMultipoint)
    }

    func testUnsupportedBeatsTheStoredRequest() {
        XCTAssertFalse(LDACSupport.unsupported.allowsStart(requested: true))
        XCTAssertTrue(LDACSupport.unknown.allowsStart(requested: true))
        XCTAssertTrue(LDACSupport.supported.allowsStart(requested: true))
        for support in [LDACSupport.supported, .unsupported, .unknown] {
            XCTAssertFalse(support.allowsStart(requested: false))
        }
    }

    func testStoreKeepsTheLastDiscoverPerAddress() throws {
        let suite = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LDACSupportStore(defaults: defaults)
        XCTAssertNil(store.discovered(forAddress: "AA-BB-CC-DD-EE-01"))
        store.record(false, forAddress: "AA-BB-CC-DD-EE-01")
        store.record(true, forAddress: "AA-BB-CC-DD-EE-02")
        let reopened = LDACSupportStore(defaults: defaults)
        XCTAssertEqual(reopened.discovered(forAddress: "AA-BB-CC-DD-EE-01"), false)
        XCTAssertEqual(reopened.discovered(forAddress: "AA-BB-CC-DD-EE-02"), true)
        store.record(true, forAddress: "AA-BB-CC-DD-EE-01")
        XCTAssertEqual(LDACSupportStore(defaults: defaults).discovered(forAddress: "AA-BB-CC-DD-EE-01"), true)
    }

    func testCapabilityExpiryContextChangesAndExplicitRediscovery() throws {
        let suite = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LDACSupportStore(defaults: defaults)
        let address = "AA-BB-CC-DD-EE-01"
        let now = Date(timeIntervalSince1970: 100000)
        let context = LDACCapabilityContext(firmware: "1.0", connectionMode: "soundQuality", multipoint: false)
        defaults.set([address: false], forKey: LDACSupportStore.key)
        XCTAssertNil(store.discovered(forAddress: address))
        store.record(false, forAddress: address, context: context, now: now)
        XCTAssertEqual(store.discovered(forAddress: address, context: context, now: now), false)
        XCTAssertNil(store.discovered(forAddress: address, context: context, now: now.addingTimeInterval(86400)))
        XCTAssertNil(store.discovered(forAddress: address, context: context, now: now.addingTimeInterval(-1)))
        var changed = context
        changed.firmware = "2.0"
        XCTAssertNil(store.discovered(forAddress: address, context: changed, now: now))
        changed = context
        changed.multipoint = true
        XCTAssertNil(store.discovered(forAddress: address, context: changed, now: now))
        changed = context
        changed.connectionMode = "stableConnection"
        changed.endpointMayBeHidden = true
        store.record(false, forAddress: address, context: changed, now: now)
        XCTAssertNil(store.discovered(forAddress: address, context: changed, now: now))
        store.record(true, forAddress: "AA-BB-CC-DD-EE-02", context: context, now: now)
        store.clear(forAddress: address)
        XCTAssertNil(store.discovered(forAddress: address, context: context, now: now))
        XCTAssertEqual(store.discovered(forAddress: "aa:bb:cc:dd:ee:02", context: context, now: now), true)
        store.record(true, forAddress: address, context: context, now: now)
        let observed = store.discovered(forAddress: address, context: context, now: now)
        XCTAssertTrue(LDACSupport.decide(modelImpliesLDAC: false, discovered: observed).allowsStart(requested: true))
    }

    func testAdvertisedRatesAndChannelMasksAreUsedForAdmission() throws {
        let context = LDACCapabilityContext()
        let suite = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LDACSupportStore(defaults: defaults)
        store.recordCapabilities(rates: 0x10, channels: 1, forAddress: "AA-BB-CC-DD-EE-01", context: context)
        let record = try XCTUnwrap(store.all["AA:BB:CC:DD:EE:01"])
        XCTAssertEqual(record.supports(sampleRate: 48000), true)
        XCTAssertEqual(record.supports(sampleRate: 44100), false)
        store.recordCapabilities(rates: 0x20, channels: 1, forAddress: "AA-BB-CC-DD-EE-01", context: context)
        XCTAssertEqual(store.all["AA:BB:CC:DD:EE:01"]?.supports(sampleRate: 44100), true)
    }
}
