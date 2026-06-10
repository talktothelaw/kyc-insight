import Foundation
import Combine

/// Runtime state for one verification session.
///
/// Mirrors `kyc-web-wiget-v2/src/state/widgetStore.ts`:
///   • `loadSchema()` — calls `createMerchantCustomer`, normalises into a
///     typed `WidgetSchema`, seeds initial values from `submittedValues`.
///   • `submitCurrentSection()` — validates required fields, calls
///     `KycSubmission`, advances the cursor, refetches the schema so
///     status pills update.
///   • Frontier rules — the user can navigate freely backwards to any
///     completed section but cannot skip forward past their current step.
@MainActor
public final class KYCWidgetSession: ObservableObject {

    // MARK: - Public state (read-only to views)

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var schema: WidgetSchema?
    @Published public private(set) var currentStepIndex: Int = 0
    @Published public private(set) var currentSectionIndex: Int = 0
    @Published public private(set) var values: [String: AnyCodable] = [:]
    @Published public private(set) var fieldErrors: [String: String] = [:]
    @Published public private(set) var submissionError: String?
    @Published public private(set) var loadError: String?
    @Published public private(set) var completed: Bool = false

    public enum Phase: Equatable, Sendable {
        case idle, loading, ready, submitting, error
    }

    // MARK: - Dependencies

    public let config: KYCWidgetConfig
    private let client: GraphQLClient
    weak var widget: KYCWidget?

    /// Slugs of steps we've already fired `onLevelApproved` for in
    /// this session. Used by `dispatchLevelApprovalTransitions` to
    /// fire ONCE per transition (not on every refresh). Seeded with
    /// already-approved steps on the very first load so the host
    /// doesn't see a "level approved" event for a level that was
    /// already done when the widget opened.
    private var approvedDispatchedSlugs: Set<String> = []
    private var didSeedApprovedSlugs = false

    public init(config: KYCWidgetConfig) {
        self.config = config
        self.client = GraphQLClient(endpoint: config.gqlEndpoint, publicKey: config.publicKey)
    }

    /// Build a LivenessAPI bound to this session's GraphQL client + auth.
    /// LivenessFieldView calls this once on appear; the API instance is
    /// stateless beyond holding the client reference.
    public func makeLivenessAPI() -> LivenessAPI {
        return LivenessAPI(client: client)
    }

    /// Bridge `onLivenessSubmitted` from the LivenessField up to the host
    /// app's callback. Fires the moment the backend evaluator returns a
    /// verdict — BEFORE the level-level `onLevelApproved` event.
    public func dispatchLivenessSubmitted(
        sessionToken: String,
        status: String,
        riskScore: Double?,
        failureReason: String?
    ) {
        widget?.dispatchLivenessSubmitted(KYCLivenessVerdict(
            sessionToken: sessionToken,
            status: status,
            riskScore: riskScore,
            failureReason: failureReason
        ))
    }

    deinit {
        // Drop any shared loaders keyed against this session so a freshly
        // presented widget doesn't accidentally see another session's
        // cached countries / states / lgas.
        LocationLoader.evict(for: ObjectIdentifier(self))
    }

    // MARK: - Schema load

