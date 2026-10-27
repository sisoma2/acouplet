import XCTest
@testable import Acouplet

final class SonyDeviceActionTransitionTests: XCTestCase {
    func testActionsRequireTransmissionMatchingResultsAndOwnedFreshReadback() throws {
        for action in [SonyPeripheralAction.connect, .disconnect] {
            let model = readyModel(secondConnection: action == .connect ? 0 : 2)
            let requestID = UUID()
            var transition = try XCTUnwrap(SonyDeviceActionTransition(action: action, targetAddress: secondAddress.lowercased(), model: model, session: 7, requestID: requestID))
            let command = [0x3C, 0x02, action.rawValue] + Array(secondAddress.utf8)
            let success = result(action)
            XCTAssertEqual(transition.requestID, requestID)
            XCTAssertEqual(transition.targetAddress, secondAddress)
            XCTAssertEqual(transition.action, action)
            XCTAssertEqual(transition.expectedPayload, command)
            XCTAssertFalse(transition.receive(success, model: model, session: 7))
            XCTAssertFalse(transition.commandTransmitted(command, model: model, session: 8))
            XCTAssertFalse(transition.commandTransmitted([0x36, 2], model: model, session: 7))
            XCTAssertEqual(transition.phase, .queued)
            XCTAssertTrue(transition.commandTransmitted(command, model: model, session: 7))
            XCTAssertEqual(transition.phase, .awaitingResult)
            XCTAssertNil(transition.expectedPayload)
            for packet in [[], [0x3D, 1, 0] + Array(secondAddress.utf8), Array(success.dropLast()), success + [0],
                           result(action, address: firstAddress), result(action == .connect ? .disconnect : .connect),
                           result(action, value: action == .connect ? 0 : 0x10)] {
                XCTAssertFalse(transition.receive(packet, model: model, session: 7))
                XCTAssertEqual(transition.phase, .awaitingResult)
            }
            XCTAssertFalse(transition.receive(success, model: model, session: 8))
            for _ in 0..<2 {
                XCTAssertTrue(transition.receive(result(action, value: action.rawValue * 16 + 2), model: model, session: 7))
                XCTAssertEqual(transition.phase, .awaitingResult)
                XCTAssertNil(transition.expectedPayload)
            }
            XCTAssertTrue(transition.receive(success, model: model, session: 7))
            XCTAssertEqual(transition.phase, .queuedReadback)
            XCTAssertEqual(transition.expectedPayload, [0x36, 2])
            let readback = inventory(secondConnection: action == .connect ? 2 : 0)
            XCTAssertFalse(transition.receive(readback, model: model, session: 7, readbackOwned: true))
            XCTAssertTrue(transition.commandTransmitted([0x36, 2], model: model, session: 7))
            XCTAssertEqual(transition.phase, .verifying)
            XCTAssertFalse(transition.receive(readback, model: model, session: 7))
            XCTAssertFalse(transition.receive(readback, model: model, session: 8, readbackOwned: true))
            var notification = readback
            notification[0] = 0x39
            XCTAssertFalse(transition.receive(notification, model: model, session: 7, readbackOwned: true))
            XCTAssertTrue(transition.receive(readback, model: model, session: 7, readbackOwned: true))
            XCTAssertEqual(transition.phase, .complete)
            XCTAssertTrue(transition.isFinished)
            XCTAssertNil(transition.expectedPayload)
            XCTAssertNil(transition.failureMessage)
            XCTAssertFalse(transition.receive(success, model: model, session: 7))
            XCTAssertFalse(transition.timeout())
            XCTAssertEqual(model.devices.last?.isConnected, action == .disconnect)
        }
    }

