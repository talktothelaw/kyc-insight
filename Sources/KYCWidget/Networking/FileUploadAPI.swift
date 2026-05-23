import Foundation

/// 1:1 Swift port of `kyc-web-wiget-v2/src/services/fileUploadApi.ts`.
///
/// Three-step pipeline:
///   1. `RequestFileUploadTwo` (GraphQL mutation) — backend creates an
///      `uploadFile` row, returns its ObjectId (`fileId`).
///   2. `POST {apiBaseUrl}/file/upload/{fileId}` (multipart) — raw bytes
///      uploaded directly to S3 via the kyc-backend proxy.
///   3. `completeFileUploadTwo` (GraphQL mutation) — marks the row saved.
@MainActor
final class FileUploadAPI {
    private let client: GraphQLClient
    init(client: GraphQLClient) { self.client = client }

    enum FileEnum: String, Sendable {
        case pdf, doc, jpeg, png, jpg, msword
    }

    struct UploadResult {
        let fileId: String
        let fileEnum: FileEnum
    }

    static func detect(mime: String?, name: String?) -> FileEnum? {
        let m = (mime ?? "").lowercased()
        let n = (name ?? "").lowercased()
        if m == "application/pdf" || n.hasSuffix(".pdf") { return .pdf }
        if m == "image/png"       || n.hasSuffix(".png") { return .png }
        if n.hasSuffix(".jpeg") { return .jpeg }
        if m == "image/jpeg"      || n.hasSuffix(".jpg") { return .jpg }
        if m == "application/msword" || n.hasSuffix(".doc") { return .doc }
        if m == "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            || n.hasSuffix(".docx") { return .msword }
        return nil
    }

    /// Run the full pipeline. Returns the fileId the caller stores as the
    /// field value; submission emits it as `kycPayload.value` and the
    /// backend swaps it for the S3 key at submit time.
    ///
    /// `fieldName` scopes the upload to a specific field on the level —
    /// when a level has multiple file fields (e.g. `utility_bill` AND
    /// `drivers_license`) they'd otherwise collide and the second upload
    /// would overwrite the first server-side. Mirrors the web's
    /// `uploadFile(client, { file, processToken, kycType, fieldName })`
    /// signature (services/fileUploadApi.ts).
    func upload(
        data: Data,
        fileName: String,
        mimeType: String?,
        processToken: String,
        kycType: String,
        fieldName: String? = nil
    ) async throws -> UploadResult {
        guard let detected = Self.detect(mime: mimeType, name: fileName) else {
            throw GraphQLClientError.server(message: "Unsupported file type for \(fileName).", code: "UNSUPPORTED_TYPE")
        }

        // Step 1 — request an upload row.
        let request = """
        mutation RequestFileUploadTwo($file: FileEnum!, $processToken: String!, $kycType: String!, $fieldName: String) {
          RequestFileUploadTwo(file: $file, processToken: $processToken, kycType: $kycType, fieldName: $fieldName)
        }
        """
        var vars: [String: Any] = ["file": detected.rawValue, "processToken": processToken, "kycType": kycType]
        vars["fieldName"] = fieldName ?? NSNull()
        let fileId = try await client.execute(
            query: request,
            variables: vars,
            rootField: "RequestFileUploadTwo",
            as: String.self
        )

        // Step 2 — POST raw bytes to the REST upload route.
        try await postBytes(data: data, fileName: fileName, fileId: fileId)

        // Step 3 — mark upload complete.
        let complete = """
        mutation CompleteFileUploadTwo($status: Boolean!, $processToken: String!, $kycType: String!, $key: String) {
          completeFileUploadTwo(status: $status, processToken: $processToken, kycType: $kycType, key: $key) {
            error
            message
          }
        }
        """
        struct CompleteResult: Decodable { let error: Bool; let message: String? }
        let _ = try await client.execute(
            query: complete,
            variables: ["status": true, "processToken": processToken, "kycType": kycType, "key": fileId],
            rootField: "completeFileUploadTwo",
            as: CompleteResult.self
        )

        return UploadResult(fileId: fileId, fileEnum: detected)
    }

    /// Two-line multipart upload to `{apiBaseUrl}/file/upload/{fileId}`.
    /// Same `x-public-key` header as the GraphQL endpoint — backend's
    /// `fileUploadV2/fileRoute.ts` validates it.
    private func postBytes(data: Data, fileName: String, fileId: String) async throws {
        let url = client.apiBaseURL.appendingPathComponent("file/upload/\(fileId)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let boundary = "kyc-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(client.publicKey, forHTTPHeaderField: "x-public-key")
        var body = Data()
        let line: (String) -> Void = { body.append(($0 + "\r\n").data(using: .utf8)!) }
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"")
        line("Content-Type: application/octet-stream")
        line("")
        body.append(data)
        line("")
        line("--\(boundary)--")
        request.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GraphQLClientError.server(message: "File upload failed (HTTP \(http.statusCode)).", code: "UPLOAD_FAILED")
        }
    }
}
