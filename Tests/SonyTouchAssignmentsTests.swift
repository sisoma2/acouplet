import XCTest
@testable import Acouplet

final class SonyTouchAssignmentsTests: XCTestCase {
    func testLegacyFixedPresetsPreserveCapabilityOrderAndEveryOtherSelection() throws {
        for order: [UInt8] in [[0, 1], [1, 0]] {
            var assignments = SonyTouchAssignments(supportedFunctions: [0xF6], generation: .v1)
            XCTAssertEqual(assignments.queryPayloads, [[0xF0, 6], [0xF2, 6], [0xF6, 6]])
            XCTAssertTrue(assignments.update(syntheticLegacyTouchCapability(keys: order)))
            XCTAssertEqual(assignments.keys?.map(\.key), order)
            XCTAssertTrue(assignments.hasKnownCapability)
            XCTAssertNil(assignments.selectedPresets)
            XCTAssertNil(assignments.setPayload(key: 0, preset: 0x10))
            let selection: [UInt8] = order.map { $0 == 0 ? 0 : 0x20 }
            XCTAssertTrue(assignments.update([0xF3, 6, 2, 0, 0]))
            XCTAssertTrue(assignments.update([0xF7, 6, 2] + selection))
            let before = assignments
            for preset: UInt8 in [0x10, 0x30, 0x31, 0x32, 0x33, 0xFF] {
                XCTAssertEqual(assignments.setPayload(key: 0, preset: preset),
                               [0xF8, 6, 2] + order.map { $0 == 0 ? preset : 0x20 })
            }
            XCTAssertEqual(assignments, before)
            XCTAssertEqual(assignments.reportedActions(key: 0)?.map(\.function), [1, 2])
            XCTAssertTrue(try XCTUnwrap(assignments.keys).allSatisfy { $0.presets.allSatisfy { $0.customizableActions.isEmpty } })
            XCTAssertEqual(assignments.queryPayloads, [[0xF2, 6], [0xF6, 6]])
            XCTAssertNil(assignments.setActionPayload(key: 0, action: 0, function: 1))
            for command: UInt8 in [0xFB, 0xFD] {
                XCTAssertFalse(assignments.update([command, 6, 1, 0, 1, 0, 1]))
            }
            XCTAssertEqual(assignments, before)
        }
    }

    func testLegacyAssignmentCaptionsNeverAcquireModernFunctionMeanings() throws {
        let meanings: [(UInt8, String, String)] = [
            (2, "Noise Cancelling Optimizer", "Noise Cancelling / Ambient Sound"),
            (0x11, "Volume up", "Noise Cancelling Optimizer"),
            (0x12, "Volume down", "Unknown function"),
        ]
        for (function, legacy, modern) in meanings {
            let action = SonyTouchActionSetting(action: 0, function: function)
            XCTAssertEqual(action.functionTitle(generation: .v1), legacy)
            XCTAssertEqual(action.functionTitle, modern)
            XCTAssertEqual(action.function, function)
        }
        XCTAssertEqual(SonyTouchActionSetting(action: 3, function: 3).gestureTitle(keyType: 0, generation: .v1), "Unknown gesture")
        XCTAssertEqual(SonyTouchActionSetting(action: 3, function: 3).functionTitle(generation: .v1), "Unknown function")
        XCTAssertEqual(SonyTouchActionSetting(action: 0, function: 0x23).functionTitle(generation: .v1), "Unknown function")
        XCTAssertEqual(SonyTouchActionSetting(action: 0x10, function: 0x34).functionTitle(generation: .v1), "Talk to / Cancel Amazon Alexa")
        var button = SonyTouchAssignments(supportedFunctions: [0xF6], generation: .v1)
        XCTAssertTrue(button.update(syntheticLegacyTouchCapability(keys: [2], keyType: 1)))
        let key = try XCTUnwrap(button.keys?.first)
        XCTAssertEqual(key.title(generation: .v1), "Custom button")
        XCTAssertEqual(key.presets.last?.title(generation: .v1), "No Function")
        XCTAssertEqual(key.presets.first?.fixedActions.last?.gestureTitle(keyType: key.keyType, generation: .v1), "Press and hold")
        XCTAssertNil(SonyTouchAssignments(supportedFunctions: [0xF3, 0xFE], generation: .v1).inquiryType)
        XCTAssertNil(SonyTouchAssignments(supportedFunctions: [0xF6]).inquiryType)
    }

    func testLegacyAssignmentUnknownsAndMalformedListsCannotSupplyWriteDefaults() {
        var assignments = SonyTouchAssignments(supportedFunctions: [0xF6], generation: .v1)
        let capability = syntheticLegacyTouchCapability()
        XCTAssertTrue(assignments.update(capability))
        XCTAssertTrue(assignments.update([0xF3, 6, 2, 0, 0]))
        XCTAssertTrue(assignments.update([0xF7, 6, 2, 0, 0x20]))
        let prior = assignments
        for length in 0..<capability.count {
            XCTAssertFalse(assignments.update(Array(capability.prefix(length))))
            XCTAssertEqual(assignments, prior)
        }
        for payload: [UInt8] in [capability + [0], [0xF3, 6, 2, 0], [0xF7, 6, 1, 0, 0x20],
                                [0xF9, 6, 0], [0xF7, 3, 2, 0, 0x20], [0xF7, 6, 0, 0, 1, 0, 1, 0xFF]] {
            XCTAssertFalse(assignments.update(payload))
            XCTAssertEqual(assignments, prior)
        }
        for index in [3, 4, 5, 7, 9, 10] {
            var changed = capability
            changed[index] = 0xFE
            var unknown = prior
            XCTAssertTrue(unknown.update(changed))
            XCTAssertFalse(unknown.hasKnownCapability)
            XCTAssertNil(unknown.setPayload(key: 0, preset: 0x10))
        }
        var duplicatePreset = capability
        duplicatePreset[13] = 0
        var duplicateAction = capability
        duplicateAction[11] = 0
        for changed in [syntheticLegacyTouchCapability(keys: [0, 0]), duplicatePreset, duplicateAction] {
            var duplicate = prior
            XCTAssertTrue(duplicate.update(changed))
            XCTAssertFalse(duplicate.hasKnownCapability)
            XCTAssertNil(duplicate.setPayload(key: 0, preset: 0x10))
        }
        XCTAssertTrue(assignments.update([0xF5, 6, 2, 0, 1]))
        XCTAssertEqual(assignments.setPayload(key: 0, preset: 0x10), [0xF8, 6, 2, 0x10, 0x20])
        XCTAssertNil(assignments.setPayload(key: 1, preset: 0x10))
        XCTAssertTrue(assignments.update([0xF5, 6, 2, 0, 2]))
        XCTAssertFalse(assignments.hasKnownStatus)
        XCTAssertEqual(assignments.statuses, [0, 2])
        XCTAssertNil(assignments.setPayload(key: 0, preset: 0x10))
        XCTAssertTrue(assignments.update([0xF5, 6, 2, 0, 0]))
        for selection: [UInt8] in [[0], [0, 0xFE], [0, 0x35]] {
            XCTAssertTrue(assignments.update([0xF9, 6, UInt8(selection.count)] + selection))
            XCTAssertEqual(assignments.selectedPresets, selection)
            XCTAssertNil(assignments.setPayload(key: 0, preset: 0x10))
        }
        XCTAssertFalse(assignments.hasKnownSelection)
    }