    public func loadSchema() async {
        // Always start clean — every call to loadSchema() is treated as
        // "start verification". No memoisation, no early-return on an
        // already-loaded schema. The GraphQL client itself is configured
        // for no-cache (URLSession ephemeral + per-request
        // .reloadIgnoringLocalAndRemoteCacheData) so this hits the wire.
        schema = nil
        values = [:]
        fieldErrors = [:]
        submissionError = nil
        completed = false
        phase = .loading
        loadError = nil

        // Opt-in offline demo path — bypasses the backend entirely.
        if config.demoMode {
            let schema = DemoSchema.make()
            self.schema = schema
            seedInitialValues()
            let resume = findResumePosition(schema)
            self.currentStepIndex = resume.step
            self.currentSectionIndex = resume.section
            self.phase = .ready
            // Seed on first load so we don't fire onLevelApproved for
            // levels that were already done when the widget opened;
            // subsequent refreshes report only NEW transitions.
            dispatchLevelApprovalTransitions(seedOnly: !didSeedApprovedSlugs)
            didSeedApprovedSlugs = true
            widget?.dispatchReady()
            if let step = schema.steps[safe: resume.step] {
                widget?.dispatchLevelChange(KYCWidgetLevel(slug: step.slug, index: resume.step))
            }
            return
        }

        let query = """
        query createMerchantCustomer(
          $slug: String!, $name: String!, $userRef: String!,
          $levelSlug: String!, $vName: String, $includeAllLevels: Boolean
        ) {
          createMerchantCustomer(
            slug: $slug, name: $name, userRef: $userRef,
            levelSlug: $levelSlug, vName: $vName,
            includeAllLevels: $includeAllLevels
          )
        }
        """
        var vars: [String: Any] = [
            "slug": config.slug, "name": config.name,
            "userRef": config.userRef, "levelSlug": config.levelSlug,
            "includeAllLevels": true,
        ]
        if let vName = config.vName { vars["vName"] = vName }

        do {
            // Backend returns the envelope `{ message, data: RawCustomerSession }`.
            let envelope = try await client.execute(
                query: query, variables: vars,
                rootField: "createMerchantCustomer",
                as: RawCreateCustomerResponse.self
            )
            let schema = SchemaNormalizer.normalize(envelope.data)
            self.schema = schema
            seedInitialValues()
            // Resume position — find the first non-approved/-pending section.
            let resume = findResumePosition(schema)
            self.currentStepIndex = resume.step
            self.currentSectionIndex = resume.section
            // Pre-flight: surface a friendly error if the schema needs a
            // direct-flow provider the business isn't unlocked for. Mirrors
            // the web's `runConsentModePreflight` in widgetStore.ts. Network
            // failure is non-fatal — the backend's
            // `enforceDirectVerificationGate` is the authoritative refusal.
            if let preflightError = await runConsentModePreflight(schema: schema) {
                self.loadError = preflightError
                self.phase = .error
                widget?.dispatchError(.loadFailed(message: preflightError))
                return
            }
            self.phase = .ready
            // Diff the new schema against tracked approvals so newly-
            // approved levels fire `onLevelApproved` even when the
            // approval came from the backend (e.g. merchant manually
            // approved a pending section after submit), not just from
            // the user's own submission. First-ever load is `seedOnly`
            // so pre-existing approvals don't fire spuriously.
            dispatchLevelApprovalTransitions(seedOnly: !didSeedApprovedSlugs)
            didSeedApprovedSlugs = true
            widget?.dispatchReady()
            if let step = schema.steps[safe: resume.step] {
                widget?.dispatchLevelChange(KYCWidgetLevel(slug: step.slug, index: resume.step))
            }
        } catch {
            // Real network / decode errors surface as a load error — no
            // silent fallback. The user sees the message + a retry button.
            self.loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            self.phase = .error
            widget?.dispatchError(.loadFailed(message: self.loadError ?? "Unknown error"))
        }
    }

    // Fallback used only when the backend doesn't return
    // `directProviderCounterparts` on `getMyConsentMode` (older deployments).
    // The server is the source of truth — adding/removing entries on the
    // backend propagates without an SDK release.
    private static let fallbackDirectToConsent: [String: String] = [
        "nin": "nin_consent",
        "driving_license": "drivers_license_consent",
        "international_passport": "passport_consent",
    ]

