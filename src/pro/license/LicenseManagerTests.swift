import XCTest

final class LicenseManagerTests: XCTestCase {
    var clock: MockClock!
    var keychain: MockKeychain!
    var api: MockLicenseAPI!
    var defaults: UserDefaults!
    var suiteName: String!
    var manager: LicenseManager!

    override func setUp() {
        super.setUp()
        suiteName = "test-license-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        clock = MockClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        keychain = MockKeychain()
        api = MockLicenseAPI()
        manager = LicenseManager(clock: clock, keychain: keychain, api: api, defaults: defaults)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Launch / initialize

    func testAlwaysPro() {
        manager.initialize()
        XCTAssertEqual(manager.state, .pro)
    }

    func testAlwaysProRegardlessOfTrialState() {
        setupTrial(daysAgo: 365)
        manager.initialize()
        XCTAssertEqual(manager.state, .pro)
    }

    // MARK: - Keychain-backed licenses

    func testAlwaysProEvenWithoutKeychain() {
        manager.initialize()
        XCTAssertEqual(manager.state, .pro)
    }

    func testAlwaysProEvenWithInvalidatedLicense() {
        setupActivatedLicense(variantId: nil)
        defaults.set(false, forKey: "lastValidationResult")
        manager.initialize()
        XCTAssertEqual(manager.state, .pro)
    }

    func testAlwaysProEvenWithoutValidationResult() {
        keychain.setValue("KEY", account: LicenseManager.keychainKeyAccount)
        keychain.setValue("instance-1", account: LicenseManager.keychainInstanceAccount)
        manager.initialize()
        XCTAssertEqual(manager.state, .pro)
    }

    // MARK: - Activate

    func testActivateSuccessTransitionsToPro() {
        api.activateResult = .success(ActivateResult(instanceId: "inst-1", variantId: "pro", customerEmail: "alice@example.com"))
        let exp = expectation(description: "activate")
        manager.activate("LICENSE-KEY-ABC") { result in
            if case .failure(let e) = result { XCTFail("expected success, got \(e)") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(manager.state, .pro)
        XCTAssertEqual(keychain.value(account: LicenseManager.keychainKeyAccount), "LICENSE-KEY-ABC")
        XCTAssertEqual(keychain.value(account: LicenseManager.keychainInstanceAccount), "inst-1")
        XCTAssertEqual(keychain.value(account: LicenseManager.keychainVariantAccount), "pro")
        XCTAssertEqual(defaults.bool(forKey: "lastValidationResult"), true)
        XCTAssertEqual(defaults.double(forKey: "lastValidation"), clock.now.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(manager.customerEmail, "alice@example.com")
    }

    func testActivateFailurePreservesProState() {
        manager.initialize()
        api.activateResult = .failure(LicenseAPIError.activationRejected("invalid"))
        let exp = expectation(description: "activate")
        manager.activate("BAD-KEY") { result in
            if case .success = result { XCTFail("expected failure") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(manager.state, .pro)
        XCTAssertNil(keychain.value(account: LicenseManager.keychainKeyAccount))
    }

    func testActivateWithoutCustomerEmailLeavesCustomerEmailNil() {
        api.activateResult = .success(ActivateResult(instanceId: "inst", variantId: nil, customerEmail: nil))
        let exp = expectation(description: "activate")
        manager.activate("KEY") { _ in exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertNil(manager.customerEmail)
        XCTAssertNil(keychain.value(account: LicenseManager.keychainVariantAccount))
    }

    func testActivateSeatLimitExceededSurfacesInstances() {
        manager.initialize()
        let instances = [
            ActiveInstance(id: "inst-old-1", machineName: "Work laptop", lastSeenAt: clock.now.addingTimeInterval(-86400)),
            ActiveInstance(id: "inst-old-2", machineName: nil, lastSeenAt: clock.now.addingTimeInterval(-86400 * 7)),
        ]
        api.activateResult = .failure(LicenseAPIError.seatLimitExceeded(instances: instances))
        let exp = expectation(description: "activate")
        var surfaced: [ActiveInstance] = []
        manager.activate("KEY") { result in
            if case .failure(let e) = result, case LicenseAPIError.seatLimitExceeded(let list) = e {
                surfaced = list
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(surfaced.count, 2)
        XCTAssertEqual(surfaced[0].id, "inst-old-1")
        XCTAssertEqual(surfaced[0].machineName, "Work laptop")
        XCTAssertNil(surfaced[1].machineName)
        XCTAssertEqual(manager.state, .pro)
        XCTAssertNil(keychain.value(account: LicenseManager.keychainKeyAccount))
    }

    func testActivateFailsAndRollsBackIfKeychainWriteFails() {
        manager.initialize()
        api.activateResult = .success(ActivateResult(instanceId: "inst-1", variantId: "pro", customerEmail: "alice@example.com"))
        keychain.setValueStatus = { _ in errSecAuthFailed }
        let exp = expectation(description: "activate")
        var surfaced: Error?
        manager.activate("LICENSE-KEY-ABC") { result in
            if case .failure(let e) = result { surfaced = e }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        guard case LicenseAPIError.keychainWriteFailed(let account, let status) = surfaced as? LicenseAPIError ?? .noData else {
            return XCTFail("expected keychainWriteFailed, got \(String(describing: surfaced))")
        }
        XCTAssertEqual(account, LicenseManager.keychainKeyAccount)
        XCTAssertEqual(status, errSecAuthFailed)
        XCTAssertEqual(manager.state, .pro)
        XCTAssertNil(keychain.value(account: LicenseManager.keychainKeyAccount))
        XCTAssertNil(keychain.value(account: LicenseManager.keychainInstanceAccount))
        XCTAssertNil(keychain.value(account: LicenseManager.keychainVariantAccount))
        XCTAssertNil(defaults.object(forKey: "lastValidation"))
        XCTAssertNil(defaults.object(forKey: "lastValidationResult"))
        XCTAssertNil(defaults.object(forKey: "customerEmail"))
    }

    func testActivateRollsBackPartialKeychainWritesOnLaterFailure() {
        manager.initialize()
        api.activateResult = .success(ActivateResult(instanceId: "inst-1", variantId: "pro", customerEmail: nil))
        var calls = 0
        keychain.setValueStatus = { _ in
            calls += 1
            return calls == 1 ? errSecSuccess : errSecAuthFailed
        }
        let exp = expectation(description: "activate")
        manager.activate("LICENSE-KEY-ABC") { _ in exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(manager.state, .pro)
        XCTAssertNil(keychain.value(account: LicenseManager.keychainKeyAccount))
        XCTAssertNil(keychain.value(account: LicenseManager.keychainInstanceAccount))
    }

    func testDeactivateInstanceCallsApiWithoutTouchingLocalState() {
        setupActivatedLicense(variantId: nil)
        manager.initialize()
        api.deactivateResult = .success(())
        let exp = expectation(description: "deactivate-instance")
        manager.deactivateInstance(licenseKey: "KEY", instanceId: "other-instance") { result in
            if case .failure(let e) = result { XCTFail("expected success, got \(e)") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(api.deactivateCalls.count, 1)
        XCTAssertEqual(api.deactivateCalls[0].0, "KEY")
        XCTAssertEqual(api.deactivateCalls[0].1, "other-instance")
        XCTAssertNotNil(keychain.value(account: LicenseManager.keychainKeyAccount))
        XCTAssertEqual(manager.state, .pro)
    }

    // MARK: - Deactivate

    func testDeactivateSuccessStaysPro() {
        setupActivatedLicense(variantId: nil)
        manager.initialize()
        XCTAssertEqual(manager.state, .pro)

        api.deactivateResult = .success(())
        let exp = expectation(description: "deactivate")
        manager.deactivate { _ in exp.fulfill() }
        wait(for: [exp], timeout: 1)

        XCTAssertEqual(manager.state, .pro)
        XCTAssertNil(keychain.value(account: LicenseManager.keychainKeyAccount))
        XCTAssertNil(keychain.value(account: LicenseManager.keychainInstanceAccount))
    }

    func testDeactivateFailurePreservesState() {
        setupActivatedLicense(variantId: nil)
        manager.initialize()
        api.deactivateResult = .failure(LicenseAPIError.deactivationRejected)
        let exp = expectation(description: "deactivate")
        manager.deactivate { result in
            if case .success = result { XCTFail("expected failure") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(manager.state, .pro)
        XCTAssertNotNil(keychain.value(account: LicenseManager.keychainKeyAccount))
    }

    func testDeactivateWithoutLicenseErrors() {
        manager.initialize()
        let exp = expectation(description: "deactivate")
        manager.deactivate { result in
            if case .success = result { XCTFail("expected failure") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(api.deactivateCalls.count, 0)
    }

    // MARK: - Async revalidation

    func testRevalidationWithinIntervalIsSkipped() {
        setupActivatedLicense(variantId: nil)
        manager.initialize()
        drainMainQueue()
        XCTAssertEqual(api.validateCalls.count, 0)
    }

    func testRevalidationAfterIntervalKeepsPro() {
        setupActivatedLicense(variantId: nil)
        defaults.set(clock.now.addingTimeInterval(-31 * 86400).timeIntervalSince1970, forKey: "lastValidation")
        api.validateResult = .success(ValidateResult(valid: true, variantId: nil))

        manager.initialize()
        let exp = expectation(description: "validate callback drained")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        drainMainQueue()

        XCTAssertEqual(api.validateCalls.count, 1)
        XCTAssertEqual(manager.state, .pro)
        XCTAssertEqual(defaults.double(forKey: "lastValidation"), clock.now.timeIntervalSince1970, accuracy: 0.01)
    }

    func testRevalidationAfterIntervalInvalidStillPro() {
        setupActivatedLicense(variantId: nil)
        defaults.set(clock.now.addingTimeInterval(-31 * 86400).timeIntervalSince1970, forKey: "lastValidation")
        api.validateResult = .success(ValidateResult(valid: false, variantId: nil))

        manager.initialize()
        XCTAssertEqual(manager.state, .pro)
        let exp = expectation(description: "validate callback drained")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        drainMainQueue()

        XCTAssertEqual(manager.state, .pro)
    }

    func testRevalidationNetworkFailurePreservesState() {
        setupActivatedLicense(variantId: nil)
        let oldValidation = clock.now.addingTimeInterval(-31 * 86400).timeIntervalSince1970
        defaults.set(oldValidation, forKey: "lastValidation")
        api.validateResult = .failure(LicenseAPIError.noData)

        manager.initialize()
        let exp = expectation(description: "validate callback drained")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        drainMainQueue()

        XCTAssertEqual(api.validateCalls.count, 1)
        XCTAssertEqual(manager.state, .pro)
        XCTAssertEqual(defaults.double(forKey: "lastValidation"), oldValidation, accuracy: 0.01)
    }

    func testRevalidationUpdatesVariantIdWhenReturned() {
        setupActivatedLicense(variantId: nil)
        defaults.set(clock.now.addingTimeInterval(-31 * 86400).timeIntervalSince1970, forKey: "lastValidation")
        api.validateResult = .success(ValidateResult(valid: true, variantId: "pro_lifetime"))

        manager.initialize()
        let exp = expectation(description: "validate callback drained")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        drainMainQueue()

        XCTAssertEqual(keychain.value(account: LicenseManager.keychainVariantAccount), "pro_lifetime")
    }

    // MARK: - State change callback

    func testOnStateChangedFiresOnInitialize() {
        var observed: [LicenseState] = []
        manager.onStateChanged = { observed.append($0) }
        manager.initialize()
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first, .pro)
    }

    func testOnStateChangedFiresOnActivateSuccess() {
        var observed: [LicenseState] = []
        manager.onStateChanged = { observed.append($0) }
        manager.initialize()
        api.activateResult = .success(ActivateResult(instanceId: "i", variantId: nil, customerEmail: nil))
        let exp = expectation(description: "activate")
        manager.activate("K") { _ in exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(observed.last, .pro)
        XCTAssertGreaterThanOrEqual(observed.count, 2)
    }

    // MARK: - isProLocked + onBeforeProUnlock

    func testIsProLockedAlwaysFalse() {
        manager.initialize()
        XCTAssertFalse(manager.isProLocked)
    }

    func testIsProLockedAlwaysFalseEvenWithExpiredTrial() {
        setupTrial(daysAgo: 14)
        manager.initialize()
        XCTAssertEqual(manager.state, .pro)
        XCTAssertFalse(manager.isProLocked)
    }

    func testIsProLockedAlwaysFalseEvenWhenKeychainInvalidated() {
        setupActivatedLicense(variantId: nil)
        defaults.set(false, forKey: "lastValidationResult")
        manager.initialize()
        XCTAssertEqual(manager.state, .pro)
        XCTAssertFalse(manager.isProLocked)
    }

    func testOnBeforeProUnlockFiresBeforeStateFlipsToPro() {
        manager.initialize()
        api.activateResult = .success(ActivateResult(instanceId: "i", variantId: nil, customerEmail: nil))
        var observedStateWhenHookFired: LicenseState?
        manager.onBeforeProUnlock = { [weak manager] in
            observedStateWhenHookFired = manager?.state
        }
        let exp = expectation(description: "activate")
        manager.activate("K") { _ in exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertNotNil(observedStateWhenHookFired)
        XCTAssertEqual(observedStateWhenHookFired, .pro)
        XCTAssertEqual(manager.state, .pro)
    }

    #if DEBUG
    func testOnBeforeProUnlockFiresOnMockProUser() {
        manager.initialize()
        var hookFired = false
        manager.onBeforeProUnlock = { hookFired = true }
        manager.mockProUser()
        XCTAssertTrue(hookFired)
        XCTAssertEqual(manager.state, .pro)
    }
    #endif

    // MARK: - Helpers

    private func setupTrial(daysAgo: Int) {
        let start = clock.now.addingTimeInterval(-Double(daysAgo) * 86400)
        defaults.set(start.timeIntervalSince1970, forKey: "trialStartDate")
    }

    private func setupActivatedLicense(variantId: String?) {
        keychain.setValue("LICENSE-ABC", account: LicenseManager.keychainKeyAccount)
        keychain.setValue("instance-1", account: LicenseManager.keychainInstanceAccount)
        if let variantId { keychain.setValue(variantId, account: LicenseManager.keychainVariantAccount) }
        defaults.set(clock.now.timeIntervalSince1970, forKey: "lastValidation")
        defaults.set(true, forKey: "lastValidationResult")
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}

// MARK: - Mocks

final class MockClock: Clock {
    var now: Date
    init(now: Date) { self.now = now }
    func advance(by interval: TimeInterval) { now = now.addingTimeInterval(interval) }
    func advance(days: Int) { now = now.addingTimeInterval(Double(days) * 86400) }
}

final class MockKeychain: Keychain {
    private var store: [String: String] = [:]
    var setValueStatus: (String) -> OSStatus = { _ in errSecSuccess }
    var removeStatus: (String) -> OSStatus = { _ in errSecSuccess }

    func value(account: String) -> String? { store[account] }

    @discardableResult
    func setValue(_ value: String, account: String) -> OSStatus {
        let status = setValueStatus(account)
        if status == errSecSuccess { store[account] = value }
        return status
    }

    @discardableResult
    func remove(account: String) -> OSStatus {
        let status = removeStatus(account)
        if status == errSecSuccess { store.removeValue(forKey: account) }
        return status
    }
}

final class MockLicenseAPI: LicenseAPI {
    var activateResult: Result<ActivateResult, Error> = .failure(LicenseAPIError.noData)
    var validateResult: Result<ValidateResult, Error> = .failure(LicenseAPIError.noData)
    var deactivateResult: Result<Void, Error> = .failure(LicenseAPIError.noData)

    var activateCalls: [String] = []
    var validateCalls: [(String, String)] = []
    var deactivateCalls: [(String, String)] = []

    func activate(_ licenseKey: String, completion: @escaping (Result<ActivateResult, Error>) -> Void) {
        activateCalls.append(licenseKey)
        let r = activateResult
        DispatchQueue.main.async { completion(r) }
    }

    func validate(_ licenseKey: String, instanceId: String, completion: @escaping (Result<ValidateResult, Error>) -> Void) {
        validateCalls.append((licenseKey, instanceId))
        let r = validateResult
        DispatchQueue.main.async { completion(r) }
    }

    func deactivate(_ licenseKey: String, instanceId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        deactivateCalls.append((licenseKey, instanceId))
        let r = deactivateResult
        DispatchQueue.main.async { completion(r) }
    }
}