    func testSupportNegotiationAndCapturedSelectionDoNotInventChoices() {
        var unsupported = SonyTouchAssignments(supportedFunctions: [0xFD, 0x4C])
        XCTAssertNil(unsupported.inquiryType)
        XCTAssertTrue(unsupported.queryPayloads.isEmpty)
        XCTAssertFalse(unsupported.update([0xF7, 0x03, 0x02, 0x35, 0x20]))
        var assignments = SonyTouchAssignments(supportedFunctions: [0xF3, 0xFD])
        XCTAssertEqual(assignments.queryPayloads, [[0xF0, 3], [0xF2, 3], [0xF6, 3]])
        XCTAssertTrue(assignments.update([0xF7, 0x03, 0x02, 0x35, 0x20]))
        XCTAssertEqual(assignments.selectedPresets, [0x35, 0x20])
        XCTAssertNil(assignments.keys)
        XCTAssertNil(assignments.selectedPreset(key: 0))
        XCTAssertNil(assignments.setPayload(key: 0, preset: 0x20))
        XCTAssertTrue(assignments.update([0xF3, 3, 2, 0, 0]))
        XCTAssertNil(assignments.setPayload(key: 0, preset: 0x20))
    }

    func testNestedCapabilityKeepsKeyOrderAndBothCountsBeforeActionArrays() throws {
        var assignments = SonyTouchAssignments(supportedFunctions: [0xF3])
        XCTAssertTrue(assignments.update(syntheticCapability))
        let keys = try XCTUnwrap(assignments.keys)
        XCTAssertEqual(keys.map(\.key), [1, 0])
        XCTAssertEqual(keys.map(\.title), ["Right", "Left"])
        XCTAssertEqual(keys[0].presets.map(\.preset), [0x20, 0x10])
        XCTAssertEqual(keys[1].defaultPreset, 0x35)
        XCTAssertEqual(keys[1].presets.map(\.preset), [0x35, 0xFF])
        let ambient = keys[1].presets[0]
        XCTAssertEqual(ambient.fixedActions, [SonyTouchActionSetting(action: 0, function: 2)])
        XCTAssertEqual(ambient.customizableActions, [SonyTouchCustomizableAction(action: 1, defaultFunction: 0x43, functions: [0x43, 0x44])])
        XCTAssertEqual(assignments.queryPayloads, [[0xF2, 3], [0xF6, 3], [0xFA, 3]])
        XCTAssertNil(assignments.selectedPresets)
        XCTAssertNil(assignments.setPayload(key: 0, preset: 0xFF))
    }

    func testPresetEditPreservesOtherKeyAndReportedCustomActionsWithoutOptimisticMutation() {
        var assignments = readyAssignments()
        XCTAssertTrue(assignments.update([0xFB, 3, 1, 0x35, 1, 1, 0x44]))
        let prior = assignments
        XCTAssertEqual(assignments.selectedPreset(key: 0), 0x35)
        XCTAssertEqual(assignments.selectedPreset(key: 1), 0x20)
        XCTAssertEqual(assignments.setPayload(key: 0, preset: 0xFF), [0xF8, 3, 2, 0x20, 0xFF])
        XCTAssertEqual(assignments.setPayload(key: 1, preset: 0x10), [0xF8, 3, 2, 0x10, 0x35])
        XCTAssertEqual(assignments, prior)
        XCTAssertEqual(assignments.customizedActions, [SonyTouchPresetActions(preset: 0x35, actions: [SonyTouchActionSetting(action: 1, function: 0x44)])])
        XCTAssertNil(assignments.setPayload(key: 0, preset: 0x20))
        XCTAssertNil(assignments.setPayload(key: 1, preset: 0x35))
        XCTAssertNil(assignments.setPayload(key: 2, preset: 0x35))
        XCTAssertTrue(assignments.update([0xF9, 3, 2, 0x20, 0xFF]))
        XCTAssertEqual(assignments.selectedPreset(key: 0), 0xFF)
        XCTAssertEqual(assignments.customizedActions, prior.customizedActions)
        XCTAssertTrue(assignments.update([0xFD, 3, 1, 0x35, 1, 1, 0x43]))
        XCTAssertEqual(assignments.customizedActions?.first?.actions.first?.function, 0x43)
    }

    func testAvailabilityAndMatchingReportedCountsGateFullListWrites() {
        var assignments = readyAssignments()
        XCTAssertTrue(assignments.update([0xF5, 3, 2, 1, 0]))
        XCTAssertFalse(assignments.isAvailable(key: 1))
        XCTAssertTrue(assignments.isAvailable(key: 0))
        XCTAssertNil(assignments.setPayload(key: 1, preset: 0x10))
        XCTAssertEqual(assignments.setPayload(key: 0, preset: 0xFF), [0xF8, 3, 2, 0x20, 0xFF])
        for status: [UInt8] in [[0], [0, 0, 0], [2, 0], [0, 0xFF]] {
            XCTAssertTrue(assignments.update([0xF5, 3, UInt8(status.count)] + status))
            XCTAssertFalse(assignments.isAvailable(key: 0))
            XCTAssertNil(assignments.setPayload(key: 0, preset: 0xFF))
        }
        XCTAssertTrue(assignments.update([0xF3, 3, 2, 0, 0]))
        for selected: [UInt8] in [[0x20], [0x20, 0x35, 0], [0xFE, 0x35], [0x20, 0x20]] {
            XCTAssertTrue(assignments.update([0xF9, 3, UInt8(selected.count)] + selected))
            XCTAssertEqual(assignments.selectedPresets, selected)
            XCTAssertNil(assignments.setPayload(key: 0, preset: 0xFF))
        }
    }

    func testDisplayedGesturesUseReportedCustomizationInsteadOfCapabilityDefaults() throws {
        var assignments = readyAssignments()
        XCTAssertEqual(assignments.reportedActions(key: 1), [SonyTouchActionSetting(action: 0, function: 0x20)])
        XCTAssertNil(assignments.reportedActions(key: 0))
        XCTAssertNil(assignments.reportedActions(key: 3))
        XCTAssertTrue(assignments.update([0xFB, 3, 1, 0x20, 1, 1, 0x43]))
        XCTAssertNil(assignments.reportedActions(key: 0))
        XCTAssertTrue(assignments.update([0xFB, 3, 1, 0x35, 1, 1, 0x44]))
        let actions = try XCTUnwrap(assignments.reportedActions(key: 0))
        XCTAssertEqual(actions, [SonyTouchActionSetting(action: 0, function: 2), SonyTouchActionSetting(action: 1, function: 0x44)])
        XCTAssertEqual(actions[0].gestureTitle(keyType: 0), "Tap")
        XCTAssertEqual(actions[1].gestureTitle(keyType: 0), "Double tap")
        XCTAssertEqual(actions[1].functionTitle, "Quick Access 2")
        XCTAssertEqual(SonyTouchActionSetting(action: 0x10, function: 0x30).functionTitle, "Voice Assistant")
        XCTAssertEqual(SonyTouchActionSetting(action: 3, function: 0x23).gestureTitle(keyType: 0), "Repeated taps")
        XCTAssertEqual(SonyTouchActionSetting(action: 0x10, function: 0x30).gestureTitle(keyType: 1), "Press and hold")
        XCTAssertEqual(SonyTouchActionSetting(action: 0, function: 0x30).gestureTitle(keyType: 0xFF), "Unknown gesture")
        XCTAssertEqual(SonyTouchActionSetting(action: 0xFF, function: 0xFF).functionTitle, "Unknown function")
        for reply: [UInt8] in [
            [0xFB, 3, 1, 0x35, 1, 2, 0x44],
            [0xFB, 3, 1, 0x35, 1, 1, 0x30],
            [0xFB, 3, 1, 0x35, 2, 1, 0x43, 1, 0x44],
            [0xFB, 3, 2, 0x35, 1, 1, 0x43, 0x35, 1, 1, 0x44],
        ] {
            XCTAssertTrue(assignments.update(reply))
            XCTAssertNil(assignments.reportedActions(key: 0))
        }
        XCTAssertTrue(assignments.update([0xF9, 3, 2, 0x20, 0xFF]))
        XCTAssertEqual(assignments.reportedActions(key: 0), [SonyTouchActionSetting(action: 0, function: 0)])
    }