    func testUnavailableUnknownFullAndUnsupportedRequestsAreRejected() {
        let model = readyModel()
        XCTAssertNil(SonyDeviceActionTransition(action: .unpair, targetAddress: secondAddress, model: model, session: 7))
        XCTAssertNil(SonyDeviceActionTransition(action: .connect, targetAddress: firstAddress, model: model, session: 7))
        XCTAssertNil(SonyDeviceActionTransition(action: .disconnect, targetAddress: secondAddress, model: model, session: 7))
        for address in ["00:00:00:00:00:99", "not an address"] {
            XCTAssertNil(SonyDeviceActionTransition(action: .connect, targetAddress: address, model: model, session: 7))
        }
        for functions: Set<UInt8> in [[], [0x30], [0x31], [0x34]] {
            XCTAssertNil(SonyDeviceActionTransition(action: .connect, targetAddress: secondAddress, model: SonyMultipoint(supportedFunctions: functions), session: 7))
        }
        var unknownCapacity = SonyMultipoint(supportedFunctions: [0x32])
        XCTAssertTrue(unknownCapacity.update([0x33, 2, 0, 0]))
        XCTAssertTrue(unknownCapacity.update(inventory()))
        XCTAssertNil(unknownCapacity.peripheralActionPayload(.connect, address: secondAddress))
        XCTAssertNil(SonyDeviceActionTransition(action: .connect, targetAddress: secondAddress, model: unknownCapacity, session: 7))
        XCTAssertTrue(unknownCapacity.update([0x31, 2, 8, 2, 0]))
        XCTAssertNotNil(SonyDeviceActionTransition(action: .connect, targetAddress: secondAddress, model: unknownCapacity, session: 7))
        XCTAssertNotNil(SonyDeviceActionTransition(action: .disconnect, targetAddress: firstAddress, model: unknownCapacity, session: 7))
        for maximum: UInt8 in [0, 1] {
            var full = model
            XCTAssertTrue(full.update([0x31, 2, 8, maximum, 0]))
            XCTAssertNil(full.peripheralActionPayload(.connect, address: secondAddress))
            XCTAssertNil(SonyDeviceActionTransition(action: .connect, targetAddress: secondAddress, model: full, session: 7))
        }
        for status: [UInt8] in [[0x35, 2, 0, 1], [0x35, 2, 0, 0xFF], [0x35, 2, 0xFF, 0], [0x37, 2]] {
            var unavailable = model
            unavailable.update(status)
            XCTAssertNil(SonyDeviceActionTransition(action: .connect, targetAddress: secondAddress, model: unavailable, session: 7))
            XCTAssertNil(SonyDeviceActionTransition(action: .disconnect, targetAddress: firstAddress, model: unavailable, session: 7))
        }
    }

    func testQueuedActionsRevalidateTargetStatusCapacityAndInventoryBeforeWriting() throws {
        for action in [SonyPeripheralAction.connect, .disconnect] {
            let original = readyModel(secondConnection: action == .connect ? 0 : 2)
            var changes: [[UInt8]] = [[0x35, 2, 0, 1], [0x37, 2], inventory(includeSecond: false),
                                     inventory(secondConnection: action == .connect ? 2 : 0)]
            if action == .connect { changes.append([0x31, 2, 8, 1, 0]) }
            for payload in changes {
                var model = original
                var transition = try XCTUnwrap(SonyDeviceActionTransition(action: action, targetAddress: secondAddress, model: model, session: 7))
                let command = try XCTUnwrap(transition.expectedPayload)
                model.update(payload)
                XCTAssertFalse(transition.commandTransmitted(command, model: model, session: 7))
                XCTAssertEqual(transition.phase, .failed)
                XCTAssertNil(transition.expectedPayload)
                XCTAssertNotNil(transition.failureMessage)
                XCTAssertFalse(transition.commandTransmitted(command, model: original, session: 7))
            }
        }
    }

    func testFailuresBusyAndUnknownResultsAreTerminalWithoutReadbackOrReplay() throws {
        for action in [SonyPeripheralAction.connect, .disconnect] {
            let model = readyModel(secondConnection: action == .connect ? 0 : 2)
            for value in [action.rawValue * 16 + 1, action.rawValue * 16 + 3, 0xFF] {
                var transition = try awaitingResult(action: action, model: model)
                XCTAssertTrue(transition.receive(result(action, value: value), model: model, session: 7))
                XCTAssertEqual(transition.phase, .failed)
                XCTAssertTrue(transition.isFinished)
                XCTAssertNotNil(transition.failureMessage)
                XCTAssertNil(transition.expectedPayload)
                let finished = transition
                XCTAssertFalse(transition.receive(result(action), model: model, session: 7))
                XCTAssertFalse(transition.controlLost(session: 7))
                XCTAssertFalse(transition.capabilitiesChanged(session: 7))
                XCTAssertFalse(transition.timeout())
                XCTAssertEqual(transition, finished)
            }
        }
    }

