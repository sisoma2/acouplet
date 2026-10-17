import XCTest
@testable import Acouplet

final class SonyDeviceCoordinatorTests: XCTestCase {
    private let firstAddress = "02:53:4F:4E:59:01"
    private let secondAddress = "02:53:4F:4E:59:02"

    @MainActor
    func testDevicePickerLabelsDistinguishSameModelWithoutChangingRouting() throws {
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let second = try device(secondAddress, name: "WF-1000XM5", model: .wfXM5)
        XCTAssertEqual(ConnectedHeadphonePicker.title(for: first, among: [first]), "WF-1000XM5")
        XCTAssertEqual(ConnectedHeadphonePicker.title(for: first, among: [first, second]), "WF-1000XM5 · 59:01")
        XCTAssertEqual(ConnectedHeadphonePicker.title(for: second, among: [first, second]), "WF-1000XM5 · 59:02")
        let renamed = try device(secondAddress, name: "Travel earbuds", model: .wfXM5)
        XCTAssertEqual(ConnectedHeadphonePicker.title(for: renamed, among: [first, renamed]), "Travel earbuds · 59:02")
        let sameSuffix = try device("02:54:4F:4E:59:01", name: first.name, model: first.model)
        let peers = [first, second, sameSuffix]
        XCTAssertEqual(ConnectedHeadphonePicker.title(for: first, among: peers), "WF-1000XM5 · \(first.address)")
        XCTAssertEqual(ConnectedHeadphonePicker.title(for: sameSuffix, among: peers), "WF-1000XM5 · \(sameSuffix.address)")
        XCTAssertEqual(ConnectedHeadphonePicker.title(for: second, among: peers), "WF-1000XM5 · 59:02")
        let coordinator = makeCoordinator()
        coordinator.reconcileConnectedDevices([first, second])
        defer { coordinator.controllers.forEach { $0.simulateControlLoss() } }
        coordinator.select(address: second.address)
        XCTAssertEqual(coordinator.selectedController.address, second.address)
        XCTAssertEqual(coordinator.selectedAddress, second.address)
    }

    @MainActor
    func testSelectionIsDeterministicAndSwitchingAppearsOnlyForMultipleConnectedDevices() throws {
        let coordinator = makeCoordinator()
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let second = try device(secondAddress, name: "WH-1000XM6", model: .whXM6)
        coordinator.reconcileConnectedDevices([second, first, first])
        defer { coordinator.controllers.forEach { $0.simulateControlLoss() } }
        XCTAssertEqual(coordinator.connectedDevices.map(\.address), [firstAddress, secondAddress])
        XCTAssertEqual(coordinator.controllers.count, 2)
        XCTAssertEqual(coordinator.selectedAddress, firstAddress)
        XCTAssertTrue(coordinator.hasMultipleConnectedDevices)
        let firstController = try XCTUnwrap(coordinator.controller(for: firstAddress))
        let secondController = try XCTUnwrap(coordinator.controller(for: secondAddress))
        coordinator.select(address: secondAddress.replacingOccurrences(of: ":", with: "-").lowercased())
        XCTAssertTrue(coordinator.selectedController === secondController)
        coordinator.reconcileConnectedDevices([first, second])
        XCTAssertTrue(coordinator.selectedController === secondController)
        coordinator.reconcileConnectedDevices([first])
        XCTAssertFalse(coordinator.hasMultipleConnectedDevices)
        XCTAssertTrue(coordinator.selectedController === firstController)
        coordinator.select(address: secondAddress)
        XCTAssertTrue(coordinator.selectedController === firstController)
        coordinator.reconcileConnectedDevices([])
        XCTAssertFalse(coordinator.hasMultipleConnectedDevices)
        XCTAssertTrue(coordinator.selectedController === firstController)
        XCTAssertEqual(coordinator.controllers.count, 2)
        coordinator.reconcileConnectedDevices([second, first])
        XCTAssertTrue(coordinator.controller(for: firstAddress) === firstController)
        XCTAssertTrue(coordinator.controller(for: secondAddress) === secondController)
    }

    #if !ACOUPLET_PUBLIC_APIS_ONLY
    @MainActor
    func testLDACHandoffRetainsDeviceAndMenuUntilOwnershipEnds() throws {
        for running in [false, true] {
            for state in [LDACState.requested, .connecting, .active(.init(sampleRateHz: 48_000, bitrateKbps: 330, channels: 2)), .stopping] {
                XCTAssertTrue(state.keepsMenuBarVisible(isSessionRunning: running))
            }
            XCTAssertFalse(LDACState.off.keepsMenuBarVisible(isSessionRunning: running))
            XCTAssertFalse(LDACState.waitingForDevice.keepsMenuBarVisible(isSessionRunning: running))
            XCTAssertEqual(LDACState.failed("Test").keepsMenuBarVisible(isSessionRunning: running), running)
        }
        let coordinator = makeCoordinator(connected: false)
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let second = try device(secondAddress, name: "WH-1000XM6", model: .whXM6)
        coordinator.reconcilePairedDevices([first, second], connectedAddresses: [firstAddress, secondAddress])
        coordinator.setReconnectAutomatically(true, suppressing: firstAddress)
        coordinator.reconcilePairedDevices([first, second], connectedAddresses: [secondAddress])
        XCTAssertEqual(coordinator.selectedAddress, firstAddress)
        XCTAssertFalse(coordinator.selectedController.simulatedReconnectAutomatically)
        coordinator.select(address: secondAddress)
        XCTAssertEqual(coordinator.selectedAddress, secondAddress)
        coordinator.setReconnectAutomatically(true)
        XCTAssertTrue(try XCTUnwrap(coordinator.controller(for: firstAddress)).simulatedReconnectAutomatically)
    }
    #endif