    func testTruncatedNestedPacketsAndInvalidCountsPreservePriorState() {
        var assignments = readyAssignments()
        let prior = assignments
        for length in 0..<syntheticCapability.count {
            XCTAssertFalse(assignments.update(Array(syntheticCapability.prefix(length))), "Length \(length)")
            XCTAssertEqual(assignments, prior)
        }
        var invalidCapabilities = [syntheticCapability + [0]]
        for index in [2, 6, 28] {
            var payload = syntheticCapability
            payload[index] = 0
            invalidCapabilities.append(payload)
        }
        var emptyActions = syntheticCapability
        emptyActions[22] = 0
        emptyActions[23] = 0
        invalidCapabilities.append(emptyActions)
        for payload in invalidCapabilities {
            XCTAssertFalse(assignments.update(payload))
            XCTAssertEqual(assignments, prior)
        }
        for command: UInt8 in [0xF3, 0xF5, 0xF7, 0xF9] {
            for suffix: [UInt8] in [[0], [1], [1, 0, 0], [3, 0, 0]] {
                XCTAssertFalse(assignments.update([command, 3] + suffix))
                XCTAssertEqual(assignments, prior)
            }
        }
        let extended: [UInt8] = [0xFB, 3, 2, 0x35, 1, 1, 0x44, 0x20, 1, 0, 0x20]
        for length in 0..<extended.count {
            XCTAssertFalse(assignments.update(Array(extended.prefix(length))))
            XCTAssertEqual(assignments, prior)
        }
        for payload: [UInt8] in [extended + [0], [0xFB, 3, 0], [0xFD, 3, 1, 0x35, 0], [0xF8, 3, 2, 0x20, 0x35], [0xF7, 0x0E, 2, 0x20, 0x35]] {
            XCTAssertFalse(assignments.update(payload))
            XCTAssertEqual(assignments, prior)
        }
    }

    func testUnrecognizedCapabilityFieldsRemainRawAndNeverBecomeWritableChoices() {
        for index in [3, 4, 5, 7, 10, 11, 26, 27, 29] {
            var assignments = readyAssignments()
            var payload = syntheticCapability
            payload[index] = 0xFE
            XCTAssertTrue(assignments.update(payload))
            XCTAssertNotNil(assignments.keys)
            XCTAssertFalse(assignments.isAvailable(key: 0), "Field \(index)")
            XCTAssertNil(assignments.setPayload(key: 0, preset: 0xFF))
        }
        var assignments = readyAssignments()
        var unknownPreset = syntheticCapability
        unknownPreset[31] = 0xFE
        XCTAssertTrue(assignments.update(unknownPreset))
        XCTAssertEqual(assignments.keys?.last?.presets.last?.preset, 0xFE)
        XCTAssertEqual(assignments.keys?.last?.presets.last?.title, "Unknown")
        XCTAssertNil(assignments.setPayload(key: 0, preset: 0xFE))
        var duplicateKey = syntheticCapability
        duplicateKey[17] = 1
        XCTAssertTrue(assignments.update(duplicateKey))
        XCTAssertNil(assignments.setPayload(key: 1, preset: 0x10))
    }

    func testLimitationSubtypeIsNegotiatedIndependentlyAndRetainsCautionPresetMeaning() {
        var assignments = SonyTouchAssignments(supportedFunctions: [0xF3, 0xFE])
        XCTAssertEqual(assignments.inquiryType, 0x0E)
        XCTAssertEqual(assignments.queryPayloads, [[0xF0, 0x0E], [0xF2, 0x0E], [0xF6, 0x0E]])
        XCTAssertFalse(assignments.update(syntheticCapability))
        for limitation: UInt8 in [0, 1, 2] {
            XCTAssertTrue(assignments.update([0xF1, 0x0E, limitation] + syntheticCapability.dropFirst(2)))
            XCTAssertEqual(assignments.limitation, limitation)
            XCTAssertTrue(assignments.update([0xF3, 0x0E, 2, 0, 0]))
            XCTAssertTrue(assignments.update([0xF7, 0x0E, 2, 0x20, 0x35]))
            XCTAssertEqual(assignments.setPayload(key: 0, preset: 0xFF), [0xF8, 0x0E, 2, 0x20, 0xFF])
        }
        XCTAssertTrue(assignments.update([0xF1, 0x0E, 3] + syntheticCapability.dropFirst(2)))
        XCTAssertEqual(assignments.limitation, 3)
        XCTAssertNil(assignments.setPayload(key: 0, preset: 0xFF))
        let caution = SonyTouchPresetCapability(preset: 0x43, fixedActions: [], customizableActions: [])
        XCTAssertEqual(caution.title, "Ambient Sound & Quick Access (Classic only)")
    }

    func testSingleActionPatchPreservesOtherActionsRecordsAndSelectedPresets() {
        var assignments = SonyTouchAssignments(supportedFunctions: [0xF3])
        XCTAssertTrue(assignments.update(syntheticTouchCustomizationCapability()))
        XCTAssertTrue(assignments.update([0xF3, 3, 2, 0, 0]))
        XCTAssertTrue(assignments.update([0xF7, 3, 2, 0x35, 0x20]))
        let extended: [UInt8] = [0xFB, 3, 3, 0x35, 2, 0, 2, 1, 0x43,
                                 0x20, 1, 0, 0x20, 0xEE, 1, 0xEE, 0xFE]
        XCTAssertTrue(assignments.update(extended))
        let prior = assignments
        XCTAssertEqual(assignments.reportedFunction(preset: 0x35, action: 0), 2)
        XCTAssertEqual(assignments.setActionPayload(key: 0, action: 0, function: 1), [0xFC, 3, 1, 0x35, 1, 0, 1])
        XCTAssertEqual(assignments, prior)
        XCTAssertEqual(assignments.selectedPresets, [0x35, 0x20])
        XCTAssertNil(assignments.setActionPayload(key: 0, action: 0x10, function: 1))
        XCTAssertNil(assignments.setActionPayload(key: 0, action: 0, function: 0x30))
        XCTAssertNil(assignments.setActionPayload(key: 1, action: 0, function: 1))
    }

    func testSharedPresetRequiresEveryActiveKeyToAllowTheSameAction() {
        var assignments = SonyTouchAssignments(supportedFunctions: [0xF3])
        XCTAssertTrue(assignments.update(syntheticTouchCustomizationCapability(rightFunctions: [2, 3])))
        XCTAssertTrue(assignments.update([0xF3, 3, 2, 0, 0]))
        XCTAssertTrue(assignments.update([0xF7, 3, 2, 0x35, 0x35]))
        XCTAssertTrue(assignments.update([0xFB, 3, 1, 0x35, 2, 0, 2, 1, 0x43]))
        XCTAssertNil(assignments.setActionPayload(key: 0, action: 0, function: 1))
        XCTAssertEqual(assignments.setActionPayload(key: 0, action: 0, function: 3), [0xFC, 3, 1, 0x35, 1, 0, 3])
        XCTAssertTrue(assignments.update([0xF5, 3, 2, 0, 1]))
        XCTAssertNil(assignments.setActionPayload(key: 0, action: 0, function: 3))
        XCTAssertTrue(assignments.update([0xF9, 3, 2, 0x35, 0x20]))
        XCTAssertEqual(assignments.setActionPayload(key: 0, action: 0, function: 1), [0xFC, 3, 1, 0x35, 1, 0, 1])
    }