    func testOwnedReadbackRequiresTargetStillPairedWithRequestedConnectionState() throws {
        for action in [SonyPeripheralAction.connect, .disconnect] {
            let model = readyModel(secondConnection: action == .connect ? 0 : 2)
            for packet in [[0x37, 2], inventory(includeSecond: false), inventory(secondConnection: action == .connect ? 0 : 2)] {
                var transition = try awaitingReadback(action: action, model: model)
                XCTAssertTrue(transition.receive(packet, model: model, session: 7, readbackOwned: true))
                XCTAssertEqual(transition.phase, .failed)
                XCTAssertNotNil(transition.failureMessage)
                XCTAssertNil(transition.expectedPayload)
            }
            var transition = try awaitingReadback(action: action, model: model)
            var unavailable = model
            XCTAssertTrue(unavailable.update([0x35, 2, 0, 1]))
            XCTAssertTrue(transition.receive(inventory(secondConnection: action == .connect ? 2 : 0), model: unavailable, session: 7, readbackOwned: true))
            XCTAssertEqual(transition.phase, .failed)
        }
    }

    func testMatchingFailureAfterSuccessCannotBeOverriddenByInventory() throws {
        for action in [SonyPeripheralAction.connect, .disconnect] {
            let model = readyModel(secondConnection: action == .connect ? 0 : 2)
            var queuedReadback = try awaitingResult(action: action, model: model)
            XCTAssertTrue(queuedReadback.receive(result(action), model: model, session: 7))
            for initial in [queuedReadback, try awaitingReadback(action: action, model: model)] {
                var duplicate = initial
                XCTAssertFalse(duplicate.receive(result(action), model: model, session: 7))
                XCTAssertFalse(duplicate.receive(result(action, value: action.rawValue * 16 + 2), model: model, session: 7))
                XCTAssertEqual(duplicate, initial)
                for value in [action.rawValue * 16 + 1, action.rawValue * 16 + 3, 0xFF] {
                    var transition = initial
                    var received = model
                    let failure = result(action, value: value)
                    XCTAssertTrue(received.update(failure))
                    XCTAssertTrue(transition.receive(failure, model: received, session: 7))
                    XCTAssertEqual(transition.phase, .failed)
                    let finished = transition
                    let readback = inventory(secondConnection: action == .connect ? 2 : 0)
                    XCTAssertTrue(received.update(readback))
                    XCTAssertFalse(transition.receive(readback, model: received, session: 7, readbackOwned: true))
                    XCTAssertEqual(transition, finished)
                    XCTAssertNil(transition.expectedPayload)
                }
            }
        }
    }

    func testConnectionConfirmationDoesNotSelectSourceOrReleaseKeeping() throws {
        var model = readyModel()
        XCTAssertTrue(model.update([0x37, 1, 0]))
        for selected: UInt8 in [0, 1, 2] {
            var transition = try awaitingReadback(action: .connect, model: model)
            XCTAssertTrue(transition.receive(inventory(secondConnection: 2, selected: selected), model: model, session: 7, readbackOwned: true))
            XCTAssertEqual(transition.phase, .complete)
            XCTAssertNil(transition.expectedPayload)
            XCTAssertEqual(model.selectedSource?.address, firstAddress)
            XCTAssertEqual(model.keeping, true)
        }
        var disconnect = try XCTUnwrap(SonyDeviceActionTransition(action: .disconnect, targetAddress: firstAddress, model: model, session: 7))
        XCTAssertTrue(disconnect.commandTransmitted([0x3C, 2, 0] + Array(firstAddress.utf8), model: model, session: 7))
        XCTAssertTrue(disconnect.receive(result(.disconnect, address: firstAddress), model: model, session: 7))
        XCTAssertTrue(disconnect.commandTransmitted([0x36, 2], model: model, session: 7))
        XCTAssertTrue(disconnect.receive(inventory(firstConnection: 0, selected: 0), model: model, session: 7, readbackOwned: true))
        XCTAssertEqual(disconnect.phase, .complete)
    }

