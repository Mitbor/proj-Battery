// Minimal MQTT 3.1.1 client over TLS (Network framework): subscribes to /open/<account>/<sn>/quota.
// The station publishes changes there every 1–3 seconds.

import Foundation
import Network

final class MQTTFeed {
    var onParams: (([String: Any]) -> Void)?   // keys already prefixed: "pd.soc", "inv.inputWatts", or flat new-gen keys
    var onClosed: ((String) -> Void)?
    var onSubscribed: (() -> Void)?

    private let queue = DispatchQueue(label: "ecoflow.mqtt")
    private var conn: NWConnection?
    private var buffer: [UInt8] = []
    private var pinger: DispatchSourceTimer?
    private var closed = false
    private var topic = ""
    private var loggedSample = false

    func connect(host: String, port: UInt16, user: String, password: String, topic: String) {
        self.topic = topic
        let params = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        guard let p = NWEndpoint.Port(rawValue: port) else { finish("bad broker port"); return }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
        conn = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let clientId = user + "_tray_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)
                // CONNECT (clean session, user+password, keepalive 60 s)
                self.send(0x10, self.str("MQTT") + [4, 0xC2, 0, 60] + self.str(String(clientId)) + self.str(user) + self.str(password))
                self.startPinger()
                self.receive()
            case .failed(let e):
                self.finish("connection failed: \(e.localizedDescription)")
            case .waiting(let e):
                self.finish("cannot connect: \(e.localizedDescription)")
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.closed = true
            self.pinger?.cancel(); self.pinger = nil
            self.conn?.cancel(); self.conn = nil
        }
    }

    private func finish(_ reason: String) {
        guard !closed else { return }
        closed = true
        pinger?.cancel(); pinger = nil
        conn?.cancel(); conn = nil
        onClosed?(reason)
    }

    private func startPinger() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in self?.send(0xC0, []) }
        t.resume()
        pinger = t
    }

    private func receive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty { self.buffer.append(contentsOf: data); self.parse() }
            if let error { self.finish("receive error: \(error.localizedDescription)"); return }
            if isComplete { self.finish("connection closed by the server"); return }
            self.receive()
        }
    }

    private func parse() {
        while !closed {
            guard buffer.count >= 2 else { return }
            var len = 0, mul = 1, i = 1
            while true {
                guard i < buffer.count else { return }          // remaining-length not fully received yet
                let b = Int(buffer[i]); i += 1
                len += (b & 127) * mul; mul *= 128
                if b & 128 == 0 { break }
                if i > 4 { finish("malformed MQTT packet"); return }
            }
            guard buffer.count >= i + len else { return }      // body not fully received yet
            let header = buffer[0]
            let body = Array(buffer[i ..< i + len])
            buffer.removeFirst(i + len)
            handle(header: header, body: body)
        }
    }

    private func handle(header: UInt8, body: [UInt8]) {
        switch header >> 4 {
        case 2: // CONNACK
            guard body.count >= 2, body[1] == 0 else {
                finish("broker rejected the login (code \(body.count > 1 ? Int(body[1]) : -1))"); return
            }
            send(0x82, [0, 1] + str(topic) + [1])
        case 9: // SUBACK
            if body.count >= 3, body[2] == 0x80 { finish("subscription rejected"); return }
            onSubscribed?()
        case 3: // PUBLISH
            guard body.count >= 2 else { return }
            let tl = Int(body[0]) << 8 | Int(body[1])
            var off = 2 + tl
            if (header >> 1) & 3 > 0, body.count >= off + 2 {
                send(0x40, [body[off], body[off + 1]])   // PUBACK
                off += 2
            }
            guard off <= body.count,
                  let msg = (try? JSONSerialization.jsonObject(with: Data(body[off...]))) as? [String: Any] else { return }
            handleMessage(msg)
        default:
            break
        }
    }

    private func handleMessage(_ msg: [String: Any]) {
        // River 2 / Delta 2 use "params"; some newer models use "param"
        guard let p = (msg["params"] ?? msg["param"]) as? [String: Any], !p.isEmpty else { return }
        if !loggedSample {
            // one sample per session — helps to add support for an unfamiliar model
            loggedSample = true
            NSLog("EcoFlowTray MQTT sample (%@): %@", "\(msg["typeCode"] ?? "no typeCode")", p.keys.sorted().prefix(40).joined(separator: ", "))
        }
        let prefix: String
        switch "\(msg["typeCode"] ?? "")" {
        case "pdStatus": prefix = "pd."
        case "bmsStatus": prefix = "bms_bmsStatus."
        case "emsStatus": prefix = "bms_emsStatus."
        case "invStatus": prefix = "inv."
        case "mpptStatus": prefix = "mppt."
        default: prefix = ""
        }
        var out: [String: Any] = [:]
        for (k, v) in p {
            out[k.contains(".") || prefix.isEmpty ? k : prefix + k] = v   // full key, or new-generation flat key
        }
        onParams?(out)
    }

    private func str(_ s: String) -> [UInt8] {
        let b = Array(s.utf8)
        return [UInt8(b.count >> 8), UInt8(b.count & 0xFF)] + b
    }

    private func send(_ type: UInt8, _ body: [UInt8]) {
        var pkt: [UInt8] = [type]
        var len = body.count
        repeat {
            var b = UInt8(len % 128); len /= 128
            if len > 0 { b |= 128 }
            pkt.append(b)
        } while len > 0
        pkt += body
        conn?.send(content: Data(pkt), completion: .contentProcessed { _ in })
    }
}
