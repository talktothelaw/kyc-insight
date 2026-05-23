import Foundation

/// Built-in demo schema. Used only when ``KYCWidgetConfig/demoMode`` is
/// `true` — never as a silent fallback for backend errors. Mirrors the
/// shape the real ``SchemaNormalizer`` produces so the renderer code paths
/// are identical.
enum DemoSchema {
    static func make() -> WidgetSchema {
        WidgetSchema(
            processToken: "demo-process-token",
            steps: [
                WidgetStep(
                    id: "tier_1", name: "Personal details", slug: "tier_1",
                    status: .initialized,
                    sections: [
                        WidgetSection(
                            id: "p_personal", name: "Personal information",
                            status: .initialized,
                            providerId: "p_personal", providerType: "personal_info",
                            fields: [
                                WidgetField(id: "fullName",  name: "fullName",  label: "Full name",     kind: .text,  required: true),
                                WidgetField(id: "email",     name: "email",     label: "Email address", kind: .email, required: true),
                                WidgetField(id: "phone",     name: "phone",     label: "Phone number",  kind: .text,  required: true),
                                WidgetField(id: "dob",       name: "dob",       label: "Date of birth", kind: .date,  required: true),
                                WidgetField(
                                    id: "gender", name: "gender", label: "Gender", kind: .select, required: true,
                                    options: [
                                        WidgetOption(label: "Male",   value: "m"),
                                        WidgetOption(label: "Female", value: "f"),
                                        WidgetOption(label: "Prefer not to say", value: "x"),
                                    ]
                                ),
                                WidgetField(
                                    id: "marital", name: "marital", label: "Marital status", kind: .radio, required: false,
                                    options: [
                                        WidgetOption(label: "Single",  value: "single"),
                                        WidgetOption(label: "Married", value: "married"),
                                        WidgetOption(label: "Other",   value: "other"),
                                    ]
                                ),
                                WidgetField(id: "terms", name: "terms", label: "I agree to the verification terms and consent to data processing.", kind: .checkbox, required: true),
                            ]
                        ),
                        WidgetSection(
                            id: "p_address", name: "Address",
                            status: .initialized,
                            providerId: "p_address", providerType: "address",
                            fields: [
                                WidgetField(id: "street",  name: "street",  label: "Street", kind: .text, required: true),
                                WidgetField(id: "city",    name: "city",    label: "City",   kind: .text, required: true),
                                WidgetField(
                                    id: "country", name: "country", label: "Country", kind: .select, required: true,
                                    options: [
                                        WidgetOption(label: "Nigeria",      value: "NG"),
                                        WidgetOption(label: "Ghana",        value: "GH"),
                                        WidgetOption(label: "Kenya",        value: "KE"),
                                        WidgetOption(label: "South Africa", value: "ZA"),
                                    ]
                                ),
                            ]
                        ),
                        WidgetSection(
                            id: "p_selfie", name: "Selfie + liveness",
                            status: .initialized,
                            providerId: "p_selfie", providerType: "selfie",
                            fields: [
                                WidgetField(id: "selfie",        name: "selfie",        label: "Take a selfie",     kind: .image,    required: true, kycType: "selfie"),
                                WidgetField(id: "documentFront", name: "documentFront", label: "Document — front",  kind: .file,     required: true, kycType: "id_document"),
                            ]
                        ),
                    ]
                ),
                WidgetStep(
                    id: "tier_2", name: "Identity verification", slug: "tier_2",
                    status: .initialized,
                    sections: [
                        // Already-approved section — read-only "Already approved" panel.
                        WidgetSection(
                            id: "p_nin", name: "NIN consent",
                            status: .approved,
                            providerId: "p_nin", providerType: "nin_consent",
                            fields: [
                                WidgetField(id: "nin", name: "nin", label: "Verify your NIN", kind: .ninConsent, required: true),
                            ]
                        ),
                        // Pending-review section — read-only "Submission pending review" panel.
                        WidgetSection(
                            id: "p_email_verify", name: "Email verification",
                            status: .pending,
                            providerId: "p_email_verify", providerType: "email_verification",
                            fields: [
                                WidgetField(id: "verify_email", name: "verify_email", label: "Confirm your email", kind: .email, required: true),
                            ]
                        ),
                        // Rejected section — keeps form + shows the RejectionBanner above it.
                        WidgetSection(
                            id: "p_doc", name: "Supporting document",
                            status: .rejected,
                            providerId: "p_doc", providerType: "document_upload",
                            fields: [
                                WidgetField(id: "doc",     name: "doc",     label: "Supporting document", kind: .file,   required: true, kycType: "supporting_doc"),
                                WidgetField(id: "notes",   name: "notes",   label: "Notes (optional)",    kind: .text,   required: false),
                                WidgetField(id: "website", name: "website", label: "Website (optional)",  kind: .url,    required: false),
                            ]
                        ),
                    ]
                ),
                WidgetStep(
                    id: "tier_3", name: "Final review", slug: "tier_3",
                    status: .initialized,
                    sections: [
                        WidgetSection(
                            id: "p_confirm", name: "Confirmation",
                            status: .initialized,
                            providerId: "p_confirm", providerType: "confirm",
                            fields: [
                                WidgetField(id: "confirm", name: "confirm", label: "I confirm that everything I've submitted is accurate.", kind: .checkbox, required: true),
                            ]
                        ),
                    ]
                ),
            ]
        )
    }
}