    func testSparsePatchDoesNotRequireUnderstandingUnrelatedCapabilityRecords() {
        let capability = syntheticTouchCustomizationCapability()
        for index in [24, 28, capability.count - 1] {
            var assignments = SonyTouchAssignments(supportedFunctions: [0xF3])
            var changed = capability
            changed[index] = 0xFE
            XCTAssertTrue(assignments.update(changed))
            XCTAssertTrue(assignments.update([0xF3, 3, 2, 0, 0]))
            XCTAssertTrue(assignments.update([0xF7, 3, 2, 0x35, 0x20]))
            XCTAssertTrue(assignments.update([0xFB, 3, 1, 0x35, 2, 0, 2, 1, 0x43]))
            XCTAssertEqual(assignments.setActionPayload(key: 0, action: 0, function: 1),
                           [0xFC, 3, 1, 0x35, 1, 0, 1], "Field \(index)")
            XCTAssertNil(assignments.setPayload(key: 0, preset: 0x20))
            XCTAssertEqual(assignments.selectedPresets, [0x35, 0x20])
        }
    }

    func testCustomActionRejectsAmbiguousOrMissingCurrentTargetAndLimitedInquiry() {
        var assignments = SonyTouchAssignments(supportedFunctions: [0xF3])
        XCTAssertTrue(assignments.update(syntheticTouchCustomizationCapability()))
        XCTAssertTrue(assignments.update([0xF3, 3, 2, 0, 0]))
        XCTAssertTrue(assignments.update([0xF7, 3, 2, 0x35, 0x20]))
        XCTAssertNil(assignments.setActionPayload(key: 0, action: 0, function: 1))
        for reply: [UInt8] in [
            [0xFB, 3, 1, 0x20, 1, 0, 2],
            [0xFB, 3, 1, 0x35, 1, 1, 0x43],
            [0xFB, 3, 1, 0x35, 2, 0, 2, 0, 3],
            [0xFB, 3, 2, 0x35, 1, 0, 2, 0x35, 1, 0, 2],
            [0xFB, 3, 1, 0x35, 1, 0, 0xFE],
        ] {
            XCTAssertTrue(assignments.update(reply))
            XCTAssertNil(assignments.setActionPayload(key: 0, action: 0, function: 1), "\(reply)")
        }
        XCTAssertTrue(assignments.update([0xFB, 3, 1, 0x35, 2, 0, 2, 1, 0x43]))
        for index in [10, 19] {
            var collision = syntheticTouchCustomizationCapability()
            collision[index] = 0
            XCTAssertTrue(assignments.update(collision))
            XCTAssertNil(assignments.setActionPayload(key: 0, action: 0, function: 1))
        }
        var limited = SonyTouchAssignments(supportedFunctions: [0xFE])
        XCTAssertTrue(limited.update([0xF1, 0x0E, 0] + syntheticTouchCustomizationCapability().dropFirst(2)))
        XCTAssertTrue(limited.update([0xF3, 0x0E, 2, 0, 0]))
        XCTAssertTrue(limited.update([0xF7, 0x0E, 2, 0x35, 0x20]))
        XCTAssertTrue(limited.update([0xFB, 0x0E, 1, 0x35, 2, 0, 2, 1, 0x43]))
        XCTAssertNil(limited.setActionPayload(key: 0, action: 0, function: 1))
    }

    @MainActor
    func testControllerConfirmsFullReportedListOnlyAfterTransmissionAndClearsOnLoss() {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        controller.setTouchAssignment(key: 0, preset: 0x20)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xF8, 3, 2, 0x20, 0x20])
        XCTAssertEqual(controller.touchAssignments.selectedPresets, [0x35, 0x20])
        XCTAssertEqual(controller.pendingChanges[.touchAssignments], [3, 2, 0x20, 0x20])
        acknowledgeSimulatedCommands(controller)
        XCTAssertNotNil(controller.pendingChanges[.touchAssignments])
        XCTAssertEqual(controller.touchAssignments.selectedPresets, [0x35, 0x20])
        for payload: [UInt8] in [[0xF9, 3, 2, 0x20], [0xF9, 3, 2, 0x20, 0x35], [0xF9, 0x0E, 2, 0x20, 0x20]] {
            controller.simulateProtocolMessage(payload)
            XCTAssertNotNil(controller.pendingChanges[.touchAssignments])
        }
        controller.simulateProtocolMessage([0xF7, 3, 2, 0x20, 0x20])
        XCTAssertNotNil(controller.pendingChanges[.touchAssignments])
        controller.simulateProtocolMessage([0xF9, 3, 2, 0x20, 0x20])
        XCTAssertNil(controller.pendingChanges[.touchAssignments])
        XCTAssertEqual(controller.touchAssignments.selectedPresets, [0x20, 0x20])
        controller.setTouchAssignment(key: 1, preset: 0x35)
        XCTAssertNotNil(controller.pendingChanges[.touchAssignments])
        controller.simulateControlLoss()
        XCTAssertNil(controller.touchAssignments.keys)
        XCTAssertNil(controller.touchAssignments.selectedPresets)
        XCTAssertTrue(controller.touchAssignments.queryPayloads.isEmpty)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
    }

    private func readyAssignments() -> SonyTouchAssignments {
        var assignments = SonyTouchAssignments(supportedFunctions: [0xF3])
        XCTAssertTrue(assignments.update(syntheticCapability))
        XCTAssertTrue(assignments.update([0xF3, 3, 2, 0, 0]))
        XCTAssertTrue(assignments.update([0xF7, 3, 2, 0x20, 0x35]))
        return assignments
    }

    private var syntheticCapability: [UInt8] {
        [0xF1, 3, 2,
         1, 0, 0x20, 2,
         0x20, 1, 0, 0, 0x20,
         0x10, 1, 0, 3, 0x23,
         0, 0, 0x35, 2,
         0x35, 1, 1, 0, 2, 1, 0x43, 2, 0x43, 0x44,
         0xFF, 1, 0, 0, 0]
    }
}

private func syntheticLegacyTouchCapability(keys: [UInt8] = [0, 1], keyType: UInt8 = 0) -> [UInt8] {
    [0xF1, 6, UInt8(keys.count)] + keys.flatMap { key in
        [key, keyType, key == 1 ? 0x20 : 0, 8,
         0, 2, 0, 1, 0x10, 2,
         0x10, 2, 0, 0x11, 1, 0x12,
         0x20, 1, 0, 0x20,
         0x30, 1, 0x10, 0x30,
         0x31, 1, 0x10, 0x32,
         0x32, 1, 0x10, 0x34,
         0x33, 1, 0x10, 0x35,
         0xFF, 1, 0, 0]
    }
}

private func syntheticTouchCustomizationCapability(rightFunctions: [UInt8] = [1, 2, 3, 4],
                                                   includeVolumePreset: Bool = false) -> [UInt8] {
    func key(_ id: UInt8, defaultPreset: UInt8, functions: [UInt8]) -> [UInt8] {
        [id, 0, defaultPreset, includeVolumePreset ? 3 : 2, 0x35, 1, 2, 0x10, 0x10, 0, 2, UInt8(functions.count)]
            + functions + [1, 0x43, 2, 0x43, 0x44, 0x20, 1, 0, 0, 0x20]
            + (includeVolumePreset ? [0x10, 1, 0, 3, 0x23] : [])
    }
    return [0xF1, 3, 2] + key(0, defaultPreset: 0x35, functions: [1, 2, 3, 4])
        + key(1, defaultPreset: 0x20, functions: rightFunctions)
}