    @MainActor
    func testPairedDisconnectedDeviceRemainsSelectableWithoutMultiDeviceUI() throws {
        let coordinator = makeCoordinator(connected: false)
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let second = try device(secondAddress, name: "WH-1000XM6", model: .whXM6)
        coordinator.reconcilePairedDevices([second, first], connectedAddresses: [])
        XCTAssertEqual(coordinator.selectedAddress, firstAddress)
        XCTAssertEqual(coordinator.selectedController.pinnedAddress, firstAddress)
        XCTAssertEqual(coordinator.connectedDevices, [])
        XCTAssertFalse(coordinator.hasMultipleConnectedDevices)
        XCTAssertFalse(coordinator.selectedController.isDeviceConnected)
        coordinator.reconcilePairedDevices([first, second], connectedAddresses: [secondAddress])
        XCTAssertEqual(coordinator.selectedAddress, secondAddress)
        XCTAssertFalse(coordinator.hasMultipleConnectedDevices)
        coordinator.reconcilePairedDevices([], connectedAddresses: [])
        XCTAssertEqual(coordinator.selectedAddress, secondAddress)
    }

    @MainActor
    func testPairedDisconnectedHeadphonesCanBeChosenBeforeRetryAndKeepSelection() throws {
        let coordinator = makeCoordinator(connected: false)
        let earbuds = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let headphones = try device(secondAddress, name: "WH-1000XM5", model: .whXM5)
        coordinator.reconcilePairedDevices([earbuds, headphones], connectedAddresses: [])
        XCTAssertEqual(coordinator.selectableDevices.map(\.address), [firstAddress, secondAddress])
        XCTAssertTrue(coordinator.hasOtherSelectableDevices)
        coordinator.select(address: secondAddress)
        XCTAssertEqual(coordinator.selectedController.pinnedAddress, secondAddress)
        coordinator.reconcilePairedDevices([earbuds, headphones], connectedAddresses: [firstAddress])
        XCTAssertEqual(coordinator.selectedAddress, secondAddress)
        coordinator.reconcilePairedDevices([earbuds, headphones], connectedAddresses: [firstAddress, secondAddress])
        XCTAssertEqual(coordinator.selectedAddress, secondAddress)
        coordinator.reconcilePairedDevices([earbuds, headphones], connectedAddresses: [firstAddress])
        XCTAssertEqual(coordinator.selectedAddress, firstAddress)
        coordinator.select(address: secondAddress)
        coordinator.reconcilePairedDevices([earbuds], connectedAddresses: [firstAddress])
        XCTAssertEqual(coordinator.selectableDevices.map(\.address), [firstAddress])
        XCTAssertEqual(coordinator.selectedAddress, firstAddress)
        coordinator.select(address: secondAddress)
        XCTAssertEqual(coordinator.selectedAddress, firstAddress)
    }

    @MainActor
    func testUnfinishedHeadphoneWorkflowRetainsContextWhenAnotherDeviceConnects() throws {
        let coordinator = makeCoordinator()
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let second = try device(secondAddress, name: "WH-1000XM6", model: .whXM6)
        coordinator.reconcileConnectedDevices([first])
        let controller = coordinator.selectedController
        defer { coordinator.controllers.forEach { $0.simulateControlLoss() } }
        XCTAssertTrue(controller.beginEarTipFit())
        let transitionID = try XCTUnwrap(controller.earTipFitTransition?.id)
        controller.simulateControlLoss()
        coordinator.reconcileConnectedDevices([second])
        XCTAssertTrue(coordinator.selectedController === controller)
        XCTAssertEqual(controller.earTipFitTransition?.id, transitionID)
        XCTAssertFalse(coordinator.hasMultipleConnectedDevices)
        coordinator.select(address: secondAddress)
        XCTAssertEqual(coordinator.selectedAddress, secondAddress)
        coordinator.selectForWorkflow(address: firstAddress)
        XCTAssertTrue(coordinator.selectedController === controller)
    }

    @MainActor
    func testPinnedControllersDoNotRetargetOrShareBatteriesCapabilitiesAndCommands() throws {
        let coordinator = makeCoordinator()
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let second = try device(secondAddress, name: "WH-1000XM6", model: .whXM6)
        coordinator.reconcileConnectedDevices([first, second])
        defer { coordinator.controllers.forEach { $0.simulateControlLoss() } }
        let earbuds = try XCTUnwrap(coordinator.controller(for: firstAddress))
        let headphones = try XCTUnwrap(coordinator.controller(for: secondAddress))
        XCTAssertTrue(earbuds.acceptsDeviceAddress(firstAddress.replacingOccurrences(of: ":", with: "-")))
        XCTAssertFalse(earbuds.acceptsDeviceAddress(secondAddress))
        XCTAssertFalse(earbuds.acceptsDeviceAddress("invalid"))
        earbuds.simulateDeviceConnection(named: "WH-1000XM6", simulatedAddress: secondAddress)
        XCTAssertEqual(earbuds.address, firstAddress)
        XCTAssertEqual(earbuds.deviceModel, .wfXM5)
        XCTAssertTrue(earbuds.supportedFunctions.contains(0x29))
        XCTAssertFalse(headphones.supportedFunctions.contains(0x29))
        deliver([0x25, 0x09, 31, 0, 47, 0], to: earbuds)
        deliver([0x25, 0x00, 92, 0], to: headphones)
        XCTAssertEqual(earbuds.batteries.left?.level, 31)
        XCTAssertEqual(earbuds.batteries.right?.level, 47)
        XCTAssertEqual(headphones.batteryLevel, 92)
        XCTAssertNil(headphones.batteries.left)
        earbuds.setNoiseControl(.anc)
        XCTAssertNotNil(earbuds.pendingChanges[.noiseControl])
        XCTAssertTrue(headphones.pendingChanges.isEmpty)
        XCTAssertFalse(headphones.simulatedTransmittedFrames.contains { $0.payload.first == 0x68 })
        coordinator.select(address: secondAddress)
        XCTAssertTrue(coordinator.selectedController === headphones)
        XCTAssertNotNil(earbuds.pendingChanges[.noiseControl])
        earbuds.simulateControlLoss()
        XCTAssertTrue(headphones.isReady)
        XCTAssertEqual(headphones.batteryLevel, 92)
    }

