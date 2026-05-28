#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// The native KYC widget SwiftUI root.
///
/// Layout (mobile-first):
///   • Sticky header — close button + flow title + progress strip.
///   • Section progress strip — tier badge + counter + thin progress bar.
///   • Scrollable section content — fields rendered via FieldRenderer.
///   • Footer — Back + Continue.
///   • Brand footer — KYC Insight credit.
///
/// Tapping the progress strip's badge opens the journey outline as a
/// bottom sheet (mirrors the web widget's left rail).
@available(iOS 15.0, *)
struct KYCWidgetView: View {
    @ObservedObject var session: KYCWidgetSession
    let onRequestClose: () -> Void

    @State private var showOutline = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            content
            Divider().opacity(0.6)
            footer
            BrandFooter()
        }
        .background(Color(.systemBackground))
        .kycBranded()    // ← navy primary tint propagates through the whole tree
        .task {
            if case .idle = session.phase {
                await session.loadSchema()
            }
        }
        .sheet(isPresented: $showOutline) {
            outlineSheet
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(headerEyebrow.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundColor(.secondary)
                    Text(headerTitle)
                        .font(.system(size: 18, weight: .semibold))
                }
                Spacer()
                Button(action: onRequestClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(Circle())
                }
                .accessibilityLabel("Close verification")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            if session.phase == .ready || session.phase == .submitting {
                SectionProgressStrip(session: session) { showOutline = true }
            }
        }
    }

    private var headerEyebrow: String {
        guard let total = session.schema?.steps.count, total > 1 else { return "Verification" }
        return "Tier \(session.currentStepIndex + 1) of \(total)"
    }
    private var headerTitle: String {
        session.currentStep?.name ?? "KYC Verification"
    }

    // MARK: - Outline sheet (journey)

    private var outlineSheet: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your verification journey")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .padding(.bottom, 8)
                    JourneyOutlineView(session: session) { tierIdx, sectionIdx in
                        session.goToSection(stepIndex: tierIdx, sectionIndex: sectionIdx)
                        showOutline = false
                    }
                }
                .padding(20)
            }
            .navigationTitle("Progress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showOutline = false }
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .idle, .loading:
            loadingView
        case .error:
            errorView
        case .ready, .submitting:
            if session.completed {
                completedView
            } else if let section = session.currentSection {
                sectionView(section)
            } else {
                emptyView
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Loading verification…")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorView: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundColor(.orange)
            Text("Couldn't load verification").font(.headline)
            Text(session.loadError ?? "Unknown error")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try again") { Task { await session.loadSchema() } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray").font(.system(size: 36)).foregroundColor(.secondary)
            Text("No verification steps configured").font(.headline)
            Text("This KYC flow has no fields configured. Add tiers + sections in the merchant dashboard.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var completedView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.green.opacity(0.12)).frame(width: 88, height: 88)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.green)
            }
            Text("Verification submitted")
                .font(.title3.weight(.semibold))
            Text("Your details have been received and will be processed. You'll receive an update once the review is complete.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionView(_ section: WidgetSection) -> some View {
        // Mirrors WidgetRoot.tsx — branch on section status:
        //  • approved | pending → SubmissionStatusPanel (no form)
        //  • rejected            → RejectionBanner above form (still editable)
        //  • initialized         → plain form
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(section)
                if session.isCurrentSectionReadOnly {
                    SubmissionStatusPanelView(
                        section: section,
                        // Offer the "Back to current step" CTA only when the
                        // cursor is BEHIND the frontier (i.e. somewhere
                        // forward is the actual current section). Same gate
                        // the web applies via `frontierIndex > currentSectionIndex`.
                        onBackToCurrent: session.currentStepFrontier > session.currentSectionIndex
                            ? { session.goToSection(stepIndex: session.currentStepIndex,
                                                    sectionIndex: session.currentStepFrontier) }
                            : nil
                    )
                } else {
                    if section.status == .rejected {
                        RejectionBannerView(
                            processToken: session.schema?.processToken ?? "",
                            kycType:      section.providerType,
                            publicKey:    session.config.publicKey,
                            endpoint:     session.config.gqlEndpoint
                        )
                    } else if section.requiresUpdate {
                        // Backend stamped some required field as
                        // unsupplied — surface the reason so the user
                        // understands why a previously-engaged section
                        // is asking for more input.
                        LevelUpdateBannerView(reason: section.requiresUpdateReason)
                    }
                    if section.fields.isEmpty {
                        Text("This section has no fields.")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    VStack(spacing: 14) {
                        // On `requiresUpdate` sections, hide fields the
                        // backend stamped `alreadySupplied: true` — the
                        // user shouldn't be asked to retype what the
                        // merchant already has on the kyc_v2 row. The
                        // hidden fields stay in `section.fields` so
                        // validation + submission see the same shape;
                        // `SectionValidator` skips them (satisfied) and
                        // `BuildSubmission`'s empty-value filter keeps
                        // them off the wire so the backend keeps the
                        // prior value untouched.
                        let visibleFields = section.requiresUpdate
                            ? section.fields.filter { $0.alreadySupplied != true }
                            : section.fields
                        ForEach(visibleFields) { field in
                            FieldRenderer(field: field, session: session)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
    }

    private func sectionHeader(_ section: WidgetSection) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(section.name)
                    .font(.system(size: 20, weight: .semibold))
                if !section.fields.isEmpty {
                    let count = section.fields.count
                    Text("\(count) field\(count == 1 ? "" : "s") in this section")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            StatusPill(status: section.status)
        }
    }

    // MARK: - Footer (Back / Continue)

    private var footer: some View {
        VStack(spacing: 8) {
            // Inline submission error — appears above the Back / Continue row.
            // Mirrors WidgetRoot.tsx's `kyc-alert kyc-alert-error` block:
            // when the backend rejects the submission, the user sees WHY
            // before re-tapping Continue.
            if let submissionError = session.submissionError, !session.isCurrentSectionReadOnly {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 14))
                    Text(submissionError)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.red.opacity(0.35), lineWidth: 1)
                )
                .cornerRadius(8)
            }
            HStack(spacing: 10) {
                Button {
                    session.goBack()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        Text("Back")
                    }
                    .frame(minWidth: 80)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(session.currentStepIndex == 0 && session.currentSectionIndex == 0)
                Spacer()
                // Read-only sections swap Continue for Next — there's nothing to
                // submit, but the user should still be able to walk forward
                // through approved sections one step at a time without jumping
                // to the frontier via the inline panel CTA.
                if session.isCurrentSectionReadOnly {
                    if session.canGoForward {
                        Button {
                            session.goForward()
                        } label: {
                            HStack(spacing: 4) {
                                Text("Next").font(.system(size: 15, weight: .semibold))
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                            }
                            .frame(minWidth: 100)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                } else {
                    Button {
                        Task { await session.submitCurrentSection() }
                    } label: {
                        HStack(spacing: 6) {
                            if session.phase == .submitting {
                                ProgressView().tint(.white)
                            }
                            Text(continueLabel)
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(session.phase == .submitting || session.phase == .loading || session.completed)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
    }

    private var continueLabel: String {
        if session.phase == .submitting { return "Submitting…" }
        let steps = session.schema?.steps ?? []
        let isLastSection = session.currentSectionIndex >= ((session.currentStep?.sections.count ?? 1) - 1)
        let isLastStep = session.currentStepIndex >= (steps.count - 1)
        return (isLastSection && isLastStep) ? "Submit" : "Continue"
    }
}
#endif