@MainActor
final class SonyTouchCustomizationControllerTests: XCTestCase {
    func testLegacyAssignmentReadsOwnActualTransmissionAndUnknownRepliesKeepDeadlines() async {
        let initial = beginLegacyDiscovery()
        defer { initial.simulateControlLoss() }
        let replies: [[UInt8]] = [syntheticLegacyTouchCapability(), [0xF3, 6, 2, 0, 0], [0xF7, 6, 2, 0, 0x20]]
        for reply in replies { deliver(reply, to: initial) }
        XCTAssertNil(initial.touchAssignments.keys)
        XCTAssertNil(initial.touchAssignments.statuses)
        XCTAssertNil(initial.touchAssignments.selectedPresets)
        acknowledgeAll(initial)
        for reply in replies { deliver(reply, type: 0x0E, to: initial) }
        XCTAssertNil(initial.touchAssignments.keys)
        XCTAssertNil(initial.touchAssignments.statuses)
        XCTAssertNil(initial.touchAssignments.selectedPresets)
        for reply in replies { deliver(reply, to: initial) }
        XCTAssertTrue(initial.canSetTouchAssignment(key: 0))
        deliver(syntheticLegacyTouchCapability(keys: [1, 0]), to: initial)
        XCTAssertEqual(initial.touchAssignments.keys?.map(\.key), [0, 1])
        var unknownCapability = syntheticLegacyTouchCapability()
        unknownCapability[4] = 0xFE
        let cases: [(query: [UInt8], valid: [UInt8], unknown: [UInt8])] = [
            ([0xF0, 6], syntheticLegacyTouchCapability(), unknownCapability),
            ([0xF2, 6], [0xF3, 6, 2, 0, 0], [0xF3, 6, 2, 0, 2]),
            ([0xF6, 6], [0xF7, 6, 2, 0, 0x20], [0xF7, 6, 2, 0, 0xFE]),
        ]
        for testCase in cases {
            for reply in [testCase.valid, testCase.unknown, Array(testCase.valid.dropLast()), []] {
                let controller = beginLegacyDiscovery()
                defer { controller.simulateControlLoss() }
                controller.simulateTouchReadTimeout(testCase.query)
                for _ in 0..<4 { await Task.yield() }
                XCTAssertTrue(controller.isReady)
                acknowledgeAll(controller)
                XCTAssertTrue(payloads(controller).contains(testCase.query))
                if !reply.isEmpty { deliver(reply, to: controller) }
                let session = controller.simulatedControlSession
                controller.simulateTouchReadTimeout(testCase.query)
                for _ in 0..<4 { await Task.yield() }
                XCTAssertTrue(controller.isReady)
                if reply != testCase.valid {
                    XCTAssertEqual(controller.simulatedControlSession, session)
                    XCTAssertTrue(controller.isDeviceConnected)
                }
            }
        }
    }

    func testLegacyAssignmentConfirmationNeedsActualWriteAndFreshCompleteSelection() async {
        let deferred = readyLegacyController()
        defer { deferred.simulateControlLoss() }
        deferred.defersSimulatedWrites = true
        deferred.setTouchAssignment(key: 0, preset: 0x10)
        deferred.defersSimulatedWrites = false
        deliver([0xF9, 6, 2, 0x10, 0x20], to: deferred)
        XCTAssertEqual(deferred.pendingChanges[.touchAssignments], [6, 2, 0x10, 0x20])
        XCTAssertFalse(payloads(deferred).contains([0xF8, 6, 2, 0x10, 0x20]))
        deferred.completeSimulatedWrite()
        acknowledgeAll(deferred)
        for reply: [UInt8] in [[0xF7, 6, 2, 0x10, 0x20], [0xF9, 6, 2, 0x10], [0xF9, 6, 2, 0x10, 0x31],
                              [0xF9, 3, 2, 0x10, 0x20]] {
            deliver(reply, to: deferred)
            XCTAssertNotNil(deferred.pendingChanges[.touchAssignments])
        }
        deliver([0xF9, 6, 2, 0x10, 0x20], type: 0x0E, to: deferred)
        XCTAssertNotNil(deferred.pendingChanges[.touchAssignments])
        deliver([0xF9, 6, 2, 0x10, 0x20], to: deferred)
        XCTAssertNil(deferred.pendingChanges[.touchAssignments])
        for expires in [false, true] {
            let controller = readyLegacyController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeAll(controller)
            let reads = payloads(controller).filter { $0 == [0xF6, 6] }.count
            controller.setTouchAssignment(key: 0, preset: 0x10)
            acknowledgeAll(controller)
            XCTAssertEqual(payloads(controller).filter { $0.first == 0xF8 }, [[0xF8, 6, 2, 0x10, 0x20]])
            XCTAssertEqual(controller.touchAssignments.selectedPresets, [0, 0x20])
            XCTAssertNotNil(controller.pendingChanges[.touchAssignments])
            if expires {
                controller.simulateSettingTimeout(.touchAssignments)
                for _ in 0..<4 { await Task.yield() }
                XCTAssertNotNil(controller.settingErrors[.touchAssignments])
                XCTAssertNil(controller.pendingChanges[.touchAssignments])
            }
            XCTAssertFalse(controller.canSetTouchAssignment(key: 1))
            controller.setTouchAssignment(key: 1, preset: 0x31)
            deliver([0xF7, 6, 2, 0x10, 0x20], to: controller)
            XCTAssertEqual(controller.touchAssignments.selectedPresets, [0, 0x20])
            XCTAssertFalse(controller.canSetTouchAssignment(key: 0))
            acknowledgeAll(controller)
            XCTAssertEqual(payloads(controller).filter { $0 == [0xF6, 6] }.count, reads + 1)
            deliver([0xF7, 6, 2, expires ? 0 : 0x10, 0x20], to: controller)
            XCTAssertNil(controller.pendingChanges[.touchAssignments])
            XCTAssertNil(controller.settingErrors[.touchAssignments])
            XCTAssertTrue(controller.canSetTouchAssignment(key: 0))
            XCTAssertEqual(controller.touchAssignments.selectedPresets, [expires ? 0 : 0x10, 0x20])
            XCTAssertEqual(payloads(controller).filter { $0.first == 0xF8 }.count, 1)
        }
    }

    func testLegacyAssignmentNotificationsCannotBeRewoundByOlderKnownOrUnknownPolls() {
        for unknown in [false, true] {
            let controller = readyLegacyController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeAll(controller)
            deliver([0xF5, 6, 2, unknown ? 2 : 1, 0], to: controller)
            deliver([0xF9, 6, 2, unknown ? 0xFE : 0x31, 0x10], to: controller)
            deliver([0xF3, 6, 2, 0xFF, 0], to: controller)
            deliver([0xF7, 6, 2, 0xFE, 0x20], to: controller)
            deliver([0xF3, 6, 2, 0, 0], to: controller)
            deliver([0xF7, 6, 2, 0, 0x20], to: controller)
            XCTAssertEqual(controller.touchAssignments.statuses, [unknown ? 2 : 1, 0])
            XCTAssertEqual(controller.touchAssignments.selectedPresets, [unknown ? 0xFE : 0x31, 0x10])
            XCTAssertFalse(controller.canSetTouchAssignment(key: 0))
            XCTAssertNil(controller.earTipFitTransition)
            XCTAssertNil(controller.earTipFit.operation)
        }
    }

