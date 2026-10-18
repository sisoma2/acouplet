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

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    func testPipelineLatencyAcrossEveryRateAndQuality() throws {
        for rate in LDACSampleRate.allCases {
            for quality in LDACQuality.allCases {
                var latency = LDACPipelineLatency(configuration: .init(sampleRate: rate, quality: quality))
                let frame = rate.rawValue > 48000 ? 256 : 128
                let packet = (661 / ((3 - quality.encoderMode) * 110)) * frame
                let initial = UInt32(rate.rawValue / 4 + frame + packet)
                XCTAssertEqual(latency.frames, initial)
                XCTAssertTrue(latency.acceptReceiverReport("DELAY_REPORT value=1000 units=0.1ms"))
                XCTAssertEqual(latency.frames, initial + UInt32(rate.rawValue / 10))
                XCTAssertTrue(latency.acceptReceiverReport("DELAY_REPORT value=1000 units=0.1ms"))
                XCTAssertEqual(latency.frames, initial + UInt32(rate.rawValue / 10))
                for invalid in ["DELAY_REPORT value=-1 units=0.1ms", "DELAY_REPORT value=65535 units=0.1ms",
                                "DELAY_REPORT value=nan units=0.1ms", "DELAY_REPORT value=100 units=ms",
                                "DELAY_REPORT value=100 units=0.1ms extra=1"] {
                    XCTAssertFalse(latency.acceptReceiverReport(invalid))
                }
                latency.offsetMilliseconds = 100
                XCTAssertEqual(latency.frames, initial + UInt32(rate.rawValue / 5))
                latency.offsetMilliseconds = -500
                XCTAssertEqual(latency.frames, 0)
            }
        }
        let old = Data(#"{"sampleRate":44100,"quality":"high"}"#.utf8)
        let configuration = try JSONDecoder().decode(LDACConfiguration.self, from: old)
        XCTAssertEqual(configuration.sampleRate, .hz44100)
        XCTAssertEqual(configuration.quality, .quality)
        XCTAssertEqual(configuration.latencyOffsetMilliseconds, 0)
    }
    #endif

    func testSupportListLineHasModelVersionAndEveryFunctionButNoAddress() {
        let line = SonySupportFunctionsLog.line(generation: "v2", table: 1, model: "WF-C710N",
                                                protocolVersion: 0x03003018, functions: [0xE7, 0x12, 0x0A])
        XCTAssertEqual(line, "MDR support list generation=v2 table=1 model=WF-C710N protocol=03003018 count=3 functions=0A 12 E7")
        XCTAssertTrue(SonySupportFunctionsLog.line(generation: "v1", table: 1, model: "X", protocolVersion: nil, functions: [])
            .hasSuffix("protocol=unknown count=0 functions="))
    }
}
