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
    func testBufferProfilesScaleLatencyAndPreserveConfigurationDefaults() throws {
        for rate in LDACSampleRate.allCases {
            for quality in LDACQuality.allCases {
                for profile in LDACBufferProfile.allCases {
                    var configuration = LDACConfiguration(sampleRate: rate, quality: quality)
                    configuration.bufferProfile = profile
                    configuration.customReserveMilliseconds = 400
                    let milliseconds = profile == .music ? 250 : profile == .video ? 100 : 400
                    XCTAssertEqual(configuration.pcmReserveFrames, rate.rawValue * milliseconds / 1000)
                    XCTAssertEqual(LDACPipelineLatency(configuration: configuration).reserveFrames, configuration.pcmReserveFrames)
                    XCTAssertEqual(configuration.mediaArguments.suffix(2), ["--pcm-reserve-ms", String(milliseconds)])
                    XCTAssertEqual(try JSONDecoder().decode(LDACConfiguration.self, from: JSONEncoder().encode(configuration)), configuration)
                }
            }
        }
        XCTAssertEqual(LDACBufferProfile.custom.reserveMilliseconds(custom: -1), 50)
        XCTAssertEqual(LDACBufferProfile.custom.reserveMilliseconds(custom: 900), 500)
        let configuration = try JSONDecoder().decode(LDACConfiguration.self, from: Data(#"{"sampleRate":48000,"quality":"low"}"#.utf8))
        XCTAssertEqual(configuration.microphonePolicy, .headset)
        XCTAssertEqual(configuration.bufferProfile, .music)
        XCTAssertFalse(configuration.routing.isSelective)
    }

    func testApplicationRoutingCannotFallBackToSystemCaptureWhenSelectionIsEmpty() throws {
        var routing = LDACApplicationRouting()
        XCTAssertTrue(routing.isValid)
        routing.enabled = true
        XCTAssertFalse(routing.isValid)
        routing.outputDeviceUID = "built-in-output"
        XCTAssertFalse(routing.isValid)
        routing.bundleIDs = ["com.apple.Music", "com.apple.Safari"]
        XCTAssertTrue(routing.isValid)
        routing.bundleIDs.append("com.apple.Music")
        XCTAssertFalse(routing.isValid)
        routing.bundleIDs = ["dev.baglayan.Acouplet.ldac-audio"]
        XCTAssertFalse(routing.isValid)
        routing.bundleIDs = ["com.test.\ninvalid"]
        XCTAssertFalse(routing.isValid)
        routing.bundleIDs = (0..<33).map { "com.test.application\($0)" }
        XCTAssertFalse(routing.isValid)
        var configuration = LDACConfiguration()
        configuration.routing = routing
        XCTAssertThrowsError(try JSONDecoder().decode(LDACConfiguration.self, from: JSONEncoder().encode(configuration)))
    }

    func testTransportHealthRejectsMalformedMetricsAndExportsRedactedIdentifiers() {
        var health = LDACTransportHealth()
        XCTAssertTrue(health.observe("LIVE_PROGRESS skippedFrames=128 bufferedFrames=12000"))
        XCTAssertTrue(health.observe("QUEUE_STATS peakMs=40 queuedMs=12 totalSkippedFrames=256"))
        XCTAssertTrue(health.observe("DRAIN_BREACH first=1"))
        XCTAssertTrue(health.observe("DRAIN_BREACH first=0"))
        XCTAssertTrue(health.observe("PCM_UNDERRUN bufferedFrames=0"))
        XCTAssertEqual(health.skippedFrames, 256)
        XCTAssertEqual(health.queuedMilliseconds, 12)
        XCTAssertEqual(health.peakQueuedMilliseconds, 40)
        XCTAssertEqual(health.stalls, 1)
        XCTAssertEqual(health.underruns, 1)
        let previous = health
        for malformed in ["LIVE_PROGRESS skippedFrames=-1 bufferedFrames=0", "QUEUE_STATS peakMs=nan queuedMs=inf",
                          "LIVE_PROGRESS skippedFrames=18446744073709551615 bufferedFrames=0", "QUEUE_STATS peakMs=999999999"] {
            XCTAssertFalse(health.observe(malformed))
            XCTAssertEqual(health, previous)
        }
        let redacted = LDACDiagnosticReport.redacted("address=AA:BB:CC:DD:EE:FF pid=123 uid=secret /Users/sarah/data 12345678-1234-1234-1234-123456789abc")
        for secret in ["AA:BB", "pid=123", "uid=secret", "sarah", "12345678-1234"] { XCTAssertFalse(redacted.contains(secret)) }
        XCTAssertTrue(LDACRuntimeStatus.supports(major: 15, minor: 4))
        XCTAssertFalse(LDACRuntimeStatus.supports(major: 15, minor: 3))
        XCTAssertTrue(LDACRuntimeStatus.supports(major: 27, minor: 2))
        XCTAssertFalse(LDACRuntimeStatus.supports(major: 28, minor: 0))
    }

    func testDiagnosticReportFilenameIncludesTimestamp() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(LDACDiagnosticReport.filename(at: date, timeZone: timeZone),
                       "Acouplet-LDAC-report-2023-11-14-221320.json")
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
