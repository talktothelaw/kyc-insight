import Foundation

func livenessWireEntries(name: String, value: AnyCodable?) -> [(String, String)] {
    guard let dict = value?.dictValue else { return [(name, "")] }
    if dict["skipped"]?.boolValue == true { return [("liveness_skipped", "true")] }
    let selfie = dict["selfieImage"]?.stringValue ?? dict["fileId"]?.stringValue ?? ""
    var entries: [(String, String)] = [(name, selfie)]
    if let frames = dict["livelinessImages"]?.arrayValue,
       let data = try? JSONSerialization.data(withJSONObject: frames.compactMap { $0.stringValue }),
       let json = String(data: data, encoding: .utf8) {
        entries.append(("liveliness_images", json))
    }
    if let token = dict["livenessSessionId"]?.stringValue, !token.isEmpty { entries.append(("livenessSessionId", token)) }
    return entries
}
