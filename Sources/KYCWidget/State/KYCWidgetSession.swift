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

    public init(config: KYCWidgetConfig) {
        self.config = config
        self.client = GraphQLClient(endpoint: config.gqlEndpoint, publicKey: config.publicKey)
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
            self.phase = .ready
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

    /// Find the first not-yet-completed section. Mirrors the web's
    /// `findResumePosition`.
    private func findResumePosition(_ schema: WidgetSchema) -> (step: Int, section: Int) {
        for (stepIdx, step) in schema.steps.enumerated() {
            for (secIdx, section) in step.sections.enumerated() {
                if section.status == .initialized || section.status == .rejected {
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
        } else if currentStepIndex > 0 {
            currentStepIndex -= 1
            currentSectionIndex = (schema?.steps[safe: currentStepIndex]?.sections.count ?? 1) - 1
        }
    }

    // MARK: - Field values

    public func setValue(_ value: AnyCodable, for fieldID: String) {
        values[fieldID] = value
        if fieldErrors[fieldID] != nil { fieldErrors[fieldID] = nil }
    }

    public var currentStep: WidgetStep? { schema?.steps[safe: currentStepIndex] }
    public var currentSection: WidgetSection? { currentStep?.sections[safe: currentSectionIndex] }

    /// True when the current section is read-only — already submitted
    /// (`approved` or `pending`). Mirrors `WidgetRoot.tsx:isReadOnlySection`.
    public var isCurrentSectionReadOnly: Bool {
        guard let s = currentSection else { return false }
        return s.status == .approved || s.status == .pending
    }

    /// Frontier for the *current* step: the first section index the user
    /// is allowed to navigate forward to. Indices > frontier are locked
    /// (no skipping ahead). Indices < frontier are completed and clickable.
    /// Mirrors `widgetStore.getNavigableFrontier`.
    public var currentStepFrontier: Int {
        guard let step = currentStep else { return -1 }
        if step.sections.isEmpty { return -1 }
        for (i, s) in step.sections.enumerated()
        where s.status != .approved && s.status != .pending { return i }
        return step.sections.count - 1
    }

    /// Tier frontier — the first step the user hasn't fully completed.
    /// Mirrors `widgetStore.getStepFrontier`.
    public var tierFrontier: Int {
        guard let schema, !schema.steps.isEmpty else { return -1 }
        for (i, step) in schema.steps.enumerated() {
            if step.sections.isEmpty { return i }
            let allDone = step.sections.allSatisfy { $0.status == .approved || $0.status == .pending }
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
            guard var composite = values[parent.id]?.dictValue,
                  let selectedType = composite["selectedType"]?.stringValue,
                  let options = parent.sysSelectOptions,
                  let option = options.first(where: { $0.providerType == selectedType }) else { continue }
            var subValues = composite["values"]?.dictValue ?? [:]
            for sub in option.fields {
                if let v = values[sub.id] {
                    subValues[sub.name] = v
                }
            }
            composite["values"] = .object(subValues)
            values[parent.id] = .object(composite)
        }
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
           let composite = values[only.id]?.dictValue,
           composite["selectedType"]?.stringValue == "bvn" {
            let subValues = composite["values"]?.dictValue ?? [:]
            // Any sub-value === "completed" satisfies — the BVN sub-field's
            // single string value lives there after the mirror step.
            return subValues.values.contains(where: { $0.stringValue == "completed" })
        }
        return false
    }

    /// Common section-advancement logic shared by the real submit path
    /// and the fast-path skip. Fires lifecycle callbacks and moves the
    /// cursor forward.
    private func advanceAfterSuccessfulSubmit(schema: WidgetSchema, step: WidgetStep) async {
        phase = .ready
        let steps = schema.steps
        let isLastSection = currentSectionIndex >= ((currentStep?.sections.count ?? 1) - 1)
        let isLastStep = currentStepIndex >= (steps.count - 1)

        if let stepSlug = currentStep?.slug, isLastSection {
            widget?.dispatchLevelApproved(
                KYCWidgetLevel(slug: stepSlug, index: currentStepIndex)
            )
        }

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