    // Detect a schema that mixes direct-flow providers with a business that
    // hasn't been granted direct-verification access. Returns the friendly
    // error to surface, or nil when everything is fine. Network failures
    // return nil and let the backend gate be the authoritative refusal.
    private func runConsentModePreflight(schema: WidgetSchema) async -> String? {
        var requestedTypes = Set<String>()
        for step in schema.steps {
            for section in step.sections {
                requestedTypes.insert(section.providerType)
            }
        }

        let mode: ConsentModeResponse
        do {
            mode = try await ConsentAPI(client: client).getMyConsentMode()
        } catch {
            return nil
        }

        let counterparts: [String: String]
        if let serverList = mode.directProviderCounterparts, !serverList.isEmpty {
            counterparts = Dictionary(uniqueKeysWithValues: serverList.map { ($0.directType, $0.consentType) })
        } else {
            counterparts = Self.fallbackDirectToConsent
        }

        let directInSchema = requestedTypes.filter { counterparts[$0] != nil }
        if directInSchema.isEmpty { return nil }

        let blocked = directInSchema.filter { directType in
            guard let counterpart = counterparts[directType] else { return false }
            if !mode.allowDirectVerification { return true }
            return !mode.directVerificationAllowedTypes.contains(counterpart)
        }
        if blocked.isEmpty { return nil }

        let items = blocked
            .sorted()
            .map { "\($0) (try \(counterparts[$0] ?? "consent"))" }
            .joined(separator: ", ")
        return "This verification cannot start because the following direct-mode providers " +
            "are not enabled for this business: \(items). " +
            "Ask the merchant to switch to the consent counterparts, or contact support to " +
            "enable direct verification."
    }

    /// Seed widget values from each section's `submittedValues` so rejected
    /// sections come up pre-populated with the user's prior data.
    private func seedInitialValues() {
        guard let schema else { return }
        var seeded: [String: AnyCodable] = [:]
        for step in schema.steps {
            for section in step.sections {
                if let sub = section.submittedValues {
                    for (k, v) in sub { seeded[k] = v }
                }
            }
        }
        values = seeded
    }

    /// Re-run `createMerchantCustomer` without changing the cursor. Used
    /// after each section submission so the freshly-flipped status pill
    /// (rejected → pending or approved) shows up in the sidebar outline.
    private func refreshSchemaPreservingCursor() async {
        let savedStep = currentStepIndex
        let savedSection = currentSectionIndex
        // Reset phase to idle so loadSchema's guard doesn't block; capture
        // and restore the cursor since loadSchema would otherwise compute
        // a fresh resume position.
        let wasCompleted = completed
        phase = .idle
        await loadSchema()
        currentStepIndex = savedStep
        currentSectionIndex = savedSection
        completed = wasCompleted
    }

    /// Fire `onLevelApproved` for any step that has just transitioned
    /// to fully-approved since the last time we checked. Mirrors the
    /// web's `main.tsx:91-104` subscription — fires ONCE per
    /// transition, not on every schema refresh.
    ///
    /// "Fully approved" matches the FE frontier semantics: every
    /// section is `.approved` AND has no `requiresUpdate` flag
    /// (otherwise the merchant added new requirements after approval
    /// and the level isn't really done).
    ///
    /// `seedOnly` is true for the very first load — we seed the
    /// "already dispatched" set with whatever's currently approved so
    /// the host doesn't see a fake "level approved" event for a level
    /// that was approved BEFORE the widget opened.
    private func dispatchLevelApprovalTransitions(seedOnly: Bool = false) {
        guard let schema else { return }
        for (idx, step) in schema.steps.enumerated() {
            guard !step.sections.isEmpty else { continue }
            let allApproved = step.sections.allSatisfy {
                $0.status == .approved && !$0.requiresUpdate
            }
            if !allApproved {
                // Step is no longer fully approved — clear it from the
                // dispatched set so a later re-approval fires again.
                approvedDispatchedSlugs.remove(step.slug)
                continue
            }
            if approvedDispatchedSlugs.contains(step.slug) { continue }
            approvedDispatchedSlugs.insert(step.slug)
            if seedOnly { continue }
            widget?.dispatchLevelApproved(
                KYCWidgetLevel(slug: step.slug, index: idx)
            )
        }
    }

    /// Find the first not-yet-completed section. Mirrors the web's
    /// `findResumePosition`. `requiresUpdate` sections count as "needs
    /// work" so the cursor lands on the new requirements added to a
    /// previously-approved tier.
    private func findResumePosition(_ schema: WidgetSchema) -> (step: Int, section: Int) {
        for (stepIdx, step) in schema.steps.enumerated() {
            for (secIdx, section) in step.sections.enumerated() {
                if section.status == .initialized
                    || section.status == .rejected
                    || section.requiresUpdate {
                    return (stepIdx, secIdx)
                }
            }
        }
        return (0, 0)
    }