    func testDeadlineCoversProgressQueuedReadbackAndVerificationWithoutReplay() throws {
        let model = readyModel()
        var queued = try XCTUnwrap(SonyDeviceActionTransition(action: .connect, targetAddress: secondAddress, model: model, session: 7))
        XCTAssertFalse(queued.timeout())
        var pending = try awaitingResult(action: .connect, model: model)
        XCTAssertTrue(pending.receive(result(.connect, value: 0x12), model: model, session: 7))
        var queuedReadback = pending
        XCTAssertTrue(queuedReadback.receive(result(.connect), model: model, session: 7))
        for initial in [pending, queuedReadback, try awaitingReadback(action: .connect, model: model)] {
            var transition = initial
            XCTAssertTrue(transition.timeout())
            XCTAssertEqual(transition.phase, .failed)
            XCTAssertNil(transition.expectedPayload)
            XCTAssertFalse(transition.receive(result(.connect), model: model, session: 7))
            XCTAssertFalse(transition.receive(inventory(secondConnection: 2), model: model, session: 7, readbackOwned: true))
            XCTAssertFalse(transition.validateForTransmission(model: model, session: 8))
        }
    }

    func testControlLossAndCapabilityChangeTerminateOnlyTheOwningSession() throws {
        let model = readyModel()
        let queued = try XCTUnwrap(SonyDeviceActionTransition(action: .connect, targetAddress: secondAddress, model: model, session: 7))
        var queuedReadback = try awaitingResult(action: .connect, model: model)
        XCTAssertTrue(queuedReadback.receive(result(.connect), model: model, session: 7))
        for initial in [queued, try awaitingResult(action: .connect, model: model), queuedReadback, try awaitingReadback(action: .connect, model: model)] {
            for lost in [true, false] {
                var transition = initial
                XCTAssertFalse(lost ? transition.controlLost(session: 8) : transition.capabilitiesChanged(session: 8))
                XCTAssertEqual(transition, initial)
                XCTAssertTrue(lost ? transition.controlLost(session: 7) : transition.capabilitiesChanged(session: 7))
                XCTAssertEqual(transition.phase, .failed)
                XCTAssertNil(transition.expectedPayload)
                XCTAssertFalse(transition.commandTransmitted([0x3C, 2, 1] + Array(secondAddress.utf8), model: model, session: 8))
            }
        }
        XCTAssertFalse(queuedReadback.validateForTransmission(model: SonyMultipoint(), session: 7))
        XCTAssertEqual(queuedReadback.phase, .failed)
    }

    private let firstAddress = "00:11:22:33:44:55"
    private let secondAddress = "AA:BB:CC:DD:EE:FF"

    private func readyModel(secondConnection: UInt8 = 0) -> SonyMultipoint {
        var model = SonyMultipoint(supportedFunctions: [0x31, 0x32])
        for payload in [[0x31, 2, 8, 2, 0], [0x33, 2, 0, 0], inventory(secondConnection: secondConnection), [0x37, 1, 1]] {
            XCTAssertTrue(model.update(payload))
        }
        return model
    }

    private func inventory(firstConnection: UInt8 = 1, secondConnection: UInt8 = 0, selected: UInt8 = 1, includeSecond: Bool = true) -> [UInt8] {
        var payload: [UInt8] = [0x37, 2, includeSecond ? 2 : 1]
        payload += Array(firstAddress.utf8) + [firstConnection, 0, 0, 0, 1, 0x41]
        if includeSecond { payload += Array(secondAddress.utf8) + [secondConnection, 0, 0, 0, 1, 0x42] }
        return payload + [selected]
    }

    private func result(_ action: SonyPeripheralAction, value: UInt8? = nil, address: String? = nil) -> [UInt8] {
        [0x3D, 2, action.rawValue, value ?? action.rawValue * 16] + Array((address ?? secondAddress).utf8)
    }

    private func awaitingResult(action: SonyPeripheralAction, model: SonyMultipoint) throws -> SonyDeviceActionTransition {
        var transition = try XCTUnwrap(SonyDeviceActionTransition(action: action, targetAddress: secondAddress, model: model, session: 7))
        XCTAssertTrue(transition.commandTransmitted(try XCTUnwrap(transition.expectedPayload), model: model, session: 7))
        return transition
    }

