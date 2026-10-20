import Foundation
import ServiceManagement
import XCTest
@testable import Acouplet

final class SettingsStoreTests: XCTestCase {
    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @MainActor
    func testLDACProfilesMigrateGlobalSettingsAndKeepSuccessfulFixedChoices() throws {
        let suite = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = SettingsStore(defaults: defaults)
        initial.ldacConfiguration = LDACConfiguration(sampleRate: .hz44100, quality: .quality)
        let settings = SettingsStore(defaults: defaults)
        let first = "AA:BB:CC:DD:EE:01"
        let second = "AA:BB:CC:DD:EE:02"
        XCTAssertEqual(settings.ldacProfile(forAddress: first).configuration.quality, .quality)
        XCTAssertTrue(settings.ldacProfile(forAddress: first).automaticallyEnable)
        settings.selectLDACDevice(address: first)
        settings.ldacConfiguration.sampleRate = .hz96000
        settings.recordLDACSuccess(forAddress: first, configuration: settings.ldacConfiguration)
        settings.ldacConfiguration.quality = .balanced
        settings.recordLDACFailure(forAddress: first)
        settings.recordLDACFailure(forAddress: first)
        XCTAssertEqual(settings.ldacConfiguration(forAddress: first).quality, .balanced)
        XCTAssertEqual(settings.ldacProfile(forAddress: first).consecutiveFailures, 2)
        settings.selectLDACDevice(address: second)
        XCTAssertEqual(settings.ldacConfiguration.sampleRate, .hz44100)
        settings.applyLDACPreset(.video, forAddress: second)
        XCTAssertEqual(settings.ldacConfiguration.bufferProfile, .video)
        XCTAssertEqual(settings.ldacConfiguration.quality, .adaptive)
        settings.updateLDACProfile(forAddress: first) { $0.automaticallyEnable = false }
        defaults.set([first: true], forKey: "ldac.codecPreferences")
        let reopened = SettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.ldacConfiguration(forAddress: first).sampleRate, .hz96000)
        XCTAssertEqual(reopened.ldacConfiguration(forAddress: second).bufferProfile, .video)
        XCTAssertTrue(reopened.ldacProfile(forAddress: second).automaticallyEnable)
        XCTAssertFalse(reopened.ldacProfile(forAddress: first).automaticallyEnable)
        reopened.useLastSuccessfulLDACConfiguration(forAddress: first)
        XCTAssertEqual(reopened.ldacConfiguration(forAddress: first).quality, .quality)
        XCTAssertEqual(reopened.ldacProfile(forAddress: first).consecutiveFailures, 0)
    }

    @MainActor
    func testPreviouslyEnabledLDACProfilesMigrateWithoutLosingConfigurationOrLaterOptOuts() throws {
        let suite = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let enabled = "AA:BB:CC:DD:EE:01"
        let disabled = "AA:BB:CC:DD:EE:02"
        let untouched = "AA:BB:CC:DD:EE:03"
        var profile = LDACDeviceProfile(configuration: LDACConfiguration(sampleRate: .hz96000, quality: .quality))
        profile.automaticallyEnable = false
        profile.lastSuccessfulConfiguration = profile.configuration
        defaults.set(try JSONEncoder().encode([enabled: profile, disabled: profile, untouched: profile]),
                     forKey: "preferences.ldacDeviceProfiles")
        defaults.set([enabled: true, disabled: false], forKey: "ldac.codecPreferences")

        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.automaticLDACConfiguration(forAddress: enabled), profile.configuration)
        XCTAssertEqual(settings.ldacProfile(forAddress: enabled).lastSuccessfulConfiguration, profile.configuration)
        XCTAssertNil(settings.automaticLDACConfiguration(forAddress: disabled))
        XCTAssertNil(settings.automaticLDACConfiguration(forAddress: untouched))
        XCTAssertEqual(defaults.dictionary(forKey: "ldac.codecPreferences")?[disabled] as? Bool, false)
        XCTAssertTrue(SettingsStore(defaults: defaults).ldacProfile(forAddress: enabled).automaticallyEnable)

        settings.updateLDACProfile(forAddress: enabled) { $0.automaticallyEnable = false }
        XCTAssertNil(SettingsStore(defaults: defaults).automaticLDACConfiguration(forAddress: enabled))
    }

    @MainActor
    func testNewDeviceProfileDoesNotInheritAnotherDevicesSettings() throws {
        let suite = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.selectLDACDevice(address: "AA:BB:CC:DD:EE:01")
        settings.ldacConfiguration.sampleRate = .hz96000
        settings.ldacConfiguration.microphonePolicy = .manual
        settings.selectLDACDevice(address: "AA:BB:CC:DD:EE:02")
        XCTAssertEqual(settings.ldacConfiguration, LDACConfiguration())
    }

    @MainActor
    func testPerDeviceLatencyCalibrationPersistsAndIsBounded() throws {
        let suite = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.setLDACLatencyOffset(120, forAddress: "AA-BB-CC-DD-EE-01")
        settings.setLDACLatencyOffset(-900, forAddress: "AA-BB-CC-DD-EE-02")
        let reopened = SettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.ldacConfiguration(forAddress: "aa:bb:cc:dd:ee:01").latencyOffsetMilliseconds, 120)
        XCTAssertEqual(reopened.ldacConfiguration(forAddress: "AA-BB-CC-DD-EE-02").latencyOffsetMilliseconds, -500)
        XCTAssertEqual(reopened.ldacConfiguration(forAddress: "AA-BB-CC-DD-EE-03").latencyOffsetMilliseconds, 0)
    }
    #endif

    @MainActor
    func testAppLanguageUsesOnlyItsOwnDomainAndRestoresSystemDefault() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let inheritedName = suiteName + ".inherited"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let inherited = try XCTUnwrap(UserDefaults(suiteName: inheritedName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            inherited.removePersistentDomain(forName: inheritedName)
        }
        inherited.set(["tr"], forKey: "AppleLanguages")
        defaults.addSuite(named: inheritedName)
        let inheritedLanguages = defaults.stringArray(forKey: "AppleLanguages")
        XCTAssertNotNil(inheritedLanguages)
        let settings = SettingsStore(defaults: defaults, preferencesDomain: suiteName)
        XCTAssertEqual(settings.appLanguage, .system)
        XCTAssertFalse(settings.appLanguageNeedsRestart)
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"])

        for language in [AppLanguage.english, .turkish] {
            settings.setAppLanguage(language)
            XCTAssertEqual(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] as? [String], [language.rawValue])
            XCTAssertTrue(settings.appLanguageNeedsRestart)
            let reopened = SettingsStore(defaults: defaults, preferencesDomain: suiteName)
            XCTAssertEqual(reopened.appLanguage, language)
            XCTAssertFalse(reopened.appLanguageNeedsRestart)
        }

        settings.setAppLanguage(.system)
        XCTAssertFalse(settings.appLanguageNeedsRestart)
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"])
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), inheritedLanguages)
        XCTAssertEqual(inherited.persistentDomain(forName: inheritedName)?["AppleLanguages"] as? [String], ["tr"])
    }

    @MainActor
    func testAppLanguagePreservesRegionalOverridesAndRefreshesExternalChanges() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["tr-TR", "en-GB"], forKey: "AppleLanguages")
        let settings = SettingsStore(defaults: defaults, preferencesDomain: suiteName)
        XCTAssertEqual(settings.appLanguage, .turkish)
        XCTAssertEqual(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] as? [String], ["tr-TR", "en-GB"])
        XCTAssertFalse(settings.appLanguageNeedsRestart)

        defaults.set(["en-GB"], forKey: "AppleLanguages")
        settings.refreshAppLanguage()
        XCTAssertEqual(settings.appLanguage, .english)
        XCTAssertTrue(settings.appLanguageNeedsRestart)
        XCTAssertEqual(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] as? [String], ["en-GB"])
        settings.setAppLanguage(.turkish)
        XCTAssertFalse(settings.appLanguageNeedsRestart)

        defaults.removeObject(forKey: "AppleLanguages")
        settings.refreshAppLanguage()
        XCTAssertEqual(settings.appLanguage, .system)
        XCTAssertTrue(settings.appLanguageNeedsRestart)
    }

    @MainActor
    func testAppLanguageHandlesInvalidPreferencesWithoutRewritingThem() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("tr", forKey: "AppleLanguages")
        let original = defaults.persistentDomain(forName: suiteName) as NSDictionary?
        let settings = SettingsStore(defaults: defaults, preferencesDomain: suiteName)
        XCTAssertEqual(settings.appLanguage, .system)
        XCTAssertEqual(defaults.persistentDomain(forName: suiteName) as NSDictionary?, original)
        XCTAssertEqual(AppLanguage(preferredLanguages: []), .system)
        XCTAssertEqual(AppLanguage(preferredLanguages: ["fr", "tr-TR"]), .turkish)
        XCTAssertEqual(AppLanguage(preferredLanguages: ["fr"]), .english)
    }

    @MainActor
    func testSystemAccentDefaultsOnAndExplicitChoicePersists() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults, preferencesDomain: suiteName)
        XCTAssertTrue(settings.useSystemAccentColor)
        XCTAssertNil(defaults.object(forKey: "preferences.useSystemAccentColor"))
        settings.useSystemAccentColor = false
        XCTAssertFalse(SettingsStore(defaults: defaults, preferencesDomain: suiteName).useSystemAccentColor)
        settings.useSystemAccentColor = true
        XCTAssertTrue(SettingsStore(defaults: defaults, preferencesDomain: suiteName).useSystemAccentColor)
    }

    @MainActor
    func testLegacyPreferencesMigrateOnceWithoutReplacingCurrentValuesOrUpdatePolicy() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let draft = EqualizerSettings(clearBass: 4, bands: [1, 2, 3, 4, 5])
        let profile = SavedEqualizerProfile(id: UUID(), name: "Night", settings: draft)
        let identity = try XCTUnwrap(SonyBLEIdentity.VerifiedDevice(classicAddress: "02:00:00:00:00:01",
                                                                  model: .wfXM5, hash: "12345678", peripheralIdentifier: nil))
        let history = Data("history".utf8)
        let legacy: [String: Any] = [
            "preferences.reconnectAutomatically": false,
            "preferences.showBatteryInMenuBar": true,
            "preferences.customEqualizerDraft": try JSONEncoder().encode(draft),
            "preferences.equalizerProfiles": try JSONEncoder().encode([profile]),
            "headphones.verifiedIdentities": [identity.classicAddress: identity.propertyList],
            "notifications.lowBatteryHistory": history,
            "firmwareUpdate.fixture.notified": "1.2.3",
            "SUEnableAutomaticChecks": false,
            "SUAutomaticallyUpdate": true,
            "SUFeedURL": "https://example.invalid/appcast.xml",
            "SUSkippedVersion": "56",
            "NSWindow Frame about": "old frame",
        ]
        defaults.set(false, forKey: "preferences.showBatteryInMenuBar")
        SettingsStore.migrateLegacyPreferences(from: legacy, to: defaults, bundleIdentifier: "dev.baglayan.Acouplet")
        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.reconnectAutomatically)
        XCTAssertFalse(settings.showBatteryInMenuBar)
        XCTAssertEqual(settings.customEqualizerDraft, draft)
        XCTAssertEqual(settings.equalizerProfiles, [profile])
        XCTAssertEqual(SonyBLEIdentity.savedDevices(in: defaults)[identity.classicAddress], identity)
        XCTAssertEqual(defaults.data(forKey: "notifications.lowBatteryHistory"), history)
        XCTAssertEqual(defaults.string(forKey: "firmwareUpdate.fixture.notified"), "1.2.3")
        XCTAssertEqual(defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool, true)
        for key in ["SUFeedURL", "SUSkippedVersion", "NSWindow Frame about"] {
            XCTAssertNil(defaults.object(forKey: key))
        }
        settings.reconnectAutomatically = true
        defaults.removeObject(forKey: "preferences.equalizerProfiles")
        SettingsStore.migrateLegacyPreferences(from: legacy, to: defaults, bundleIdentifier: "dev.baglayan.Acouplet")
        XCTAssertTrue(SettingsStore(defaults: defaults).reconnectAutomatically)
        XCTAssertTrue(SettingsStore(defaults: defaults).equalizerProfiles.isEmpty)
    }

    @MainActor
    func testLegacyPreferencesDoNotMigrateIntoOtherAppIdentities() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        for identifier in ["dev.baglayan.Acouplet.debug", "example.unrelated", nil] {
            SettingsStore.migrateLegacyPreferences(from: ["preferences.showBatteryInMenuBar": true],
                                                   to: defaults, bundleIdentifier: identifier)
            XCTAssertTrue(defaults.persistentDomain(forName: suiteName)?.isEmpty ?? true)
        }
    }

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    func testLegacyBackgroundServiceMigrationReplacesUnconditionalAndConditionalPolicies() throws {
        for keepAlive: Any in [true, ["SuccessfulExit": false]] {
            let old: [String: Any] = ["Label": LegacyBackgroundService.label,
                                     "ProgramArguments": [LegacyBackgroundService.executablePath, "--background-service"],
                                     "KeepAlive": keepAlive, "StandardErrorPath": "/tmp/acouplet-fixture.log",
                                     "EnvironmentVariables": ["EXISTING_SETTING": "retained"]]
            let data = try PropertyListSerialization.data(fromPropertyList: old, format: .xml, options: 0)
            let migrated = try LegacyBackgroundService.configuration(from: data,
                                                                     executablePath: LegacyBackgroundService.executablePath)
            XCTAssertEqual(migrated["KeepAlive"] as? [String: Bool], ["SuccessfulExit": false])
            XCTAssertEqual(migrated["EnvironmentVariables"] as? [String: String],
                           [LegacyBackgroundService.policyKey: LegacyBackgroundService.policy, "EXISTING_SETTING": "retained"])
            XCTAssertEqual(migrated["StandardErrorPath"] as? String, "/tmp/acouplet-fixture.log")
            XCTAssertEqual(migrated["ProgramArguments"] as? [String],
                           [LegacyBackgroundService.executablePath, "--background-service"])
        }
    }

    func testLegacyBackgroundServiceMigrationRejectsUnrelatedOrOverriddenExecutables() throws {
        let valid: [String: Any] = ["Label": LegacyBackgroundService.label,
                                   "ProgramArguments": [LegacyBackgroundService.executablePath, "--background-service"]]
        for (key, value): (String, Any) in [("Label", "example.unrelated"),
                                           ("ProgramArguments", ["/bin/sh", "--background-service"]),
                                           ("ProgramArguments", [LegacyBackgroundService.executablePath, "--background-service", "--extra"]),
                                           ("Program", "/bin/sh"),
                                           ("EnvironmentVariables", ["INVALID": 1])] {
            var invalid = valid
            invalid[key] = value
            let data = try PropertyListSerialization.data(fromPropertyList: invalid, format: .xml, options: 0)
            XCTAssertThrowsError(try LegacyBackgroundService.configuration(from: data,
                                                                           executablePath: LegacyBackgroundService.executablePath))
        }
    }

    @MainActor
    func testLDACMatrixPreferencesRoundTripAndRejectInvalidFormats() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.ldacConfiguration, LDACConfiguration())
        let expected = [[303, 606, 909, 303], [330, 660, 990, 330], [303, 606, 909, 303], [330, 660, 990, 330]]
        for (rateIndex, rate) in LDACSampleRate.allCases.enumerated() {
            for (qualityIndex, quality) in LDACQuality.allCases.enumerated() {
                let configuration = LDACConfiguration(sampleRate: rate, quality: quality)
                settings.ldacConfiguration = configuration
                XCTAssertEqual(SettingsStore(defaults: defaults).ldacConfiguration, configuration)
                XCTAssertEqual(configuration.bitrateKbps, expected[rateIndex][qualityIndex])
                XCTAssertEqual(configuration.format.sampleRateHz, rate.rawValue)
                XCTAssertEqual(configuration.helperArguments, ["--sample-rate", String(rate.rawValue), "--quality", quality.rawValue])
            }
        }
        for invalid in [#"{"sampleRate":192000,"quality":"high"}"#, #"{"sampleRate":48000,"quality":"unsupported"}"#, "invalid"] {
            defaults.set(Data(invalid.utf8), forKey: "preferences.ldacConfiguration")
            XCTAssertEqual(SettingsStore(defaults: defaults).ldacConfiguration, LDACConfiguration())
        }
    }
    #endif

    @MainActor
    func testLDACDefaultsOnAndExplicitPreferencePersists() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        XCTAssertTrue(settings.experimentalLDACEnabled)
        XCTAssertNil(defaults.object(forKey: "preferences.experimentalLDACEnabled"))
        settings.experimentalLDACEnabled = true
        XCTAssertTrue(SettingsStore(defaults: defaults).experimentalLDACEnabled)
        settings.experimentalLDACEnabled = false
        XCTAssertFalse(SettingsStore(defaults: defaults).experimentalLDACEnabled)
    }

    @MainActor
    func testLaunchAtLoginDefaultMatchesDistributionAndRespectsExplicitChoice() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        settings.enableLaunchAtLoginByDefault()
        #if ACOUPLET_PUBLIC_APIS_ONLY
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertNil(defaults.object(forKey: "preferences.launchAtLoginDefaultApplied"))
        settings.setLaunchAtLogin(true)
        #endif
        XCTAssertTrue(settings.launchAtLogin)
        settings.setLaunchAtLogin(false)
        settings.enableLaunchAtLoginByDefault()
        XCTAssertFalse(settings.launchAtLogin)
        let restored = SettingsStore(defaults: defaults)
        restored.enableLaunchAtLoginByDefault()
        XCTAssertFalse(restored.launchAtLogin)
        defaults.removePersistentDomain(forName: suiteName)
        let optedOut = SettingsStore(defaults: defaults)
        optedOut.setLaunchAtLogin(false)
        optedOut.enableLaunchAtLoginByDefault()
        XCTAssertFalse(optedOut.launchAtLogin)
    }

    @MainActor
    func testLaunchAtLoginDefaultPreservesPriorInstallationAndFreshDistributionDefault() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "migration.legacyPreferences")
        XCTAssertNil(defaults.object(forKey: "preferences.launchAtLoginDefaultApplied"))

        SettingsStore.migrateLegacyPreferences(from: [:], to: defaults, bundleIdentifier: "dev.baglayan.Acouplet")
        let upgraded = SettingsStore(defaults: defaults)
        upgraded.enableLaunchAtLoginByDefault()
        XCTAssertFalse(upgraded.launchAtLogin)
        XCTAssertTrue(upgraded.experimentalLDACEnabled)
        let restored = SettingsStore(defaults: defaults)
        restored.enableLaunchAtLoginByDefault()
        XCTAssertFalse(restored.launchAtLogin)

        defaults.removePersistentDomain(forName: suiteName)
        SettingsStore.migrateLegacyPreferences(from: [:], to: defaults, bundleIdentifier: "dev.baglayan.Acouplet")
        let fresh = SettingsStore(defaults: defaults)
        fresh.enableLaunchAtLoginByDefault()
        #if ACOUPLET_PUBLIC_APIS_ONLY
        XCTAssertFalse(fresh.launchAtLogin)
        #else
        XCTAssertTrue(fresh.launchAtLogin)
        #endif
        XCTAssertTrue(fresh.experimentalLDACEnabled)
    }

    @MainActor
    func testInstallerLoginItemCommandsRunOnlyForTheirArgumentsAndReportRemoval() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = FakeLoginItemService(status: .enabled)

        XCTAssertNil(SettingsStore.runLoginItemCommand(["Acouplet"], defaults: defaults, service: service))
        XCTAssertNil(SettingsStore.runLoginItemCommand(["Acouplet", "--background-service"], defaults: defaults, service: service))
        XCTAssertNil(SettingsStore.runLoginItemCommand(["Acouplet", "--unregister-login-item", "--background-service"],
                                                       defaults: defaults, service: service))
        XCTAssertNil(defaults.object(forKey: "preferences.launchAtLoginDefaultApplied"))
        XCTAssertEqual(service.calls, [])

        XCTAssertEqual(SettingsStore.runLoginItemCommand(["Acouplet", "--unregister-login-item"], defaults: defaults, service: service), EXIT_SUCCESS)
        XCTAssertEqual(service.calls, ["unregister"])
        XCTAssertEqual(service.status, .notRegistered)
        XCTAssertTrue(defaults.bool(forKey: "preferences.launchAtLoginDefaultApplied"))

        XCTAssertEqual(SettingsStore.runLoginItemCommand(["Acouplet", "--unregister-login-item"], defaults: defaults, service: service), EXIT_SUCCESS)
        XCTAssertEqual(service.calls, ["unregister"], "An absent login item is not unregistered again")

        XCTAssertEqual(SettingsStore.runLoginItemCommand(["Acouplet", "--register-login-item"], defaults: defaults, service: service), EXIT_SUCCESS)
        XCTAssertEqual(service.calls, ["unregister", "register"])
        XCTAssertEqual(service.status, .enabled)

        let approval = FakeLoginItemService(status: .requiresApproval)
        XCTAssertEqual(SettingsStore.runLoginItemCommand(["Acouplet", "--unregister-login-item"], defaults: defaults, service: approval), EXIT_SUCCESS)
        XCTAssertEqual(approval.calls, ["unregister"])

        let failing = FakeLoginItemService(status: .enabled, fails: true)
        XCTAssertEqual(SettingsStore.runLoginItemCommand(["Acouplet", "--unregister-login-item"], defaults: defaults, service: failing), EXIT_FAILURE)
        XCTAssertEqual(SettingsStore.runLoginItemCommand(["Acouplet", "--register-login-item"], defaults: defaults, service: failing), EXIT_FAILURE)
    }

    #if canImport(Sparkle)
    func testUpdatesStayOffInDevelopmentBuildsAndWithoutAFeed() {
        let feed = "https://baglayan.dev/updates/appcast.xml"
        XCTAssertTrue(AppUpdater.updatesEnabled(feed: feed, distribution: "production"))
        XCTAssertFalse(AppUpdater.updatesEnabled(feed: feed, distribution: "development"),
                       "A local build of the fork never asks upstream's feed for updates")
        XCTAssertFalse(AppUpdater.updatesEnabled(feed: "", distribution: "production"))
        XCTAssertFalse(AppUpdater.updatesEnabled(feed: nil, distribution: "production"))
        XCTAssertFalse(AppUpdater.updatesEnabled(feed: "", distribution: "development"))
    }

    @MainActor
    func testThisBuildsInfoPlistMatchesItsUpdatePolicy() {
        let info = Bundle.main.infoDictionary ?? [:]
        let distribution = info["AcoupletDistribution"] as? String
        let feed = info["SUFeedURL"] as? String
        XCTAssertEqual(feed, distribution == "development" ? "" : "https://baglayan.dev/updates/appcast.xml")
        XCTAssertEqual(AppUpdater().isEnabled, distribution != "development")
    }
    #endif

    @MainActor
    func testBackgroundServiceModeFollowsThePlistStateNotTheLaunchArguments() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.isBackgroundServiceProcess)
        XCTAssertFalse(settings.hasBackgroundService)
        XCTAssertFalse(settings.launchAtLogin)

        settings.applyLaunchStatus(background: .enabled, launchAtLogin: false)
        XCTAssertTrue(settings.hasBackgroundService, "A copy started without --background-service still sees the installed service")
        settings.applyLaunchStatus(background: .requiresApproval, launchAtLogin: false)
        XCTAssertTrue(settings.hasBackgroundService, "A service turned off in Login Items is still the startup mode")
        settings.applyLaunchStatus(background: .notRegistered, launchAtLogin: true)
        XCTAssertFalse(settings.hasBackgroundService)
        XCTAssertTrue(settings.launchAtLogin)
        settings.applyLaunchStatus(background: .notFound, launchAtLogin: false)
        XCTAssertFalse(settings.hasBackgroundService)
        XCTAssertFalse(settings.launchAtLogin)
    }

    @MainActor
    func testReopeningDoesNotRequestSettings() {
        let delegate = AppDelegate()
        var settingsRequests = 0
        delegate.openSettings = { settingsRequests += 1 }

        XCTAssertFalse(delegate.applicationShouldHandleReopen(.shared, hasVisibleWindows: false))
        XCTAssertFalse(delegate.applicationShouldHandleReopen(.shared, hasVisibleWindows: true))
        XCTAssertEqual(settingsRequests, 0)

        delegate.showSettings()
        XCTAssertEqual(settingsRequests, 1)
    }

    @MainActor
    func testGlobalShortcutConflictRecoversAfterRegistrationIsReleased() throws {
        let first = GlobalHotKeyController {}
        let second = GlobalHotKeyController {}
        guard first.setEnabled(true) == nil else {
            throw XCTSkip("The shortcut is registered outside this isolated test.")
        }
        defer {
            _ = first.setEnabled(false)
            _ = second.setEnabled(false)
        }
        XCTAssertNil(first.setEnabled(true))
        XCTAssertNotNil(second.setEnabled(true))
        XCTAssertNil(second.setEnabled(false))
        XCTAssertNil(first.setEnabled(false))
        XCTAssertNil(second.setEnabled(true))
    }

    @MainActor
    func testPresetNamePreflightMatchesSavedNamesAndPreservesReplacementIdentity() {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        for proposedName in ["  Night\n", String(repeating: "a", count: 40), "  "] {
            let expectedName = settings.equalizerProfileName(for: proposedName)
            XCTAssertEqual(settings.saveEqualizerProfile(named: proposedName).name, expectedName)
        }
        let original = settings.equalizerProfiles[0]
        let name = settings.equalizerProfileName(for: " NIGHT ")
        XCTAssertEqual(settings.equalizerProfiles.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }?.id, original.id)
        XCTAssertEqual(SettingsStore(defaults: defaults).equalizerProfiles[0], original)
        settings.customEqualizerDraft = EqualizerSettings(clearBass: 4, bands: [1, 2, 3, 4, 5])
        let replacement = settings.saveEqualizerProfile(named: name)
        XCTAssertEqual(replacement.id, original.id)
        XCTAssertEqual(replacement.settings, settings.customEqualizerDraft)
        settings.deleteEqualizerProfile(id: replacement.id)
        XCTAssertFalse(SettingsStore(defaults: defaults).equalizerProfiles.contains { $0.id == original.id })
    }

    @MainActor
    func testAutomaticPresetNamesReuseUnusedNumbersWithoutReplacingExistingProfiles() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        let first = settings.saveEqualizerProfile(named: "")
        let second = settings.saveEqualizerProfile(named: "")
        let third = settings.saveEqualizerProfile(named: "")
        settings.deleteEqualizerProfile(id: second.id)
        XCTAssertEqual(settings.equalizerProfileName(for: "  "), second.name)
        let replacement = settings.saveEqualizerProfile(named: "  ")
        XCTAssertEqual(replacement.name, second.name)
        XCTAssertNotEqual(replacement.id, second.id)
        XCTAssertEqual(settings.equalizerProfiles, [first, third, replacement])
        let fourthName = String(localized: "My EQ \(4)")
        settings.saveEqualizerProfile(named: fourthName.lowercased())
        XCTAssertEqual(settings.equalizerProfileName(for: ""), String(localized: "My EQ \(5)"))
    }

    @MainActor
    func testRestoredEqualizerNormalizesBandCountAndLevels() {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data(#"{"clearBass":99,"bands":[-99,4]}"#.utf8), forKey: "preferences.customEqualizerDraft")

        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.customEqualizerDraft, EqualizerSettings(clearBass: 10, bands: [-10, 4, 0, 0, 0]))
        XCTAssertEqual(restored.customEqualizerDraft[band: 4], 0)
    }

    @MainActor
    func testEqualizerDraftsRemainIndependentAcrossDevicesAndRelaunches() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        let first = "02:00:00:00:00:01"
        let second = "02:00:00:00:00:02"
        let firstDraft = EqualizerSettings(clearBass: 4, bands: [1, 2, 3, 4, 5])
        let secondDraft = EqualizerSettings(clearBass: -2, bands: [0, -1, -2, -3, -4])
        settings.customEqualizerDraft = firstDraft
        settings.selectEqualizerDevice(address: first, defaultDraft: .flat)
        XCTAssertEqual(settings.customEqualizerDraft, firstDraft)
        settings.selectEqualizerDevice(address: second, defaultDraft: secondDraft)
        XCTAssertEqual(settings.customEqualizerDraft, secondDraft)
        settings.selectEqualizerDevice(address: first, defaultDraft: .flat)
        XCTAssertEqual(settings.customEqualizerDraft, firstDraft)
        settings.selectEqualizerDevice(address: first.replacingOccurrences(of: ":", with: "-"), defaultDraft: secondDraft)
        XCTAssertEqual(settings.customEqualizerDraft, firstDraft)
        let restored = SettingsStore(defaults: defaults)
        restored.selectEqualizerDevice(address: second, defaultDraft: .flat)
        XCTAssertEqual(restored.customEqualizerDraft, secondDraft)
        restored.selectEqualizerDevice(address: first, defaultDraft: .flat)
        XCTAssertEqual(restored.customEqualizerDraft, firstDraft)
    }

    @MainActor
    func testNewEqualizerDraftWaitsForReadbackAcrossSelectionsAndRelaunches() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = "02:00:00:00:00:01"
        let second = "02:00:00:00:00:02"
        let curve = EqualizerSettings(clearBass: 4, bands: [1, 2, 3, 4, 5])
        let settings = SettingsStore(defaults: defaults)
        settings.selectEqualizerDevice(address: first, defaultDraft: nil)
        settings.selectEqualizerDevice(address: second, defaultDraft: nil)
        settings.selectEqualizerDevice(address: first, defaultDraft: nil)
        XCTAssertEqual(settings.customEqualizerDraft, .flat)
        XCTAssertNil(defaults.data(forKey: "preferences.equalizerDraftsByDevice"))
        let restored = SettingsStore(defaults: defaults)
        restored.selectEqualizerDevice(address: first, defaultDraft: nil)
        restored.selectEqualizerDevice(address: first, defaultDraft: curve)
        XCTAssertEqual(restored.customEqualizerDraft, curve)
        restored.selectEqualizerDevice(address: first, defaultDraft: .flat)
        XCTAssertEqual(restored.customEqualizerDraft, curve)
        let relaunched = SettingsStore(defaults: defaults)
        relaunched.selectEqualizerDevice(address: first, defaultDraft: .flat)
        XCTAssertEqual(relaunched.customEqualizerDraft, curve)
    }

    @MainActor
    func testEditingProvisionalEqualizerDraftPreservesItWhenReadbackArrives() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let address = "02:00:00:00:00:01"
        let incoming = EqualizerSettings(layout: SonyEqualizerBand.tenBand, levelSteps: 13,
                                         values: Array(repeating: 2, count: 10))
        for edited in [EqualizerSettings.flat, EqualizerSettings(clearBass: 4, bands: [1, 2, 3, 4, 5])] {
            defaults.removePersistentDomain(forName: suiteName)
            let settings = SettingsStore(defaults: defaults)
            settings.selectEqualizerDevice(address: address, defaultDraft: nil)
            settings.customEqualizerDraft = edited
            settings.selectEqualizerDevice(address: address, defaultDraft: incoming)
            XCTAssertEqual(settings.customEqualizerDraft, edited)
            let restored = SettingsStore(defaults: defaults)
            restored.selectEqualizerDevice(address: address, defaultDraft: incoming)
            XCTAssertEqual(restored.customEqualizerDraft, edited)
        }
    }

    @MainActor
    func testEnvironmentSeedsOnlyTheFirstReceivedEqualizerCurveForTheSelectedDevice() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        defer { controller.simulateControlLoss() }
        let environment = AppEnvironment(settings: SettingsStore(defaults: defaults), headphones: controller,
                                         audioRoute: MacAudioRouteObserver(startAutomatically: false))
        XCTAssertNil(controller.equalizer.settings)
        XCTAssertNil(defaults.data(forKey: "preferences.equalizerDraftsByDevice"))
        let curve = EqualizerSettings(clearBass: 4, bands: [1, 2, 3, 4, 5])
        controller.simulateProtocolMessage([0x59] + curve.sonySetPayload.dropFirst())
        XCTAssertEqual(controller.equalizer.settings, curve)
        XCTAssertEqual(environment.settings.customEqualizerDraft, curve)
        environment.settings.customEqualizerDraft = .flat
        let changedCurve = EqualizerSettings(clearBass: -2, bands: [0, -1, -2, -3, -4])
        controller.simulateProtocolMessage([0x59] + changedCurve.sonySetPayload.dropFirst())
        XCTAssertEqual(controller.equalizer.settings, changedCurve)
        XCTAssertEqual(environment.settings.customEqualizerDraft, .flat)
    }

    @MainActor
    func testEnvironmentUsesAdvertisedEqualizerLayoutBeforeFirstCurve() throws {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM6", galleryModel: .wfXM6)
        defer { controller.simulateControlLoss() }
        let environment = AppEnvironment(settings: SettingsStore(defaults: defaults), headphones: controller,
                                         audioRoute: MacAudioRouteObserver(startAutomatically: false))
        let provisional = try XCTUnwrap(controller.equalizer.flatSettings)
        XCTAssertEqual(provisional.layout, SonyEqualizerBand.tenBand)
        XCTAssertEqual(provisional.levelSteps, 13)
        XCTAssertNil(controller.equalizer.settings)
        XCTAssertEqual(environment.settings.customEqualizerDraft, provisional)
        XCTAssertNil(defaults.data(forKey: "preferences.equalizerDraftsByDevice"))
        var received = provisional
        received.values = Array(repeating: 2, count: 10)
        let payload = try XCTUnwrap(controller.equalizer.settingsPayload(received))
        controller.simulateProtocolMessage([0x59] + payload.dropFirst())
        XCTAssertEqual(controller.equalizer.settings, received)
        XCTAssertEqual(environment.settings.customEqualizerDraft, received)
    }

    @MainActor
    func testMultipointSourcesWithTheSameNameRemainDistinguishable() {
        let first = SonyMultipointDevice(address: "02:00:00:00:00:01", connectionID: 1, classOfDevice: 0, name: "MacBook Pro")
        let second = SonyMultipointDevice(address: "02:00:00:00:00:02", connectionID: 2, classOfDevice: 0, name: "macbook pro")
        XCTAssertEqual(MultipointControls.title(for: first, among: [first]), first.name)
        XCTAssertEqual(MultipointControls.title(for: first, among: [first, second]), "MacBook Pro · 02:00:00:00:00:01")
        XCTAssertEqual(MultipointControls.title(for: second, among: [first, second]), "macbook pro · 02:00:00:00:00:02")
    }

    @MainActor
    func testDefaultsAndPersistence() {
        let suiteName = "dev.baglayan.Acouplet.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.keepMenuBarIconWhenDisconnected)
        settings.keepMenuBarIconWhenDisconnected = true
        XCTAssertTrue(SettingsStore(defaults: defaults).keepMenuBarIconWhenDisconnected)
        settings.keepMenuBarIconWhenDisconnected = false
        XCTAssertFalse(SettingsStore(defaults: defaults).keepMenuBarIconWhenDisconnected)
        XCTAssertFalse(settings.showBatteryInMenuBar)
        settings.showBatteryInMenuBar = true
        XCTAssertTrue(SettingsStore(defaults: defaults).showBatteryInMenuBar)
        XCTAssertTrue(settings.reconnectAutomatically)
        XCTAssertFalse(settings.globalShortcutEnabled, "The system-wide shortcut stays off until someone turns it on")
        XCTAssertNil(defaults.object(forKey: "preferences.globalShortcutEnabled"))
        XCTAssertEqual(settings.customEqualizerDraft, .flat)
        settings.globalShortcutEnabled = true
        XCTAssertTrue(SettingsStore(defaults: defaults).globalShortcutEnabled, "A shortcut turned on deliberately stays on")

        settings.reconnectAutomatically = false
        settings.globalShortcutEnabled = false
        settings.customEqualizerDraft = EqualizerSettings(clearBass: 4, bands: [1, 2, 3, 4, 5])
        let profile = settings.saveEqualizerProfile(named: "Night")

        XCTAssertFalse(SettingsStore(defaults: defaults).reconnectAutomatically)
        XCTAssertFalse(SettingsStore(defaults: defaults).globalShortcutEnabled)
        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.customEqualizerDraft, settings.customEqualizerDraft)
        XCTAssertEqual(restored.equalizerProfiles, [profile])
    }
}

private final class FakeLoginItemService: LoginItemService {
    private(set) var status: SMAppService.Status
    private(set) var calls: [String] = []
    private let fails: Bool

    init(status: SMAppService.Status, fails: Bool = false) {
        self.status = status
        self.fails = fails
    }

    func register() throws {
        guard !fails else { throw CocoaError(.featureUnsupported) }
        calls.append("register")
        status = .enabled
    }

    func unregister() throws {
        guard !fails else { throw CocoaError(.featureUnsupported) }
        calls.append("unregister")
        status = .notRegistered
    }
}