    // MARK: - Cursor navigation

    public func goToSection(stepIndex: Int, sectionIndex: Int) {
        let prevStep = currentStepIndex
        currentStepIndex = stepIndex
        currentSectionIndex = sectionIndex
        if prevStep != stepIndex, let step = schema?.steps[safe: stepIndex] {
            widget?.dispatchLevelChange(KYCWidgetLevel(slug: step.slug, index: stepIndex))
        }
    }

    public func goBack() {
        if currentSectionIndex > 0 {
            currentSectionIndex -= 1
            return
        }
        guard currentStepIndex > 0 else { return }
        // Crossing a level boundary backward — fire onLevelChange so
        // the host sees the transition, matching the web widget's
        // subscription that dispatches on ANY currentStepIndex change
        // (forward or backward). Without this the host would think
        // the user is still on the prior level even though
        // `currentStep` now points one level back.
        currentStepIndex -= 1
        currentSectionIndex = (schema?.steps[safe: currentStepIndex]?.sections.count ?? 1) - 1
        if let step = currentStep {
            widget?.dispatchLevelChange(
                KYCWidgetLevel(slug: step.slug, index: currentStepIndex)
            )
        }
    }

    // Counterpart to goBack — used by the read-only footer's Next button so
    // a user who has stepped back into an approved section can walk forward
    // one section at a time instead of jumping straight to the frontier.
    public func goForward() {
        guard let step = currentStep, let schema else { return }
        if currentSectionIndex < step.sections.count - 1 {
            currentSectionIndex += 1
            return
        }
        guard currentStepIndex < schema.steps.count - 1 else { return }
        currentStepIndex += 1
        currentSectionIndex = 0
        if let s = currentStep {
            widget?.dispatchLevelChange(
                KYCWidgetLevel(slug: s.slug, index: currentStepIndex)
            )
        }
    }

    /// True when there's somewhere ahead of the current cursor — either a
    /// later section in the current step, or a later step at all.
    public var canGoForward: Bool {
        guard let step = currentStep, let schema else { return false }
        if currentSectionIndex < step.sections.count - 1 { return true }
        return currentStepIndex < schema.steps.count - 1
    }

    // MARK: - Field values

    public func setValue(_ value: AnyCodable, for fieldID: String) {
        values[fieldID] = value
        if fieldErrors[fieldID] != nil { fieldErrors[fieldID] = nil }
    }

    public var currentStep: WidgetStep? { schema?.steps[safe: currentStepIndex] }
    public var currentSection: WidgetSection? { currentStep?.sections[safe: currentSectionIndex] }

    /// True when the current section is read-only — already submitted
    /// (`approved` or `pending`) AND NOT flagged by the backend's
    /// per-field `alreadySupplied` stamps as needing more input.
    /// Mirrors `WidgetRoot.tsx:isReadOnlySection`.
    public var isCurrentSectionReadOnly: Bool {
        guard let s = currentSection else { return false }
        if s.requiresUpdate { return false }
        return s.status == .approved || s.status == .pending
    }

    /// Frontier for the *current* step. `requiresUpdate` sections
    /// count as "needs work" so the user can navigate to them.
    public var currentStepFrontier: Int {
        guard let step = currentStep else { return -1 }
        if step.sections.isEmpty { return -1 }
        for (i, s) in step.sections.enumerated() {
            if (s.status != .approved && s.status != .pending) || s.requiresUpdate {
                return i
            }
        }
        return step.sections.count - 1
    }

    /// Tier frontier — the first step that's not fully completed
    /// OR has any section flagged `requiresUpdate`.
    public var tierFrontier: Int {
        guard let schema, !schema.steps.isEmpty else { return -1 }
        for (i, step) in schema.steps.enumerated() {
            if step.sections.isEmpty { return i }
            if step.requiresUpdate { return i }
            let allDone = step.sections.allSatisfy {
                ($0.status == .approved || $0.status == .pending) && !$0.requiresUpdate
            }
            if !allDone { return i }
        }
        return schema.steps.count - 1
    }