    private func awaitingReadback(action: SonyPeripheralAction, model: SonyMultipoint) throws -> SonyDeviceActionTransition {
        var transition = try awaitingResult(action: action, model: model)
        XCTAssertTrue(transition.receive(result(action), model: model, session: 7))
        XCTAssertTrue(transition.commandTransmitted([0x36, 2], model: model, session: 7))
        return transition
    }
}

final class SonyDeviceActionControllerTests: XCTestCase {
    @MainActor
    func testDisconnectRequiresMatchingResultAndOwnedReadbackWithoutSourceCommands() throws {
        let controller = preparedController()
        let phone = try XCTUnwrap(controller.multipoint.devices.last)
        controller.changeDeviceConnection(.disconnect, device: phone)
        XCTAssertEqual(controller.deviceActionTransition?.phase, .awaitingResult)
        XCTAssertTrue(controller.simulatedDeviceActionTimeoutPending)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x3C, 2, 0] + Array(phone.address.utf8))
        XCTAssertFalse(controller.canControlPlayback)
        XCTAssertFalse(controller.canRefreshSoundPressure)
        XCTAssertFalse(controller.canRefreshDevices)
        XCTAssertNotNil(controller.sourceControlUnavailableReason)
        XCTAssertNotNil(controller.connectionModeUnavailableReason(.stableConnection))
        XCTAssertNotNil(controller.multipointUnavailableReason)
        controller.setDSEE(.off)
        controller.setMultipointEnabled(false)
        controller.selectAudioSource(phone)
        controller.setSourceKeeping(true)
        XCTAssertNil(controller.multipointTransition)
        XCTAssertNil(controller.sourceTransition)
        deliver(result(address: phone.address, value: 2), to: controller)
        deliver(result(address: phone.address, value: 0), type: 0x0C, to: controller)
        deliver(result(address: "02:00:00:00:00:01", value: 0), to: controller)
        XCTAssertEqual(controller.deviceActionTransition?.phase, .awaitingResult)
        deliver(result(address: phone.address, value: 0), to: controller)
        XCTAssertEqual(controller.deviceActionTransition?.phase, .queuedReadback)
        deliver(inventory(secondConnection: 0), to: controller)
        XCTAssertEqual(controller.deviceActionTransition?.phase, .queuedReadback)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.deviceActionTransition?.phase, .verifying)
        XCTAssertTrue(controller.simulatedDeviceActionTimeoutPending)
        deliver(inventory(command: 0x39, secondConnection: 0), to: controller)
        XCTAssertEqual(controller.deviceActionTransition?.phase, .verifying)
        deliver(inventory(secondConnection: 0), to: controller)
        XCTAssertEqual(controller.deviceActionTransition?.phase, .complete)
        XCTAssertFalse(controller.simulatedDeviceActionTimeoutPending)
        XCTAssertFalse(controller.simulatedInventoryReadPending)
        XCTAssertEqual(controller.multipoint.selectedSource?.connectionID, 1)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload.first == 0x3C }.map(\.payload),
                       [[0x3C, 2, 0] + Array(phone.address.utf8)])
        XCTAssertFalse(controller.simulatedTransmittedFrames.contains { $0.type == 0x0E && $0.payload.prefix(2) == [0x38, 1] })
        controller.simulateControlLoss()
    }

    @MainActor
    func testTerminalFailureCannotBeOverwrittenByAlreadyQueuedInventoryRead() throws {
        let controller = preparedController()
        let phone = try XCTUnwrap(controller.multipoint.devices.last)
        controller.changeDeviceConnection(.disconnect, device: phone)
        deliver(result(address: phone.address, value: 0), to: controller)
        XCTAssertEqual(controller.deviceActionTransition?.phase, .queuedReadback)
        XCTAssertTrue(controller.simulatedInventoryReadPending)
        deliver(result(address: phone.address, value: 3), to: controller)
        let failed = try XCTUnwrap(controller.deviceActionTransition)
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertFalse(controller.simulatedDeviceActionTimeoutPending)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == [0x36, 2] }.count, 1)
        deliver(inventory(secondConnection: 0), to: controller)
        XCTAssertEqual(controller.deviceActionTransition, failed)
        XCTAssertFalse(controller.simulatedInventoryReadPending)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload.first == 0x3C }.count, 1)
        controller.simulateControlLoss()
    }

    @MainActor
    func testCapacityAndExistingReadBlockConnectUntilFreshInventoryAndFreeSlot() throws {
        let controller = preparedController()
        deliver(inventory(includeSaved: true), to: controller)
        let tablet = try XCTUnwrap(controller.multipoint.devices.last)
        XCTAssertNotNil(controller.deviceActionUnavailableReason(.connect, device: tablet))
        controller.changeDeviceConnection(.connect, device: tablet)
        XCTAssertNil(controller.deviceActionTransition)
        controller.refreshDevices()
        acknowledgeAll(controller)
        deliver(inventory(command: 0x39, secondConnection: 0, includeSaved: true), to: controller)
        controller.changeDeviceConnection(.connect, device: tablet)
        XCTAssertNil(controller.deviceActionTransition)
        deliver(inventory(secondConnection: 0, includeSaved: true), to: controller)
        XCTAssertNil(controller.deviceActionUnavailableReason(.connect, device: tablet))
        controller.changeDeviceConnection(.connect, device: tablet)
        acknowledgeAll(controller)
        XCTAssertEqual(controller.deviceActionTransition?.phase, .awaitingResult)
        deliver([0x3D, 2, 1, 0x10] + Array(tablet.address.utf8), to: controller)
        acknowledgeAll(controller)
        deliver(inventory(secondConnection: 0, includeSaved: true, savedConnection: 2), to: controller)
        XCTAssertEqual(controller.deviceActionTransition?.phase, .complete)
        XCTAssertEqual(controller.multipoint.selectedSource?.connectionID, 1)
        controller.simulateControlLoss()
    }

    @MainActor
    func testConnectProgressKeepsDeadlineAndTimeoutRefreshesInventoryWithoutClosingControls() throws {
        let controller = preparedController()
        deliver(inventory(secondConnection: 0), to: controller)
        let phone = try XCTUnwrap(controller.multipoint.devices.last)
        let session = controller.simulatedControlSession
        controller.changeDeviceConnection(.connect, device: phone)
        acknowledgeAll(controller)
        for _ in 0..<3 { deliver([0x3D, 2, 1, 0x12] + Array(phone.address.utf8), to: controller) }
        XCTAssertEqual(controller.deviceActionTransition?.phase, .awaitingResult)
        XCTAssertTrue(controller.simulatedDeviceActionTimeoutPending)
        controller.simulateDeviceActionTimeout()
        let failed = try XCTUnwrap(controller.deviceActionTransition)
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertFalse(controller.simulatedDeviceActionTimeoutPending)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x36, 2])
        acknowledgeAll(controller)
        deliver(inventory(), to: controller)
        XCTAssertEqual(controller.deviceActionTransition, failed)
        XCTAssertTrue(controller.multipoint.devices.last?.isConnected == true)
        XCTAssertFalse(controller.simulatedInventoryReadPending)
        controller.simulateAutomaticRefresh()
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.simulatedControlSession, session)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload.prefix(2) == [0x3C, 2] }.map(\.payload),
                       [[0x3C, 2, 1] + Array(phone.address.utf8)])
        controller.simulateControlLoss()
    }

    @MainActor
    func testConnectControlLossAllowsOnlyTwoRecoveryAttemptsWithoutReplayingAction() throws {
        let controller = preparedController()
        deliver(inventory(secondConnection: 0), to: controller)
        let phone = try XCTUnwrap(controller.multipoint.devices.last)
        controller.changeDeviceConnection(.connect, device: phone)
        acknowledgeAll(controller)
        controller.simulateControlLoss()
        let failed = try XCTUnwrap(controller.deviceActionTransition)
        XCTAssertEqual(failed.phase, .failed)
        for _ in 0..<2 {
            controller.simulateAutomaticRefresh()
            XCTAssertEqual(controller.linkState, .handshaking)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x00, 0x00])
            XCTAssertTrue(controller.simulatedHandshakeTimeoutPending)
            controller.simulateControlLoss()
        }
        let transmitted = controller.simulatedTransmittedFrames
        for _ in 0..<40 { controller.simulateAutomaticRefresh() }
        XCTAssertFalse(controller.isReady)
        XCTAssertNil(controller.simulatedPendingFrame)
        XCTAssertFalse(controller.simulatedHandshakeTimeoutPending)
        XCTAssertEqual(controller.simulatedTransmittedFrames, transmitted)
        XCTAssertEqual(controller.deviceActionTransition, failed)
        XCTAssertEqual(transmitted.filter { $0.type == 0x0E && $0.payload.prefix(2) == [0x3C, 2] }.map(\.payload),
                       [[0x3C, 2, 1] + Array(phone.address.utf8)])
        controller.simulateControlLoss()
    }

    @MainActor
    func testConnectBLERecoveryUsesTwoBoundedAttemptsWithoutReplayingAction() throws {
        let ordinary = preparedController()
        XCTAssertTrue(ordinary.simulateBLEReconnectWait(automatic: true, priorBluetoothLE: true, classicConnected: true))
        XCTAssertTrue(ordinary.simulatedBLEWaitsForConnection)
        ordinary.simulateControlLoss()

        let controller = preparedController()
        deliver(inventory(secondConnection: 0), to: controller)
        let phone = try XCTUnwrap(controller.multipoint.devices.last)
        controller.changeDeviceConnection(.connect, device: phone)
        acknowledgeAll(controller)
        controller.simulateControlLoss()
        for _ in 0..<2 {
            XCTAssertTrue(controller.simulateBLEReconnectWait(automatic: true, priorBluetoothLE: true, classicConnected: true))
            XCTAssertEqual(controller.linkState, .opening)
            XCTAssertFalse(controller.simulatedBLEWaitsForConnection)
            controller.simulateBLEDisconnect("The headphone connection timed out.")
            XCTAssertFalse(controller.usesBluetoothLE)
        }
        XCTAssertFalse(controller.simulateBLEReconnectWait(automatic: true, priorBluetoothLE: true, classicConnected: true))
        XCTAssertFalse(controller.usesBluetoothLE)
        XCTAssertEqual(controller.deviceActionTransition?.phase, .failed)
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload.prefix(2) == [0x3C, 2] }.map(\.payload),
                       [[0x3C, 2, 1] + Array(phone.address.utf8)])
        controller.simulateControlLoss()
    }

    @MainActor
    func testConnectRecoverySuccessRestoresOrdinaryControlRecovery() throws {
        for failedAttempts in 0..<2 {
            let controller = preparedController()
            deliver(inventory(secondConnection: 0), to: controller)
            let phone = try XCTUnwrap(controller.multipoint.devices.last)
            controller.changeDeviceConnection(.connect, device: phone)
            acknowledgeAll(controller)
            controller.simulateControlLoss()
            for _ in 0..<failedAttempts {
                controller.simulateAutomaticRefresh()
                XCTAssertEqual(controller.linkState, .handshaking)
                controller.simulateControlLoss()
            }
            controller.simulateAutomaticRefresh()
            XCTAssertEqual(controller.linkState, .handshaking)
            acknowledgeAll(controller)
            deliver([0x01, 0x00, 0x03, 0x00, 0x30, 0x18, 0x00, 0x00], type: 0x0C, to: controller)
            acknowledgeAll(controller)
            let functions: [UInt8] = [0x6B, 0x14, 0x90, 0xE7]
            deliver([0x07, 0, UInt8(functions.count)] + functions.flatMap { [$0, 0] }, type: 0x0C, to: controller)
            acknowledgeAll(controller)
            deliver([0x61, 0x17, 2, 0, 1, 20, 1, 1, 1, 20, 1], type: 0x0C, to: controller)
            deliver([0x63, 0x17, 0], type: 0x0C, to: controller)
            acknowledgeAll(controller)
            deliver([0x67, 0x17, 0x01, 0x01, 0, 0, 10], type: 0x0C, to: controller)
            XCTAssertTrue(controller.isReady)
            XCTAssertNil(controller.deviceActionTransition)
            XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.type == 0x0E && $0.payload.prefix(2) == [0x3C, 2] }.map(\.payload),
                           [[0x3C, 2, 1] + Array(phone.address.utf8)])
            controller.simulateControlLoss()
            controller.simulateAutomaticRefresh()
            XCTAssertEqual(controller.linkState, .handshaking)
            XCTAssertEqual(controller.simulatedPendingFrame?.payload, [0x00, 0x00])
            controller.simulateControlLoss()
        }
    }

    @MainActor
    func testControlLossBeforeWriteCompletionAndLateRepliesCannotFinishOrReplayAction() throws {
        let controller = preparedController()
        let mac = try XCTUnwrap(controller.multipoint.devices.first)
        let session = controller.simulatedControlSession
        controller.defersSimulatedWrites = true
        controller.changeDeviceConnection(.disconnect, device: mac)
        XCTAssertEqual(controller.deviceActionTransition?.phase, .queued)
        XCTAssertFalse(controller.simulatedDeviceActionTimeoutPending)
        controller.simulateControlLoss()
        let failed = controller.deviceActionTransition
        XCTAssertEqual(failed?.phase, .failed)
        controller.completeSimulatedWrite()
        XCTAssertFalse(controller.simulatedDeviceActionTimeoutPending)
        controller.simulateProtocolMessage(result(address: mac.address, value: 0), type: 0x0E, session: session)
        XCTAssertEqual(controller.deviceActionTransition, failed)
        XCTAssertNil(controller.simulatedPendingFrame)
        controller.simulateAutomaticRefresh()
        XCTAssertNil(controller.simulatedPendingFrame)
    }

    @MainActor
    func testActionInvalidatesListeningLevelAndRejectsOldOwnedReply() throws {
        let controller = preparedController()
        let phone = try XCTUnwrap(controller.multipoint.devices.last)
        controller.refreshSoundPressure()
        acknowledgeAll(controller)
        controller.changeDeviceConnection(.disconnect, device: phone)
        XCTAssertEqual(controller.deviceActionTransition?.phase, .awaitingResult)
        deliver([0x5B, 3, 80, 0xFF], to: controller)
        XCTAssertNil(controller.soundPressure.reading)
        XCTAssertFalse(controller.isReadingSoundPressure)
        XCTAssertFalse(controller.canRefreshSoundPressure)
        let reads = controller.simulatedTransmittedFrames.filter { $0.payload == SonySoundPressure.levelQueryPayload }.count
        controller.refreshSoundPressure()
        XCTAssertEqual(controller.simulatedTransmittedFrames.filter { $0.payload == SonySoundPressure.levelQueryPayload }.count, reads)
        controller.simulateControlLoss()
    }

    @MainActor
    private func preparedController() -> SonyHeadphonesController {
        let controller = SonyHeadphonesController(startAutomatically: false, simulated: true)
        controller.simulateDeviceConnection(named: "WF-1000XM5")
        return controller
    }

    @MainActor
    private func acknowledgeAll(_ controller: SonyHeadphonesController) {
        var count = 0
        while let frame = controller.simulatedPendingFrame, count < 50 {
            controller.simulateProtocolData(SonyFrameCodec.encode(type: 1, sequence: 1 - frame.sequence, payload: []))
            count += 1
        }
        XCTAssertNil(controller.simulatedPendingFrame)
    }

    @MainActor
    private func deliver(_ payload: [UInt8], type: UInt8 = 0x0E, to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload, type: type)
    }

    private func result(address: String, value: UInt8) -> [UInt8] {
        [0x3D, 2, 0, value] + Array(address.utf8)
    }

    private func inventory(command: UInt8 = 0x37, secondConnection: UInt8 = 2, includeSaved: Bool = false, savedConnection: UInt8 = 0) -> [UInt8] {
        var payload: [UInt8] = [command, 2, includeSaved ? 3 : 2]
        payload += Array("02:00:00:00:00:01".utf8) + [1, 0, 0, 0, 1, 0x41]
        payload += Array("02:00:00:00:00:02".utf8) + [secondConnection, 0, 0, 0, 1, 0x42]
        if includeSaved { payload += Array("02:00:00:00:00:03".utf8) + [savedConnection, 0, 0, 0, 1, 0x43] }
        return payload + [1]
    }
}