    func testQueuedLegacyPresetRejectsOtherSideChangesAndIgnoresUnownedKeyReordering() {
        for changed: [UInt8] in [[0xF9, 6, 2, 0, 0x10], [0xF5, 6, 2, 1, 0], [0xF9, 6, 2, 0xFE, 0x20]] {
            let controller = readyLegacyController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            controller.setTouchAssignment(key: 0, preset: 0x10)
            XCTAssertNotNil(controller.pendingChanges[.touchAssignments])
            XCTAssertFalse(payloads(controller).contains([0xF8, 6, 2, 0x10, 0x20]))
            deliver(changed, to: controller)
            acknowledgeAll(controller)
            XCTAssertFalse(payloads(controller).contains([0xF8, 6, 2, 0x10, 0x20]))
            XCTAssertTrue(controller.isReady)
            XCTAssertNil(controller.pendingChanges[.touchAssignments])
        }
        let controller = readyLegacyController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        controller.setTouchAssignment(key: 0, preset: 0x10)
        deliver(syntheticLegacyTouchCapability(keys: [1, 0]), to: controller)
        XCTAssertEqual(controller.touchAssignments.keys?.map(\.key), [0, 1])
        acknowledgeAll(controller)
        XCTAssertTrue(payloads(controller).contains([0xF8, 6, 2, 0x10, 0x20]))
        deliver([0xF9, 6, 2, 0x10, 0x20], to: controller)
        XCTAssertNil(controller.pendingChanges[.touchAssignments])
        let disconnecting = readyLegacyController()
        defer { disconnecting.simulateControlLoss() }
        disconnecting.refresh()
        disconnecting.setTouchAssignment(key: 1, preset: 0x31)
        XCTAssertEqual(disconnecting.pendingChanges[.touchAssignments], [6, 2, 0, 0x31])
        XCTAssertFalse(payloads(disconnecting).contains([0xF8, 6, 2, 0, 0x31]))
        let session = disconnecting.simulatedControlSession
        disconnecting.simulateControlLoss()
        acknowledgeAll(disconnecting)
        deliver([0xF9, 6, 2, 0, 0x31], session: session, to: disconnecting)
        XCTAssertFalse(payloads(disconnecting).contains([0xF8, 6, 2, 0, 0x31]))
        XCTAssertTrue(disconnecting.pendingChanges.isEmpty)
        XCTAssertNil(disconnecting.touchAssignments.keys)
    }

    func testLegacySingleButtonAssignmentAndModernFitKeepSeparateInquirySixContracts() {
        let legacy = readyLegacyController(singleButton: true)
        defer { legacy.simulateControlLoss() }
        XCTAssertEqual(legacy.touchAssignments.inquiryType, 6)
        XCTAssertFalse(legacy.earTipFit.isSupported)
        XCTAssertFalse(legacy.beginEarTipFit())
        XCTAssertFalse(legacy.canSetTouchAction(key: 2, action: 0))
        legacy.setTouchAction(key: 2, action: 0, function: 1)
        legacy.setTouchAssignment(key: 2, preset: 0x10)
        acknowledgeAll(legacy)
        XCTAssertEqual(payloads(legacy).filter { $0.first == 0xF8 }, [[0xF8, 6, 1, 0x10]])
        XCTAssertFalse(payloads(legacy).contains { $0.first == 0xFA || $0.first == 0xFC })
        deliver([0xF9, 6, 1, 0, 1, 0, 1, 0xFF], to: legacy)
        XCTAssertNotNil(legacy.pendingChanges[.touchAssignments])
        deliver([0xF9, 6, 1, 0x10], to: legacy)
        XCTAssertNil(legacy.pendingChanges[.touchAssignments])
        XCTAssertEqual(legacy.touchAssignments.selectedPreset(key: 2), 0x10)
        XCTAssertNil(legacy.earTipFit.operation)
        let modern = SonyHeadphonesController(startAutomatically: false, simulated: true)
        modern.simulateDeviceConnection(named: "WF-1000XM5")
        defer { modern.simulateControlLoss() }
        let assignment = modern.touchAssignments
        XCTAssertTrue(modern.beginEarTipFit())
        XCTAssertFalse(modern.canSetTouchAssignment(key: 0))
        deliver(syntheticLegacyTouchCapability(), to: modern)
        deliver([0xF3, 6, 2, 0, 0], to: modern)
        deliver([0xF7, 6, 2, 0, 0x20], to: modern)
        XCTAssertEqual(modern.touchAssignments, assignment)
        XCTAssertNil(modern.earTipFit.capability)
        deliver([0xF1, 6, 5, 1, 1, 1, 2], to: modern)
        XCTAssertEqual(modern.earTipFit.capability?.duration, 5)
        XCTAssertEqual(modern.touchAssignments, assignment)
    }

