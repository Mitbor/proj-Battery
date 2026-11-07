// EcoFlow Open API (https://developer.ecoflow.com): signed HTTP requests.

import Foundation
import CryptoKit

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct EcoFlowAPI {
    let accessKey: String
    let secretKey: String
    let host: String

    private func sign(_ params: String) -> (nonce: String, timestamp: String, sign: String) {
        let nonce = String(Int.random(in: 100000...999999))
        let ts = String(Int64(Date().timeIntervalSince1970 * 1000))
        let s = (params.isEmpty ? "" : params + "&") + "accessKey=\(accessKey)&nonce=\(nonce)&timestamp=\(ts)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(s.utf8), using: SymmetricKey(data: Data(secretKey.utf8)))
        return (nonce, ts, mac.map { String(format: "%02x", $0) }.joined())
    }

    private func get(_ path: String, query: String = "") async throws -> [String: Any] {
        let base = host.hasSuffix("/") ? String(host.dropLast()) : host
        guard let url = URL(string: base + path + (query.isEmpty ? "" : "?" + query)) else {
            throw APIError(message: "Bad server address: \(host)")
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        let s = sign(query)
        req.setValue(accessKey, forHTTPHeaderField: "accessKey")
        req.setValue(s.nonce, forHTTPHeaderField: "nonce")
        req.setValue(s.timestamp, forHTTPHeaderField: "timestamp")
        req.setValue(s.sign, forHTTPHeaderField: "sign")

        let data: Data
        do { (data, _) = try await URLSession.shared.data(for: req) }
        catch { throw APIError(message: "Cannot reach \(host): \(error.localizedDescription)") }

        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw APIError(message: "Unexpected answer from \(host)")
        }
        let code = "\(d["code"] ?? "?")"
        if code == "1006" { throw APIError(message: "EcoFlow does not allow this model in the Open API (code 1006)") }
        if code != "0" { throw APIError(message: "EcoFlow API: \(d["message"] ?? "error") (code \(code))") }
        return d
    }

    func listDevices() async throws -> [[String: Any]] {
        let d = try await get("/iot-open/sign/device/list")
        return d["data"] as? [[String: Any]] ?? []
    }

    // Snapshot from the cloud cache. WARNING: the cloud refreshes it rarely (hours apart),
    // so it is only a fallback until live MQTT data arrives.
    func quotaAll(sn: String) async throws -> [String: Any] {
        let q = "sn=" + (sn.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? sn)
        let d = try await get("/iot-open/sign/device/quota/all", query: q)
        guard let data = d["data"] as? [String: Any], !data.isEmpty else {
            throw APIError(message: "The station sent no data (switched off or offline?)")
        }
        return data
    }

    // EcoFlow MQTT broker credentials for the live data stream.
    func certification() async throws -> [String: Any] {
        let d = try await get("/iot-open/sign/certification")
        guard let data = d["data"] as? [String: Any] else { throw APIError(message: "The server returned no MQTT credentials") }
        return data
    }

    static func isStation(_ dev: [String: Any]) -> Bool {
        let pn = "\(dev["productName"] ?? "")".uppercased()
        return pn.contains("RIVER") || pn.contains("DELTA") || pn.contains("TRAIL")
    }
}