    @MainActor
    func testPinnedControllersLoadOnlyTheirVerifiedBLEIdentity() throws {
        let suite = "dev.baglayan.Acouplet.coordinator-identity-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = try XCTUnwrap(SonyBLEIdentity.VerifiedDevice(classicAddress: firstAddress, model: .wfXM5,
            hash: "12345678", peripheralIdentifier: UUID()))
        let second = try XCTUnwrap(SonyBLEIdentity.VerifiedDevice(classicAddress: secondAddress, model: .whXM6,
            hash: "ABCDEF12", peripheralIdentifier: UUID()))
        SonyBLEIdentity.save(first, in: defaults)
        SonyBLEIdentity.save(second, in: defaults)
        let earbuds = SonyHeadphonesController(startAutomatically: false, simulated: true, identityDefaults: defaults,
            pinnedAddress: firstAddress, advertisedName: "My earbuds")
        let headphones = SonyHeadphonesController(startAutomatically: false, simulated: true, identityDefaults: defaults,
            pinnedAddress: secondAddress, advertisedName: "My headphones")
        let missing = SonyHeadphonesController(startAutomatically: false, simulated: true, identityDefaults: defaults,
            pinnedAddress: "02:53:4F:4E:59:05")
        let unpinned = SonyHeadphonesController(startAutomatically: false, simulated: true, identityDefaults: defaults)
        XCTAssertEqual(earbuds.simulatedSavedIdentity, first)
        XCTAssertEqual(headphones.simulatedSavedIdentity, second)
        XCTAssertEqual(earbuds.deviceModel, .wfXM5)
        XCTAssertEqual(headphones.deviceModel, .whXM6)
        XCTAssertNil(missing.simulatedSavedIdentity)
        XCTAssertNil(unpinned.simulatedSavedIdentity)
    }

    @MainActor
    func testRejectedProtocolPayloadsDoNotPublishAndRepeatedCodecReplyKeepsSyncFresh() throws {
        let coordinator = makeCoordinator()
        coordinator.reconcileConnectedDevices([try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)])
        let controller = coordinator.selectedController
        defer { controller.simulateControlLoss() }
        var changes = 0
        let observation = coordinator.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        for type: UInt8 in [0x0C, 0x0E] {
            for payload: [UInt8] in [[0xFF, 0], [0x51, 0], [0x13, 0x02], [0x43, 0x20]] {
                controller.simulateProtocolMessage(payload, type: type)
            }
        }
        XCTAssertEqual(changes, 0)
        let initialSync = controller.lastSyncDate
        deliver([0x15, 0x02, 0x10], to: controller)
        XCTAssertEqual(controller.audioFeatures.codec, .ldac)
        XCTAssertEqual(changes, 2)
        XCTAssertNotEqual(controller.lastSyncDate, initialSync)
        changes = 0
        let previousSync = controller.lastSyncDate
        deliver([0x15, 0x02, 0x10], to: controller)
        XCTAssertEqual(controller.audioFeatures.codec, .ldac)
        XCTAssertEqual(changes, 1)
        XCTAssertNotEqual(controller.lastSyncDate, previousSync)
    }

    @MainActor
    func testMalformedMultipointInventoryStillPublishesStaleState() throws {
        let coordinator = makeCoordinator()
        coordinator.reconcileConnectedDevices([try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)])
        let controller = coordinator.selectedController
        defer { controller.simulateControlLoss() }
        XCTAssertFalse(controller.multipoint.inventoryIsStale)
        var changes = 0
        let observation = coordinator.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        controller.simulateProtocolMessage([0x39, 0x02], type: 0x0E)
        XCTAssertTrue(controller.multipoint.inventoryIsStale)
        XCTAssertGreaterThan(changes, 0)
    }

    @MainActor
    func testQuietPollsDoNotPublishAndFifthPollStillRequestsSettings() throws {
        let coordinator = makeCoordinator()
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        coordinator.reconcileConnectedDevices([first])
        let controller = coordinator.selectedController
        defer { controller.simulateControlLoss() }
        var changes = 0
        let observation = coordinator.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        for _ in 0..<4 { controller.simulateAutomaticRefresh() }
        XCTAssertEqual(changes, 0)
        XCTAssertTrue(controller.isDeviceConnected)
        XCTAssertNil(controller.retrySecondsRemaining)
        XCTAssertTrue(controller.simulatedTransmittedFrames.isEmpty)
        controller.simulateAutomaticRefresh()
        XCTAssertGreaterThan(changes, 0)
        XCTAssertFalse(controller.simulatedTransmittedFrames.isEmpty)
    }

    @MainActor
    func testCoordinatorPublishesUpdatedDeviceMetadataAndForwardsControllerChanges() async throws {
        let coordinator = makeCoordinator()
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        coordinator.reconcileConnectedDevices([first])
        defer { coordinator.controllers.forEach { $0.simulateControlLoss() } }
        var changes = 0
        let observation = coordinator.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        coordinator.selectedController.simulateDeviceConnection(named: "WH-1000XM4", simulatedAddress: firstAddress)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(coordinator.connectedDevices.first?.name, "WH-1000XM4")
        XCTAssertEqual(coordinator.connectedDevices.first?.model, .whXM4)
    }

    @available(macOS 27.0, *)
    @MainActor
    func testNativeNoiseActionTargetsItsDeviceIndependentlyOfSelection() async throws {
        let coordinator = makeCoordinator()
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let second = try device(secondAddress, name: "WH-1000XM6", model: .whXM6)
        coordinator.reconcileConnectedDevices([first, second])
        defer { coordinator.controllers.forEach { $0.simulateControlLoss() } }
        let earbuds = try XCTUnwrap(coordinator.controller(for: firstAddress))
        let headphones = try XCTUnwrap(coordinator.controller(for: secondAddress))
        XCTAssertEqual(coordinator.noiseControlActions.count, 6)
        let identifier = try XCTUnwrap(headphones.noiseControlActions.first { $0.title == NoiseControlMode.anc.title }?.id)
        let action = Task { @MainActor in try await coordinator.performNoiseControlAction(identifier) }
        for _ in 0..<10 { await Task.yield() }
        let frame = try XCTUnwrap(headphones.simulatedPendingFrame)
        XCTAssertEqual(frame.payload.first, 0x68)
        headphones.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        XCTAssertTrue(earbuds.pendingChanges.isEmpty)
        XCTAssertEqual(coordinator.selectedAddress, firstAddress)
        deliver([0x69] + frame.payload.dropFirst(), to: headphones)
        try await action.value
        XCTAssertEqual(headphones.noiseControlMode, .anc)
        XCTAssertEqual(earbuds.noiseControlMode, .ambient)
        headphones.simulateControlLoss()
        do {
            try await coordinator.performNoiseControlAction(identifier)
            XCTFail("A stale device action must not fall back to the selected headphones.")
        } catch {
            XCTAssertTrue(error is HeadphoneControlError)
        }
        XCTAssertTrue(earbuds.pendingChanges.isEmpty)
        XCTAssertFalse(earbuds.simulatedTransmittedFrames.contains { $0.payload.first == 0x68 })
    }

    @available(macOS 27.0, *)
    @MainActor
    func testSameModelActionsRemainDistinctAndKeepTheirOwnerAcrossSelectionChanges() async throws {
        let coordinator = makeCoordinator()
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let second = try device(secondAddress, name: "WF-1000XM5", model: .wfXM5)
        coordinator.reconcileConnectedDevices([first, second])
        defer { coordinator.controllers.forEach { $0.simulateControlLoss() } }
        let owner = try XCTUnwrap(coordinator.controller(for: firstAddress))
        let other = try XCTUnwrap(coordinator.controller(for: secondAddress))
        let actions = coordinator.noiseControlActions
        XCTAssertEqual(Set(actions.map(\.id)).count, 6)
        let ancActions = actions.filter { $0.title == NoiseControlMode.anc.title }
        XCTAssertEqual(Set(ancActions.map(\.modelName)), ["WF-1000XM5 · 59:01", "WF-1000XM5 · 59:02"])
        XCTAssertEqual(Set(ancActions.map(\.controlTitle)), [
            String(localized: "Noise Cancelling") + " · WF-1000XM5 · 59:01", String(localized: "Noise Cancelling") + " · WF-1000XM5 · 59:02",
        ])
        let identifier = try XCTUnwrap(ancActions.first { $0.id.hasPrefix(firstAddress + ":") }?.id)
        coordinator.select(address: secondAddress)
        let action = Task { @MainActor in try await coordinator.performNoiseControlAction(identifier) }
        for _ in 0..<10 { await Task.yield() }
        let frame = try XCTUnwrap(owner.simulatedPendingFrame)
        XCTAssertEqual(frame.payload.first, 0x68)
        coordinator.select(address: firstAddress)
        coordinator.select(address: secondAddress)
        XCTAssertTrue(other.pendingChanges.isEmpty)
        XCTAssertFalse(other.simulatedTransmittedFrames.contains { $0.payload.first == 0x68 })
        owner.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        deliver([0x69] + frame.payload.dropFirst(), to: owner)
        try await action.value
        XCTAssertEqual(owner.noiseControlMode, .anc)
        XCTAssertEqual(other.noiseControlMode, .ambient)
        XCTAssertEqual(coordinator.selectedAddress, secondAddress)
    }

    @available(macOS 27.0, *)
    @MainActor
    func testSavedNoiseActionsWaitForDiscoveryAndSurviveUnreadyDevice() async throws {
        let coordinator = makeCoordinator(connected: false)
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let identifier = "\(firstAddress):wfXM5:anc"
        let started = expectation(description: "Saved action resolution started")
        var completed = false
        let resolution = Task { @MainActor in
            started.fulfill()
            let result = try await coordinator.resolveNoiseControlActions(for: [identifier], startupTimeout: .seconds(1))
            completed = true
            return result
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertFalse(completed)
        coordinator.isRunning = true
        coordinator.isDiscovering = true
        coordinator.reconcileConnectedDevices([first])
        coordinator.isDiscovering = false
        let actions = try await resolution.value
        XCTAssertEqual(actions.map(\.id), [identifier])
        XCTAssertTrue(coordinator.noiseControlActions.isEmpty)
        let controller = try XCTUnwrap(coordinator.controller(for: firstAddress))
        defer { controller.simulateControlLoss() }
        XCTAssertTrue(controller.simulatedTransmittedFrames.isEmpty)
        let invalid = try await coordinator.resolveNoiseControlActions(for: [
            "\(secondAddress):wfXM5:anc", "\(firstAddress):whXM5:anc", "\(firstAddress):wfXM5:invalid", "invalid",
        ])
        XCTAssertTrue(invalid.isEmpty)
        do {
            try await coordinator.performNoiseControlAction(identifier)
            XCTFail("A restored identity must not make a disconnected device writable.")
        } catch { XCTAssertTrue(error is HeadphoneControlError) }
        XCTAssertTrue(controller.simulatedTransmittedFrames.isEmpty)
        coordinator.retiredControllerAddresses.insert(firstAddress)
        let retired = try await coordinator.resolveNoiseControlActions(for: [identifier])
        XCTAssertTrue(retired.isEmpty)
    }

    @available(macOS 27.0, *)
    @MainActor
    func testNoiseActionWaitsForItsHandshakeWithoutChangingDeviceSelection() async throws {
        let coordinator = makeCoordinator()
        coordinator.isRunning = true
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let second = try device(secondAddress, name: "WH-1000XM6", model: .whXM6)
        coordinator.reconcileConnectedDevices([first, second])
        defer { coordinator.controllers.forEach { $0.simulateControlLoss() } }
        let owner = try XCTUnwrap(coordinator.controller(for: firstAddress))
        let other = try XCTUnwrap(coordinator.controller(for: secondAddress))
        let identifier = try XCTUnwrap(owner.noiseControlActions.first { $0.title == NoiseControlMode.anc.title }?.id)
        owner.simulateProtocolData(Data(), beginConnection: true)
        coordinator.select(address: secondAddress)
        let started = expectation(description: "Noise action waits for handshake")
        let action = Task { @MainActor in
            started.fulfill()
            try await coordinator.performNoiseControlAction(identifier, startupTimeout: .seconds(1))
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertFalse(owner.simulatedTransmittedFrames.contains { $0.payload.first == 0x68 })
        XCTAssertTrue(other.simulatedTransmittedFrames.isEmpty)
        owner.simulateDeviceConnection(named: first.name, simulatedAddress: first.address)
        for _ in 0..<20 { await Task.yield() }
        let frame = try XCTUnwrap(owner.simulatedPendingFrame)
        XCTAssertEqual(frame.payload.first, 0x68)
        XCTAssertEqual(coordinator.selectedAddress, secondAddress)
        owner.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        deliver([0x69] + frame.payload.dropFirst(), to: owner)
        try await action.value
        XCTAssertEqual(owner.noiseControlMode, .anc)
        XCTAssertEqual(other.noiseControlMode, .ambient)
        XCTAssertTrue(other.simulatedTransmittedFrames.isEmpty)
    }

    @available(macOS 27.0, *)
    @MainActor
    func testNoiseStartupWaitEndsOnTimeoutCancellationOrStopWithoutWrites() async throws {
        for ending in ["timeout", "cancel", "stop"] {
            let coordinator = makeCoordinator(connected: false)
            coordinator.isRunning = true
            coordinator.isDiscovering = true
            let identifier = "\(firstAddress):wfXM5:anc"
            let started = expectation(description: "Startup wait \(ending)")
            let resolution = Task { @MainActor in
                started.fulfill()
                return try await coordinator.resolveNoiseControlActions(for: [identifier],
                    startupTimeout: ending == "timeout" ? .milliseconds(50) : .seconds(1))
            }
            await fulfillment(of: [started], timeout: 1)
            if ending == "cancel" { resolution.cancel() }
            if ending == "stop" { coordinator.stop() }
            do {
                let result = try await resolution.value
                XCTAssertEqual(ending, "stop")
                XCTAssertTrue(result.isEmpty)
            } catch {
                if ending == "cancel" { XCTAssertTrue(error is CancellationError) }
                else {
                    XCTAssertEqual(ending, "timeout")
                    XCTAssertEqual(error.localizedDescription, String(localized: "The headphones are still connecting. Try again in a moment."))
                }
            }
            XCTAssertTrue(coordinator.controllers.isEmpty)
        }
    }

    @MainActor
    private func makeCoordinator(connected: Bool = true) -> SonyDeviceCoordinator {
        SonyDeviceCoordinator(fallbackController: SonyHeadphonesController(startAutomatically: false, simulated: true)) { device in
            let controller = SonyHeadphonesController(startAutomatically: false, simulated: true,
                pinnedAddress: device.address, advertisedName: device.name)
            if connected { controller.simulateDeviceConnection(named: device.name, simulatedAddress: device.address) }
            return controller
        }
    }

    @available(macOS 27.0, *)
    @MainActor
    func testSavedSpeakToChatActionsWaitForDiscoveryWithoutInventingAvailability() async throws {
        let coordinator = makeCoordinator(connected: false)
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let identifier = "\(firstAddress):wfXM5:speak-to-chat-on"
        let started = expectation(description: "Saved Speak-to-Chat resolution started")
        var completed = false
        let resolution = Task { @MainActor in
            started.fulfill()
            let result = try await coordinator.resolveSpeakToChatActions(for: [identifier], startupTimeout: .seconds(1))
            completed = true
            return result
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertFalse(completed)
        coordinator.isRunning = true
        coordinator.isDiscovering = true
        coordinator.reconcileConnectedDevices([first])
        coordinator.isDiscovering = false
        let restored = try await resolution.value
        XCTAssertEqual(restored.map(\.id), [identifier])
        XCTAssertEqual(restored.first?.enabled, true)
        XCTAssertTrue(coordinator.speakToChatActions.isEmpty)
        let invalid = try await coordinator.resolveSpeakToChatActions(for: [
            "\(secondAddress):wfXM5:speak-to-chat-on", "\(firstAddress):whXM5:speak-to-chat-on",
            "\(firstAddress):wfXM5:speak-to-chat-toggle", "\(firstAddress):wfXM5:anc", "invalid",
        ])
        XCTAssertTrue(invalid.isEmpty)
        do {
            try await coordinator.performSpeakToChatAction(identifier)
            XCTFail("Saved identity does not imply a ready feature.")
        } catch { XCTAssertTrue(error is HeadphoneControlError) }
        let owner = try XCTUnwrap(coordinator.controller(for: firstAddress))
        XCTAssertTrue(owner.simulatedTransmittedFrames.isEmpty)
        coordinator.retiredControllerAddresses.insert(firstAddress)
        let retired = try await coordinator.resolveSpeakToChatActions(for: [identifier])
        XCTAssertTrue(retired.isEmpty)
    }

    @available(macOS 27.0, *)
    @MainActor
    func testSpeakToChatActionsKeepTheirExactOwnerThroughHandshakeAndSelectionChanges() async throws {
        let coordinator = makeCoordinator()
        coordinator.isRunning = true
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let second = try device(secondAddress, name: "WF-1000XM5", model: .wfXM5)
        coordinator.reconcileConnectedDevices([first, second])
        defer { coordinator.controllers.forEach { $0.simulateControlLoss() } }
        let actions = coordinator.speakToChatActions.filter(\.enabled)
        XCTAssertEqual(Set(actions.map(\.controlTitle)), [
            String(localized: "Turn On Speak-to-Chat") + " · WF-1000XM5 · 59:01", String(localized: "Turn On Speak-to-Chat") + " · WF-1000XM5 · 59:02",
        ])
        let identifier = try XCTUnwrap(actions.first { $0.id.hasPrefix(firstAddress + ":") }?.id)
        let owner = try XCTUnwrap(coordinator.controller(for: firstAddress))
        let other = try XCTUnwrap(coordinator.controller(for: secondAddress))
        owner.simulateProtocolData(Data(), beginConnection: true)
        coordinator.select(address: secondAddress)
        let started = expectation(description: "Speak-to-Chat waits for its owner")
        let action = Task { @MainActor in
            started.fulfill()
            try await coordinator.performSpeakToChatAction(identifier, startupTimeout: .seconds(1))
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertFalse(owner.simulatedTransmittedFrames.contains { $0.payload.prefix(2) == [0xF8, 0x0C] })
        owner.simulateDeviceConnection(named: first.name, simulatedAddress: first.address)
        for _ in 0..<20 { await Task.yield() }
        let frame = try XCTUnwrap(owner.simulatedPendingFrame)
        XCTAssertEqual(frame.payload, [0xF8, 0x0C, 0, 1])
        XCTAssertTrue(other.simulatedTransmittedFrames.isEmpty)
        owner.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        deliver([0xF9, 0x0C, 0, 1], to: owner)
        try await action.value
        XCTAssertEqual(owner.systemFeatureState(.speakToChat)?.enabled, true)
        XCTAssertEqual(other.systemFeatureState(.speakToChat)?.enabled, false)
        XCTAssertEqual(coordinator.selectedAddress, secondAddress)
    }

    @MainActor
    func testUnconfirmedFindingRemainsSelectableAfterSwitchingAndDisconnecting() async throws {
        for otherStaysConnected in [true, false] {
            let coordinator = makeCoordinator()
            let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
            let second = try device(secondAddress, name: "WH-1000XM6", model: .whXM6)
            coordinator.reconcileConnectedDevices([first, second])
            let owner = try XCTUnwrap(coordinator.controller(for: firstAddress))
            let other = try XCTUnwrap(coordinator.controller(for: secondAddress))
            let finder = try prepareFinder(owner)
            defer {
                finder.dismiss()
                finder.simulateTransportFailure()
                coordinator.controllers.forEach { $0.simulateControlLoss() }
            }
            finder.play(.left)
            finder.simulateConnectionOpened()
            try authorizeFinding(finder)
            let ring = try XCTUnwrap(FastPairRingCommand.ring(.left, timeoutSeconds: 30)?.message.encoded)
            let stop = try XCTUnwrap(FastPairRingCommand.stop.message.encoded)
            XCTAssertEqual(finder.simulatedSentMessages, [ring])
            coordinator.select(address: secondAddress)
            finder.simulateTransportFailure()
            owner.simulateControlLoss(deviceConnected: false)
            if !otherStaysConnected { other.simulateControlLoss(deviceConnected: false) }
            coordinator.reconcilePairedDevices([first, second], connectedAddresses: otherStaysConnected ? [secondAddress] : [])
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(coordinator.selectedAddress, secondAddress)
            XCTAssertEqual(coordinator.connectedDevices.map(\.address), otherStaysConnected ? [secondAddress] : [])
            XCTAssertEqual(coordinator.selectableDevices.map(\.address), [firstAddress, secondAddress])
            XCTAssertTrue(coordinator.hasOtherSelectableDevices)
            XCTAssertEqual(finder.session?.phase, .unconfirmed)
            XCTAssertTrue(finder.mayBeRinging)
            XCTAssertEqual(finder.simulatedSentMessages, [ring])
            coordinator.select(address: firstAddress)
            XCTAssertTrue(coordinator.selectedController === owner)
            XCTAssertTrue(owner.beginEarbudFinder())
            XCTAssertTrue(owner.earbudFinder === finder)
            XCTAssertNil(other.earbudFinder)
            finder.retryStop()
            finder.simulateConnectionOpened()
            XCTAssertEqual(finder.simulatedSentMessages, [ring, stop])
            finder.simulateProtocolData(try XCTUnwrap(FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 0]).encoded))
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(finder.session?.phase, .finished)
            XCTAssertFalse(finder.mayBeRinging)
            XCTAssertEqual(coordinator.selectableDevices.map(\.address), [firstAddress, secondAddress])
            XCTAssertTrue(coordinator.hasOtherSelectableDevices)
            XCTAssertEqual(finder.simulatedSentMessages, [ring, stop])
        }
    }

    @MainActor
    func testTerminationWaitsForExistingStopRetryWithoutCancellingOrRepeatingIt() async throws {
        let (coordinator, owner, finder) = try findingCoordinator()
        defer { finishFinding(coordinator) }
        finder.play(.left)
        let firstSessionID = try XCTUnwrap(finder.session?.id)
        finder.simulateConnectionOpened()
        try authorizeFinding(finder)
        let ring = try XCTUnwrap(FastPairRingCommand.ring(.left, timeoutSeconds: 30)?.message.encoded)
        let stop = try XCTUnwrap(FastPairRingCommand.stop.message.encoded)
        XCTAssertEqual(finder.simulatedSentMessages, [ring])
        finder.simulateTransportFailure()
        finder.retryStop()
        var completions = 0
        XCTAssertTrue(coordinator.prepareEarbudFindingForTermination { completions += 1 })
        XCTAssertTrue(coordinator.prepareEarbudFindingForTermination { XCTFail("The active cleanup must retain its original completion.") })
        await receiveFindingUpdates()
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(finder.session?.phase, .connecting)
        XCTAssertEqual(finder.session?.isRetryingStop, true)
        XCTAssertEqual(finder.simulatedSentMessages, [ring])
        finder.simulateConnectionOpened()
        XCTAssertEqual(finder.simulatedSentMessages, [ring, stop])
        try acknowledgeFindingStop(finder)
        await receiveFindingUpdates()
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(finder.simulatedTransportCloseCount, 2)
        XCTAssertFalse(coordinator.prepareEarbudFindingForTermination { XCTFail("A completed session must not run cleanup again.") })
        XCTAssertTrue(owner.beginEarbudFinder())
        let next = try XCTUnwrap(owner.earbudFinder)
        XCTAssertTrue(next === finder)
        next.play(.right)
        XCTAssertNotEqual(next.session?.id, firstSessionID)
        next.simulateConnectionOpened()
        try authorizeFinding(next)
        XCTAssertTrue(coordinator.prepareEarbudFindingForTermination { completions += 1 })
        XCTAssertEqual(next.session?.phase, .stopping)
        try acknowledgeFindingStop(next)
        await receiveFindingUpdates()
        XCTAssertEqual(completions, 2)
        XCTAssertEqual(finder.simulatedTransportCloseCount, 3)
        let rightRing = try XCTUnwrap(FastPairRingCommand.ring(.right, timeoutSeconds: 30)?.message.encoded)
        XCTAssertEqual(finder.simulatedSentMessages, [ring, stop, rightRing, stop])
    }

    @MainActor
    func testTerminationRetriesUnconfirmedStopOnceAndResetAllowsAnotherQuit() async throws {
        let (coordinator, _, finder) = try findingCoordinator()
        defer { finishFinding(coordinator) }
        finder.play(.left)
        finder.simulateConnectionOpened()
        try authorizeFinding(finder)
        let ring = try XCTUnwrap(FastPairRingCommand.ring(.left, timeoutSeconds: 30)?.message.encoded)
        let stop = try XCTUnwrap(FastPairRingCommand.stop.message.encoded)
        finder.simulateTransportFailure()
        var completions = 0
        XCTAssertTrue(coordinator.prepareEarbudFindingForTermination { completions += 1 })
        XCTAssertEqual(finder.session?.phase, .connecting)
        finder.simulateConnectionOpened()
        finder.simulateAcknowledgementTimeout()
        await receiveFindingUpdates()
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(finder.session?.phase, .unconfirmed)
        XCTAssertTrue(finder.mayBeRinging)
        XCTAssertFalse(coordinator.prepareEarbudFindingForTermination { XCTFail("Failed cleanup must not retry indefinitely.") })
        XCTAssertEqual(finder.simulatedSentMessages, [ring, stop])
        coordinator.resetEarbudFindingTermination()
        XCTAssertTrue(coordinator.prepareEarbudFindingForTermination { completions += 1 })
        finder.simulateConnectionOpened()
        try acknowledgeFindingStop(finder)
        await receiveFindingUpdates()
        XCTAssertEqual(completions, 2)
        XCTAssertFalse(finder.mayBeRinging)
        XCTAssertEqual(finder.simulatedSentMessages, [ring, stop, stop])
    }

    @MainActor
    func testTerminationDoesNotReconnectAfterItsOrdinaryStopTimesOut() async throws {
        let (coordinator, _, finder) = try findingCoordinator()
        defer { finishFinding(coordinator) }
        finder.play(.left)
        finder.simulateConnectionOpened()
        try authorizeFinding(finder)
        var completions = 0
        XCTAssertTrue(coordinator.prepareEarbudFindingForTermination { completions += 1 })
        XCTAssertEqual(finder.session?.phase, .stopping)
        finder.simulateAcknowledgementTimeout()
        await receiveFindingUpdates()
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(finder.session?.phase, .unconfirmed)
        XCTAssertEqual(finder.session?.isRetryingStop, false)
        XCTAssertFalse(coordinator.prepareEarbudFindingForTermination { XCTFail("This session already attempted its shutdown Stop.") })
        XCTAssertEqual(finder.simulatedSentMessages, [
            try XCTUnwrap(FastPairRingCommand.ring(.left, timeoutSeconds: 30)?.message.encoded),
            try XCTUnwrap(FastPairRingCommand.stop.message.encoded),
        ])
    }

    @MainActor
    func testTerminationCancelsAuthenticationAndRejectsItsLateSuccess() async throws {
        let (coordinator, owner, finder) = try findingCoordinator(simulatedTable2Functions: [0xF0])
        defer { finishFinding(coordinator) }
        acknowledgeFindingQueries(owner)
        finder.play(.left)
        finder.simulateConnectionOpened()
        acknowledgeFindingQueries(owner)
        owner.simulateProtocolMessage([0xF3, 0, 0], type: 0x0E)
        await receiveFindingUpdates()
        XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
        let sessionID = try XCTUnwrap(finder.session?.id)
        finder.authenticateWearingOverride(sessionID: sessionID)
        XCTAssertTrue(finder.isAuthenticating)
        var completions = 0
        XCTAssertTrue(coordinator.prepareEarbudFindingForTermination { completions += 1 })
        XCTAssertFalse(finder.isAuthenticating)
        finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
        finder.confirmWearingOverride(sessionID: sessionID)
        await receiveFindingUpdates()
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(finder.session?.phase, .finished)
        XCTAssertNil(finder.wearingAuthorization)
        XCTAssertTrue(finder.simulatedAuthorizationEvents.isEmpty)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
    }

    @MainActor
    func testTerminationCancelsAnOpeningFinderBeforeAnySoundCanStart() async throws {
        let (coordinator, _, finder) = try findingCoordinator()
        defer { finishFinding(coordinator) }
        finder.play(.left)
        var completions = 0
        XCTAssertTrue(coordinator.prepareEarbudFindingForTermination { completions += 1 })
        finder.simulateConnectionOpened()
        await receiveFindingUpdates()
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(finder.session?.phase, .finished)
        XCTAssertFalse(finder.mayBeRinging)
        XCTAssertTrue(finder.simulatedSentMessages.isEmpty)
    }

    @MainActor
    func testTerminationWaitsForEveryDeviceAndResetCancelsPendingCompletion() async throws {
        let coordinator = makeCoordinator()
        let first = try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)
        let second = try device(secondAddress, name: "WF-1000XM5", model: .wfXM5)
        coordinator.reconcileConnectedDevices([first, second])
        defer { finishFinding(coordinator) }
        let left = try prepareFinder(try XCTUnwrap(coordinator.controller(for: firstAddress)))
        let right = try prepareFinder(try XCTUnwrap(coordinator.controller(for: secondAddress)))
        left.play(.left)
        left.simulateConnectionOpened()
        try authorizeFinding(left)
        right.play(.right)
        right.simulateConnectionOpened()
        try authorizeFinding(right)
        left.simulateTransportFailure()
        var completions = 0
        XCTAssertTrue(coordinator.prepareEarbudFindingForTermination { completions += 1 })
        XCTAssertEqual(left.session?.phase, .connecting)
        XCTAssertEqual(right.session?.phase, .stopping)
        try acknowledgeFindingStop(right)
        await receiveFindingUpdates()
        XCTAssertEqual(completions, 0)
        left.simulateConnectionOpened()
        try acknowledgeFindingStop(left)
        await receiveFindingUpdates()
        XCTAssertEqual(completions, 1)
        coordinator.resetEarbudFindingTermination()
        let next = try prepareFinder(try XCTUnwrap(coordinator.controller(for: firstAddress)))
        next.play(.left)
        next.simulateConnectionOpened()
        try authorizeFinding(next)
        XCTAssertTrue(coordinator.prepareEarbudFindingForTermination { completions += 1 })
        coordinator.resetEarbudFindingTermination()
        try acknowledgeFindingStop(next)
        await receiveFindingUpdates()
        XCTAssertEqual(completions, 1)
    }

    @MainActor
    private func findingCoordinator(simulatedTable2Functions: Set<UInt8>? = nil) throws -> (SonyDeviceCoordinator, SonyHeadphonesController, EarbudFinderController) {
        let coordinator = makeCoordinator()
        coordinator.reconcileConnectedDevices([try device(firstAddress, name: "WF-1000XM5", model: .wfXM5)])
        let owner = try XCTUnwrap(coordinator.controller(for: firstAddress))
        return (coordinator, owner, try prepareFinder(owner, simulatedTable2Functions: simulatedTable2Functions))
    }

    @MainActor
    private func prepareFinder(_ owner: SonyHeadphonesController, simulatedTable2Functions: Set<UInt8>? = nil) throws -> EarbudFinderController {
        owner.simulateDeviceConnection(named: "WF-1000XM5", simulatedAddress: owner.address, galleryModel: .wfXM5,
                                       simulatedTable2Functions: simulatedTable2Functions)
        let firmware = Array("6.1.0".utf8)
        deliver([0x05, 2, UInt8(firmware.count)] + firmware, to: owner)
        XCTAssertTrue(owner.beginEarbudFinder())
        let finder = try XCTUnwrap(owner.earbudFinder)
        XCTAssertEqual(finder.wearingDetectionIsUnavailable, simulatedTable2Functions?.contains(0xF0) != true)
        return finder
    }

    @MainActor
    private func authorizeFinding(_ finder: EarbudFinderController) throws {
        XCTAssertEqual(finder.session?.phase, .awaitingWearingConfirmation)
        XCTAssertNil(finder.session?.wearingConfirmationStatus)
        let sessionID = try XCTUnwrap(finder.session?.id)
        let sentMessages = finder.simulatedSentMessages
        finder.confirmWearingOverride(sessionID: sessionID)
        XCTAssertEqual(finder.simulatedSentMessages, sentMessages)
        finder.authenticateWearingOverride(sessionID: sessionID)
        finder.simulateAuthorizationCompletion(sessionID: sessionID, succeeded: true)
        XCTAssertEqual(finder.simulatedSentMessages, sentMessages)
        finder.confirmWearingOverride(sessionID: sessionID)
        XCTAssertEqual(finder.session?.startedWithWearingOverride, true)
        XCTAssertEqual(finder.simulatedAuthorizationEvents.last, sessionID)
        XCTAssertEqual(finder.simulatedSentMessages.count, sentMessages.count + 1)
    }

    @MainActor
    private func finishFinding(_ coordinator: SonyDeviceCoordinator) {
        coordinator.resetEarbudFindingTermination()
        for owner in coordinator.controllers {
            owner.earbudFinder?.dismiss()
            owner.earbudFinder?.simulateTransportFailure()
            owner.simulateControlLoss()
        }
    }

    @MainActor
    private func acknowledgeFindingStop(_ finder: EarbudFinderController) throws {
        finder.simulateProtocolData(try XCTUnwrap(FastPairMessage(group: 0xFF, code: 1, payload: [4, 1, 0]).encoded))
    }

    @MainActor
    private func receiveFindingUpdates() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    private func acknowledgeFindingQueries(_ owner: SonyHeadphonesController) {
        for _ in 0..<200 {
            guard let frame = owner.simulatedPendingFrame else { return }
            owner.simulateProtocolData(SonyFrameCodec.encode(type: 0x01, sequence: 1 - frame.sequence, payload: []))
        }
        XCTFail("The simulated command queue did not drain.")
    }

    private func device(_ address: String, name: String, model: SonyDeviceModel) throws -> SonyConnectedDevice {
        try XCTUnwrap(SonyConnectedDevice(address: address, name: name, model: model))
    }

    @MainActor
    private func deliver(_ payload: [UInt8], to controller: SonyHeadphonesController) {
        controller.simulateProtocolMessage(payload)
    }
}