    func testOwnedDiscoveryRejectsEarlyMalformedAndWrongTableReplies() async {
        let controller = beginDiscovery()
        defer { controller.simulateControlLoss() }
        deliver(syntheticTouchCustomizationCapability(), to: controller)
        deliver([0xF3, 3, 2, 0, 0], to: controller)
        deliver([0xF7, 3, 2, 0x35, 0x20], to: controller)
        deliver(extended(), to: controller)
        XCTAssertNil(controller.touchAssignments.keys)
        XCTAssertNil(controller.touchAssignments.statuses)
        XCTAssertNil(controller.touchAssignments.selectedPresets)
        XCTAssertNil(controller.touchAssignments.customizedActions)
        acknowledgeAll(controller)
        deliver(syntheticTouchCustomizationCapability(), type: 0x0E, to: controller)
        deliver(Array(syntheticTouchCustomizationCapability().dropLast()), to: controller)
        XCTAssertNil(controller.touchAssignments.keys)
        deliver(syntheticTouchCustomizationCapability(), to: controller)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xFA, 3])
        deliver(Array(extended().dropLast()), to: controller)
        XCTAssertNil(controller.touchAssignments.customizedActions)
        deliver(extended(), to: controller)
        deliver([0xF3, 3, 2, 0, 0], to: controller)
        deliver([0xF7, 3, 2, 0x35, 0x20], to: controller)
        acknowledgeAll(controller)
        XCTAssertTrue(controller.canSetTouchAction(key: 0, action: 0))
        deliver(extended(function: 4), to: controller)
        var changedCapability = syntheticTouchCustomizationCapability()
        changedCapability[15] = 0
        deliver(changedCapability, to: controller)
        XCTAssertEqual(controller.touchAssignments.reportedFunction(preset: 0x35, action: 0), 2)
        XCTAssertEqual(controller.touchAssignments.keys?.first?.presets.first?.customizableActions.first?.functions, [1, 2, 3, 4])
        for index in [24, 28] {
            let sparse = beginDiscovery()
            defer { sparse.simulateControlLoss() }
            acknowledgeAll(sparse)
            var unknownUnrelated = syntheticTouchCustomizationCapability()
            unknownUnrelated[index] = 0xFE
            deliver(unknownUnrelated, to: sparse)
            acknowledgeAll(sparse)
            deliver([0xF3, 3, 2, 0, 0], to: sparse)
            deliver([0xF7, 3, 2, 0x35, 0x20], to: sparse)
            deliver(extended(), to: sparse)
            XCTAssertTrue(sparse.canSetTouchAction(key: 0, action: 0))
            XCTAssertFalse(sparse.canSetTouchAssignment(key: 0))
            sparse.simulateTouchReadTimeout([0xF0, 3])
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(sparse.isReady)
            sparse.setTouchAction(key: 0, action: 0, function: 1)
            XCTAssertTrue(payloads(sparse).contains([0xFC, 3, 1, 0x35, 1, 0, 1]))
        }
    }

    func testCustomActionConfirmationRequiresTransmissionAndExactUniqueTarget() {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.defersSimulatedWrites = true
        controller.setTouchAction(key: 0, action: 0, function: 1)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xFC, 3, 1, 0x35, 1, 0, 1])
        controller.defersSimulatedWrites = false
        deliver(extended(command: 0xFD, function: 1), to: controller)
        XCTAssertNotNil(controller.pendingChanges[.touchCustomActions])
        XCTAssertFalse(payloads(controller).contains { $0.first == 0xFC })
        controller.completeSimulatedWrite()
        acknowledgeAll(controller)
        XCTAssertNotNil(controller.pendingChanges[.touchCustomActions])
        deliver(extended(command: 0xFD, function: 1), type: 0x0E, to: controller)
        for reply: [UInt8] in [
            [0xFD, 0x0E, 1, 0x35, 1, 0, 1],
            [0xFD, 3, 1, 0x20, 1, 0, 1],
            [0xFD, 3, 1, 0x35, 1, 1, 1],
            [0xFD, 3, 1, 0x35, 2, 0, 1, 0, 1],
            [0xFD, 3, 2, 0x35, 1, 0, 1, 0x35, 1, 0, 1],
            [0xFD, 3, 1, 0x35, 1, 0, 2],
        ] {
            deliver(reply, to: controller)
            XCTAssertNotNil(controller.pendingChanges[.touchCustomActions], "\(reply)")
        }
        deliver(extended(command: 0xFD, function: 1, otherFunction: 0x44), to: controller)
        XCTAssertNil(controller.pendingChanges[.touchCustomActions])
        XCTAssertEqual(controller.touchAssignments.reportedFunction(preset: 0x35, action: 0), 1)
        XCTAssertEqual(controller.touchAssignments.reportedFunction(preset: 0x35, action: 1), 0x44)
        XCTAssertEqual(controller.touchAssignments.selectedPresets, [0x35, 0x20])
        XCTAssertFalse(payloads(controller).contains { $0.first == 0xF8 })
        controller.setTouchAction(key: 0, action: 0, function: 3)
        XCTAssertNotNil(controller.pendingChanges[.touchCustomActions])
        let session = controller.simulatedControlSession
        controller.simulateControlLoss()
        deliver(extended(command: 0xFD, function: 3), session: session, to: controller)
        XCTAssertNil(controller.touchAssignments.keys)
        XCTAssertNil(controller.touchAssignments.customizedActions)
        XCTAssertTrue(controller.pendingChanges.isEmpty)
    }

    func testOldExtendedReadCannotConfirmNewPatchUntilFreshOwnedReply() {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeAll(controller)
        let reads = payloads(controller).filter { $0 == [0xFA, 3] }.count
        controller.setTouchAction(key: 0, action: 0, function: 1)
        acknowledgeAll(controller)
        deliver(extended(function: 1), to: controller)
        XCTAssertNotNil(controller.pendingChanges[.touchCustomActions])
        XCTAssertEqual(controller.touchAssignments.reportedFunction(preset: 0x35, action: 0), 2)
        acknowledgeAll(controller)
        XCTAssertEqual(payloads(controller).filter { $0 == [0xFA, 3] }.count, reads + 1)
        deliver(extended(function: 1), to: controller)
        XCTAssertNil(controller.pendingChanges[.touchCustomActions])
        XCTAssertEqual(controller.touchAssignments.reportedFunction(preset: 0x35, action: 0), 1)
    }

    func testOldTouchRepliesCannotRewindNewerGestureSelectionOrAvailability() {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeAll(controller)
        deliver(extended(command: 0xFD, function: 4), to: controller)
        deliver([0xF9, 3, 2, 0x20, 0x35], to: controller)
        deliver([0xF5, 3, 2, 1, 0], to: controller)
        deliver(extended(), to: controller)
        deliver([0xF7, 3, 2, 0x35, 0x20], to: controller)
        deliver([0xF3, 3, 2, 0, 0], to: controller)
        XCTAssertEqual(controller.touchAssignments.reportedFunction(preset: 0x35, action: 0), 4)
        XCTAssertEqual(controller.touchAssignments.selectedPresets, [0x20, 0x35])
        XCTAssertEqual(controller.touchAssignments.statuses, [1, 0])
        XCTAssertFalse(controller.canSetTouchAssignment(key: 0))
        XCTAssertTrue(controller.canSetTouchAction(key: 1, action: 0))
    }

    func testQueuedPatchRevalidatesAvailabilityTargetAndSharingMembership() {
        let cases: [(selection: [UInt8], change: [UInt8])] = [
            ([0x35, 0x20], [0xF5, 3, 2, 1, 0]),
            ([0x35, 0x20], [0xF9, 3, 2, 0x20, 0x20]),
            ([0x35, 0x20], [0xF9, 3, 2, 0x35, 0x35]),
            ([0x35, 0x35], [0xF9, 3, 2, 0x35, 0x20]),
        ]
        for testCase in cases {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            deliver([0xF9, 3, 2] + testCase.selection, to: controller)
            controller.refresh()
            controller.setTouchAction(key: 0, action: 0, function: 1)
            XCTAssertNotNil(controller.pendingChanges[.touchCustomActions])
            deliver(testCase.change, to: controller)
            acknowledgeAll(controller)
            XCTAssertFalse(payloads(controller).contains { $0.first == 0xFC })
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.pendingChanges.isEmpty)
        }
    }

    func testQueuedPatchPreservesUnrelatedActionsAndOtherKeySelection() {
        let controller = readyController(includeVolumePreset: true)
        defer { controller.simulateControlLoss() }
        controller.refresh()
        controller.setTouchAction(key: 0, action: 0, function: 1)
        deliver([0xF9, 3, 2, 0x35, 0x10], to: controller)
        deliver(extended(command: 0xFD, otherFunction: 0x44), to: controller)
        acknowledgeAll(controller)
        XCTAssertEqual(payloads(controller).filter { $0.first == 0xFC }, [[0xFC, 3, 1, 0x35, 1, 0, 1]])
        XCTAssertEqual(controller.touchAssignments.reportedFunction(preset: 0x35, action: 1), 0x44)
        deliver(extended(command: 0xFD, function: 1, otherFunction: 0x44), to: controller)
        XCTAssertNil(controller.pendingChanges[.touchCustomActions])
        XCTAssertEqual(controller.touchAssignments.selectedPresets, [0x35, 0x10])
    }

    func testUnconfirmedCustomActionBlocksBothMutationsUntilFreshOwnedState() async {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeAll(controller)
        controller.setTouchAction(key: 0, action: 0, function: 1)
        acknowledgeAll(controller)
        controller.setTouchAssignment(key: 1, preset: 0x35)
        XCTAssertNil(controller.pendingChanges[.touchAssignments])
        controller.simulateSettingTimeout(.touchCustomActions)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertFalse(controller.canSetTouchAction(key: 0, action: 0))
        XCTAssertFalse(controller.canSetTouchAssignment(key: 1))
        let before = payloads(controller)
        controller.setTouchAction(key: 0, action: 0, function: 2)
        controller.setTouchAssignment(key: 1, preset: 0x35)
        XCTAssertEqual(payloads(controller), before)
        deliver(extended(function: 1), to: controller)
        XCTAssertFalse(controller.canSetTouchAction(key: 0, action: 0))
        acknowledgeAll(controller)
        deliver(extended(), to: controller)
        XCTAssertTrue(controller.canSetTouchAction(key: 0, action: 0))
        XCTAssertTrue(controller.canSetTouchAssignment(key: 1))
        XCTAssertNil(controller.settingErrors[.touchCustomActions])
        controller.setTouchAction(key: 0, action: 0, function: 1)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0xFC, 3, 1, 0x35, 1, 0, 1])
    }

    func testUnconfirmedPresetBlocksCustomActionAndOldSelectionCannotUnlockIt() async {
        let controller = readyController()
        defer { controller.simulateControlLoss() }
        controller.refresh()
        acknowledgeAll(controller)
        controller.setTouchAssignment(key: 1, preset: 0x35)
        acknowledgeAll(controller)
        controller.setTouchAction(key: 0, action: 0, function: 1)
        XCTAssertNil(controller.pendingChanges[.touchCustomActions])
        controller.simulateSettingTimeout(.touchAssignments)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertFalse(controller.canSetTouchAction(key: 0, action: 0))
        deliver([0xF7, 3, 2, 0x35, 0x35], to: controller)
        XCTAssertFalse(controller.canSetTouchAction(key: 0, action: 0))
        acknowledgeAll(controller)
        deliver([0xF7, 3, 2, 0x35, 0x20], to: controller)
        XCTAssertTrue(controller.canSetTouchAction(key: 0, action: 0))
        XCTAssertNil(controller.settingErrors[.touchAssignments])
        XCTAssertFalse(payloads(controller).contains { $0.first == 0xFC })
    }

    func testMissingTouchReadRepliesExpireOnlyAfterTransmissionAndResetOwnership() async {
        for query: [UInt8] in [[0xF0, 3], [0xF2, 3], [0xF6, 3], [0xFA, 3]] {
            let controller = beginDiscovery()
            defer { controller.simulateControlLoss() }
            controller.simulateTouchReadTimeout(query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            acknowledgeAll(controller)
            if query[0] == 0xFA {
                deliver(syntheticTouchCustomizationCapability(), to: controller)
                acknowledgeAll(controller)
            }
            XCTAssertTrue(payloads(controller).contains(query))
            let session = controller.simulatedControlSession
            controller.simulateTouchReadTimeout(query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertTrue(controller.isDeviceConnected)
            XCTAssertNotNil(controller.noiseControlMode)
            XCTAssertNotNil(controller.settingErrors[query[0] == 0xFA ? .touchCustomActions : .touchAssignments])
            switch query[0] {
            case 0xF0: XCTAssertNil(controller.touchAssignments.keys)
            case 0xF2: XCTAssertNil(controller.touchAssignments.statuses)
            case 0xF6: XCTAssertNil(controller.touchAssignments.selectedPresets)
            default: XCTAssertNil(controller.touchAssignments.customizedActions)
            }
            controller.simulateControlLoss()
            deliver(extended(command: 0xFD), session: session, to: controller)
            XCTAssertNil(controller.touchAssignments.customizedActions)
            controller.simulateDeviceConnection(named: "WF-1000XM5")
            controller.simulateTouchReadTimeout(query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
        }
    }

    func testExpiredTouchSelectionReadRetainsOwnershipAndAcceptsFreshRecovery() async {
        for notification in [false, true] {
            let controller = readyController()
            defer { controller.simulateControlLoss() }
            controller.refresh()
            acknowledgeAll(controller)
            let session = controller.simulatedControlSession
            let query: [UInt8] = [0xF6, 3]
            let reads = payloads(controller).filter { $0 == query }.count
            controller.simulateTouchReadTimeout(query)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.simulatedControlSession, session)
            XCTAssertNil(controller.touchAssignments.selectedPresets)
            XCTAssertFalse(controller.canSetTouchAssignment(key: 0))
            XCTAssertNotNil(controller.noiseControlMode)
            if notification { deliver([0xF9, 3, 2, 0x20, 0x35], to: controller) }
            for _ in 0..<40 { controller.simulateAutomaticRefresh() }
            acknowledgeAll(controller)
            deliver([0xF7, 3, 2, 0x35], to: controller)
            acknowledgeAll(controller)
            XCTAssertEqual(payloads(controller).filter { $0 == query }.count, reads)
            deliver([0xF7, 3, 2, 0x35, 0x20], to: controller)
            XCTAssertEqual(controller.touchAssignments.selectedPresets, notification ? [0x20, 0x35] : nil)
            acknowledgeAll(controller)
            XCTAssertEqual(payloads(controller).filter { $0 == query }.count, reads + 1)
            deliver([0xF7, 3, 2, 0x35, 0x20], to: controller)
            XCTAssertEqual(controller.touchAssignments.selectedPresets, [0x35, 0x20])
            XCTAssertTrue(controller.canSetTouchAssignment(key: 0))
            XCTAssertEqual(controller.simulatedControlSession, session)
        }
    }

    private func beginLegacyDiscovery() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
        controller.simulateProtocolMessage([1, 0, 2, 0x10], beginConnection: true)
        acknowledgeAll(controller)
        let model = Array("WF-1000XM4".utf8)
        deliver([5, 1, UInt8(model.count)] + model, to: controller)
        deliver([5, 3, 0x30, 0xFF], to: controller)
        deliver([7, 0, 2, 0x62, 0xF6], to: controller)
        acknowledgeAll(controller)
        deliver([0x61, 2, 2, 3, 1, 2, 0, 20, 1, 15], to: controller)
        deliver([0x63, 2, 0], to: controller)
        deliver([0x67, 2, 1, 2, 0, 1, 0, 12], to: controller)
        XCTAssertTrue(controller.isReady)
        return controller
    }

    private func readyLegacyController(singleButton: Bool = false) -> SonyHeadphonesController {
        let controller = beginLegacyDiscovery()
        acknowledgeAll(controller)
        deliver(syntheticLegacyTouchCapability(keys: singleButton ? [2] : [0, 1], keyType: singleButton ? 1 : 0), to: controller)
        deliver(singleButton ? [0xF3, 6, 1, 0] : [0xF3, 6, 2, 0, 0], to: controller)
        deliver(singleButton ? [0xF7, 6, 1, 0] : [0xF7, 6, 2, 0, 0x20], to: controller)
        XCTAssertTrue(controller.canSetTouchAssignment(key: singleButton ? 2 : 0))
        return controller
    }

    private func beginDiscovery() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5", controlBusy: true)
        controller.simulateProtocolMessage([1, 0, 3, 0, 0x30, 0x18, 0, 0], beginConnection: true)
        acknowledgeAll(controller)
        deliver([7, 0, 2, 0x6B, 1, 0xF3, 1], to: controller)
        acknowledgeAll(controller)
        deliver([0x61, 0x17, 1, 0, 1, 20, 1], to: controller)
        deliver([0x63, 0x17, 0], to: controller)
        deliver([0x67, 0x17, 1, 1, 1, 0, 8], to: controller)
        return controller
    }

    private func readyController(includeVolumePreset: Bool = false) -> SonyHeadphonesController {
        let controller = beginDiscovery()
        acknowledgeAll(controller)
        deliver(syntheticTouchCustomizationCapability(includeVolumePreset: includeVolumePreset), to: controller)
        deliver([0xF3, 3, 2, 0, 0], to: controller)
        deliver([0xF7, 3, 2, 0x35, 0x20], to: controller)
        acknowledgeAll(controller)
        deliver(extended(), to: controller)
        XCTAssertTrue(controller.canSetTouchAction(key: 0, action: 0))
        return controller
    }

    private func extended(command: UInt8 = 0xFB, function: UInt8 = 2, otherFunction: UInt8 = 0x43) -> [UInt8] {
        [command, 3, 2, 0x35, 2, 0, function, 1, otherFunction, 0x20, 1, 0, 0x20]
    }

    private func deliver(_ payload: [UInt8], type: UInt8 = 0x0C, session: UInt64? = nil,
                         to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload, type: type, session: session)
    }

    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        for _ in 0..<100 {
            guard let frame = controller.simulatedPendingFrame else { return }
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("The simulated command queue did not drain.")
    }

    private func payloads(_ controller: SonyHeadphonesController) -> [[UInt8]] {
        controller.simulatedTransmittedFrames.filter { $0.type == 0x0C }.map(\.payload)
    }
}