    private func validateCurrentSection() -> Bool {
        guard let section = currentSection else { return true }
        // Mirror any sub-field writes into their parent sysSelect's
        // composite BEFORE running validation. Sub-field renderers
        // (BvnFieldView, ConsentFieldView, FileFieldView, etc.) write to
        // session.values[subField.id] at the top level — they don't
        // know they're nested inside a sysSelect. The web's
        // SysSelectField intercepts the sub-field's onChange to route
        // into the composite; iOS doesn't have that interception, so we
        // sync here. Without this, validation and BuildSubmission would
        // both see an empty `composite.values` dict — the user would
        // verify BVN successfully, tap Continue, and the backend would
        // reject with "KYC payload cannot be empty. Error Code: 101".
        mirrorSysSelectSubValues(in: section)
        // Per-kind validation in SectionValidator — matches the web's
        // engine/processing/validate.ts behaviour 1:1 so the same
        // backend schema validates identically on both clients (file
        // uploads checked for `fileId`, consent fields for
        // `consentAcceptanceId`, sysSelect recurses into sub-fields,
        // email/url/number/time format checks, etc.).
        fieldErrors = SectionValidator.validate(section: section, values: values)
        return fieldErrors.isEmpty
    }

    /// Copy each sub-field's value (stored at top-level by the field
    /// renderer) into the parent sysSelect's composite `values` dict so
    /// the canonical data model matches the web's. Idempotent — safe to
    /// call before every validate/submit.
    private func mirrorSysSelectSubValues(in section: WidgetSection) {
        for parent in section.fields where parent.kind == .sysSelect {
            guard let composite = values[parent.id]?.dictValue else { continue }
            // Recurse so a sysSelect sub-field's own composite gets mirrored
            // BEFORE we snapshot it into the parent's values dict. Without
            // recursion, the outer composite carries a stale inner composite
            // and the leaf provider's sub-field values never reach the wire.
            let mirrored = mirrorOneSysSelect(parent: parent, composite: composite)
            values[parent.id] = .object(mirrored)
        }
    }

    /// Recursive worker for ``mirrorSysSelectSubValues(in:)``. For each
    /// immediate sub-field of the selected option, copies its top-level value
    /// into the composite's `values` dict. When a sub-field is itself a
    /// sysSelect, its inner composite is mirrored first (depth-first) so the
    /// nested values propagate end-to-end.
    private func mirrorOneSysSelect(
        parent: WidgetField,
        composite: [String: AnyCodable]
    ) -> [String: AnyCodable] {
        var out = composite
        guard let selectedType = composite["selectedType"]?.stringValue,
              // Immediate-level lookup — each composite's selectedType is the
              // user's choice at THAT level. The tree-walk happens via the
              // recursion below, not via findSysSelectOptionByType here.
              let options = parent.sysSelectOptions,
              let option = options.first(where: { $0.providerType == selectedType }) else { return out }
        var subValues = composite["values"]?.dictValue ?? [:]
        for sub in option.fields {
            let v = values[sub.id]
            if sub.kind == .sysSelect, let innerDict = v?.dictValue {
                subValues[sub.name] = .object(mirrorOneSysSelect(parent: sub, composite: innerDict))
            } else if let v {
                subValues[sub.name] = v
            }
        }
        out["values"] = .object(subValues)
        return out
    }

    // MARK: - Submit

