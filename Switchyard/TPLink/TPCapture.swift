import Foundation
import WebKit

/// Notes which pages the TP-Link's own web interface calls and what they answer (after the page decrypts them),
/// so a native dashboard can be built for firmware Switchyard doesn't know yet. Kept in memory only.
@MainActor
final class TPCapture: ObservableObject {
    static let shared = TPCapture()
    struct Event { var time: Date; var kind: String; var text: String }
    @Published private(set) var events: [Event] = []
    private let start = Date()

    var pageCount: Int { Set(events.filter { $0.kind == "REQ" }.map(\.text)).count }

    func add(_ kind: String, _ text: String) {
        events.append(Event(time: Date(), kind: kind, text: text))
        if events.count > 600 { events.removeFirst(events.count - 600) }
    }

    func clear() { events.removeAll() }

    func report(host: String) -> String {
        var out = ["TP-Link web page at \(host): what its own interface asked for and got back."]
        let pages = Set(events.filter { $0.kind == "REQ" }.map(\.text)).sorted()
        out.append("Pages called (\(pages.count)):")
        out.append(contentsOf: pages.map { "  " + $0 })
        out.append("")
        out.append("Timeline (seconds since Switchyard opened):")
        for e in events {
            out.append(String(format: "%8.2f ", e.time.timeIntervalSince(start)) + e.kind + " " + e.text)
        }
        return out.joined(separator: "\n")
    }

    static let script = #"""
    (function () {
      if (window.__sy) return; window.__sy = 1;
      function post(m) { try { window.webkit.messageHandlers.sy.postMessage(m); } catch (e) {} }
      function clean(u) {
        try { u = String(u && u.url ? u.url : u); } catch (e) { return ''; }
        return u.replace(/;stok=[^\/]*/, ';stok=').replace(/^https?:\/\/[^\/]+/, '');
      }
      var O = XMLHttpRequest.prototype.open, S = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (m, u) { this.__u = clean(u); return O.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function () {
        var x = this; post({ k: 'REQ', v: x.__u });
        x.addEventListener('loadend', function () { post({ k: 'DONE', v: x.status + ' ' + x.__u }); });
        return S.apply(this, arguments);
      };
      if (window.fetch) {
        var F = window.fetch;
        window.fetch = function (i) {
          var u = clean(i); post({ k: 'REQ', v: u });
          return F.apply(this, arguments).then(function (r) { post({ k: 'DONE', v: r.status + ' ' + u }); return r; });
        };
      }
      var P = JSON.parse;
      JSON.parse = function () {
        var r = P.apply(this, arguments);
        try {
          if (r && typeof r === 'object' && !Array.isArray(r) && ('success' in r || 'errorcode' in r)) {
            var s = JSON.stringify(r); post({ k: 'JSON', v: s.length > 4000 ? s.slice(0, 4000) : s });
          }
        } catch (e) {}
        return r;
      };
    })();
    """#

    private static let secretKeys = ["key", "password", "psk", "pwd", "passphrase", "secret", "token", "stok", "sysauth", "wps_pin", "pincode"]

    static func redact(_ v: Any) -> Any {
        if let d = v as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, x) in d {
                let l = k.lowercased()
                if secretKeys.contains(where: { l.contains($0) }), !(x is [String: Any]), !(x is [Any]), "\(x)" != "" {
                    out[k] = "<redacted>"
                } else { out[k] = redact(x) }
            }
            return out
        }
        if let a = v as? [Any] { return a.map(redact) }
        return v
    }

    static func redactedJSON(_ s: String) -> String {
        guard let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)),
              let d = try? JSONSerialization.data(withJSONObject: redact(o), options: [.sortedKeys]) else {
            return "(unreadable, left out)"
        }
        return String(decoding: d, as: UTF8.self)
    }
}

/// Weak bridge so the web view doesn't keep its owner alive.
final class TPCaptureHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let b = m.body as? [String: Any], let k = b["k"] as? String, let v = b["v"] as? String else { return }
        Task { @MainActor in
            TPCapture.shared.add(k, k == "JSON" ? TPCapture.redactedJSON(v) : v)
        }
    }
}