    public func submitCurrentSection() async {
        guard let section = currentSection, let step = currentStep else { return }
        guard let schema else { return }
        guard validateCurrentSection() else { return }
        phase = .submitting
        submissionError = nil
        widget?.dispatchSubmit(payload: section)

        if !config.demoMode {
            // Fast paths: when the section is "self-completing" via a
            // consent-based provider (BVN webhook, NIN/DL/Passport
            // auto-completion, CAC self-completion), the kyc_v2 row was
            // already written server-side. Calling submitKyc here would
            // hit the legacy direct-verification switch — which doesn't
            // know about these consent-based shapes — and reject with
            // "Direct verification for bvn is not enabled" / "We don't
            // have support for X yet" / similar. Web mirrors these in
            // `widgetStore.submitSection` (Branches A/A2/A3).
            if sectionIsAutoCompletedServerSide(section) {
                await refreshSchemaPreservingCursor()
                await advanceAfterSuccessfulSubmit(schema: schema, step: step)
                return
            }

            // Real submission path for everything else.
            let payload = BuildSubmission.build(
                processToken: schema.processToken,
                step: step,
                section: section,
                values: values
            )

            // Branch B-CAC — composite CAC: a `cac_business_lookup` field
            // HELD a kyc_v2 row (executeCacBusinessChecks) and this section
            // has sibling fields. Finalize so those siblings merge into the
            // SAME CAC submission rather than a separate row. A CAC-only
            // section was already short-circuited by
            // sectionIsAutoCompletedServerSide above. Mirrors web
            // widgetStore.ts "Branch B-CAC" and Android KYCWidgetSession —
            // ordered BEFORE the consent branch and the V1 fallback.
            if let cacId = payload.cacKycSubmissionId {
                let cacApi = CacAPI(client: client)
                var additional: [String: Any] = [
                    "kycPayload": payload.kycPayload.map { $0.toDictionary() },
                ]
                if let optionalType = payload.optionalType { additional["optionalType"] = optionalType }
                do {
                    let res = try await cacApi.finalizeCacRequirement(
                        processToken: payload.processToken,
                        kycSubmissionId: cacId,
                        providerId: payload.providerId,
                        levelSlug: payload.levelSlug,
                        additionalPayload: additional
                    )
                    let state = (res.requirementState ?? "").lowercased()
                    if state == "failed" || state == "rejected" {
                        submissionError = res.message ?? "The CAC requirement could not be completed."
                        widget?.dispatchError(.submissionFailed(message: submissionError ?? "Unknown"))
                        phase = .ready
                        return
                    }
                    await refreshSchemaPreservingCursor()
                } catch {
                    submissionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    widget?.dispatchError(.submissionFailed(message: submissionError ?? "Unknown"))
                    phase = .ready
                    return
                }
            }
            // V2 route — section carries a consent reference. Use the
            // V2 `finalizeRequirement` mutation (Flow A). The legacy
            // `KycSubmission` / `KycPayloadV2` input type doesn't
            // define `consentReference` and rejects the request with
            // 'Field "consentReference" is not defined by type
            // "KycPayloadV2"'. Mirrors `widgetStore.ts:submitSection`
            // Branch B in the web.
            else if let cid = payload.consentAcceptanceId {
                print("[KYC Submit] V2 path — finalizeRequirement cid=\(cid.prefix(8))… ref=\(payload.consentReference?.prefix(8) ?? "-")")
                let consentApi = ConsentAPI(client: client)
                var additional: [String: Any] = [
                    "kycPayload": payload.kycPayload.map { $0.toDictionary() },
                ]
                if let optionalType = payload.optionalType { additional["optionalType"] = optionalType }
                do {
                    let res = try await consentApi.finalizeRequirement(
                        processToken: payload.processToken,
                        consentAcceptanceId: cid,
                        providerId: payload.providerId,
                        levelSlug: payload.levelSlug,
                        consentReference: payload.consentReference,
                        additionalPayload: additional
                    )
                    let state = res.requirementState.lowercased()
                    if state == "failed" || state == "rejected" {
                        submissionError = res.message ?? "The requirement could not be completed."
                        widget?.dispatchError(.submissionFailed(message: submissionError ?? "Unknown"))
                        phase = .ready
                        return
                    }
                    await refreshSchemaPreservingCursor()
                } catch {
                    submissionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    widget?.dispatchError(.submissionFailed(message: submissionError ?? "Unknown"))
                    phase = .ready
                    return
                }
            } else {
                // V1 route — plain section with no consent. Legacy
                // `KycSubmission` mutation accepts `KycPayloadV2`.
                let api = KycSubmissionAPI(client: client)
                do {
                    _ = try await api.submit(payload)
                    await refreshSchemaPreservingCursor()
                } catch {
                    submissionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    widget?.dispatchError(.submissionFailed(message: submissionError ?? "Unknown"))
                    phase = .ready
                    return
                }
            }
        } else {
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        await advanceAfterSuccessfulSubmit(schema: schema, step: step)
    }

    /// Was the section already completed server-side via a consent-based
    /// provider's webhook (so we MUST NOT call submitKyc)? 1:1 with the
    /// web's three fast-path detectors in
    /// `kyc-web-wiget-v2/src/state/widgetStore.ts` (Branches A / A2 / A3):
    ///   • NIN / DL / Passport auto-completed (consent value carries
    ///     `autoCompleted: true`)
    ///   • CAC business lookup self-completed (value has kycSubmissionId)
    ///   • BVN-only section (direct or sysSelect-wrapped) with value
    ///     `"completed"` — the BVN provider's webhook writes kyc_v2
    ///     directly, and calling submitKyc afterwards hits the legacy
    ///     direct-verification switch which rejects with
    ///     "Direct verification for bvn is not enabled for this business."
    private func sectionIsAutoCompletedServerSide(_ section: WidgetSection) -> Bool {
        let isSingleField = section.fields.count == 1
        guard isSingleField, let only = section.fields.first else { return false }

        // (1) NIN / DL / Passport — autoCompleted flag in the consent value.
        if only.kind == .ninConsent || only.kind == .driversLicenseConsent || only.kind == .passportConsent {
            return values[only.id]?.dictValue?["autoCompleted"]?.boolValue == true
        }

        // (2) CAC self-completed — value has a kycSubmissionId / _id.
        if only.kind == .cacBusinessLookup {
            let dict = values[only.id]?.dictValue
            let id = dict?["kycSubmissionId"]?.stringValue ?? dict?["_id"]?.stringValue ?? ""
            return !id.isEmpty
        }

        // (3) BVN — direct OR sysSelect-wrapped, in both cases value="completed".
        if only.kind == .bvn {
            return values[only.id]?.stringValue == "completed"
        }
        if only.kind == .sysSelect,
           let composite = values[only.id]?.dictValue {
            // Walk to the LEAF composite — the user might have reached `bvn`
            // through a wrapper sysSelect (e.g. identity_method → bvn). The
            // old top-level selectedType check returned false for nested
            // selections and we'd then mis-route to V1 submitKyc.
            let (leafType, leafValues) = SysSelectTraversal.resolveLeaf(composite)
            guard leafType == "bvn", let subValues = leafValues else { return false }
            return subValues.values.contains(where: { $0.stringValue == "completed" })
        }
        return false
    }

    /// Common section-advancement logic shared by the real submit path
    /// and the fast-path skip. Fires lifecycle callbacks and moves the
    /// cursor forward.
    ///
    /// `onLevelApproved` is NOT dispatched inline here — the post-
    /// submit `refreshSchemaPreservingCursor` re-runs `loadSchema`,
    /// which calls `dispatchLevelApprovalTransitions`, which compares
    /// the fresh step statuses against `approvedDispatchedSlugs` and
    /// fires for any step that just flipped to fully-approved. That
    /// path catches BOTH cases:
    ///   • user's own submit completed the last section of a step,
    ///   • merchant (or auto-approval) approved a previously-pending
    ///     section so the step is now fully approved.
    /// The inline call we used to make here only handled the first
    /// case and would double-fire once the refresh detector picked up
    /// the same transition.
    private func advanceAfterSuccessfulSubmit(schema: WidgetSchema, step: WidgetStep) async {
        phase = .ready
        let steps = schema.steps
        let isLastSection = currentSectionIndex >= ((currentStep?.sections.count ?? 1) - 1)
        let isLastStep = currentStepIndex >= (steps.count - 1)

        if isLastSection && isLastStep {
            completed = true
            widget?.dispatchSuccess()
        } else if isLastSection {
            currentStepIndex += 1
            currentSectionIndex = 0
            if let step = currentStep {
                widget?.dispatchLevelChange(
                    KYCWidgetLevel(slug: step.slug, index: currentStepIndex)
                )
            }
        } else {
            currentSectionIndex += 1
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
