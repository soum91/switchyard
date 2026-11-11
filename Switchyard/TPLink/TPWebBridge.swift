import UIKit
import WebKit

/// Talks to newer TP-Link firmware (TL-WR1502X) through its own web page, loaded invisibly.
/// The page logs in and does its own signing; Switchyard asks it to make each request with the page's
/// exposed window.encrypt / window.decrypt, so it always matches whatever scheme the firmware uses.
@MainActor
final class TPWebBridge: NSObject, WKNavigationDelegate {
    let host: String
    private let password: String
    private let web: WKWebView
    private var stok: String?
    private var loginError: String?
    private var pageLoaded = false
    private(set) var ready = false

    private static let hook = #"""
    (function () {
      if (window.__sybr) return; window.__sybr = 1;
      var P = JSON.parse;
      JSON.parse = function () {
        var r = P.apply(this, arguments);
        try {
          if (r && typeof r === 'object' && !Array.isArray(r)) {
            if (r.data && typeof r.data === 'object' && typeof r.data.stok === 'string') {
              window.__syStok = r.data.stok;
              window.webkit.messageHandlers.sybr.postMessage({ k: 'stok', v: r.data.stok });
            } else if (r.success === false && (r.errorcode || (r.data && r.data.errorcode))) {
              window.webkit.messageHandlers.sybr.postMessage({ k: 'err', v: JSON.stringify(r).slice(0, 300) });
            }
          }
        } catch (e) {}
        return r;
      };
    })();
    """#

    init(host: String, password: String) {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !h.hasPrefix("http") { h = "http://" + h }
        while h.hasSuffix("/") { h.removeLast() }
        self.host = h
        self.password = password
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(WKUserScript(source: Self.hook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        super.init()
        config.userContentController.add(TPBridgeHandler(self), name: "sybr")
        web.navigationDelegate = self
        web.alpha = 0.01
        web.isUserInteractionEnabled = false
    }

    fileprivate func received(_ k: String, _ v: String) {
        if k == "stok" { stok = v; loginError = nil }
        if k == "err", stok == nil { loginError = v }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { pageLoaded = true }

    private func attach() {
        guard web.superview == nil else { return }
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        window?.insertSubview(web, at: 0)
    }

    private func js(_ body: String, _ args: [String: Any] = [:]) async throws -> Any? {
        try await web.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .page)
    }

    private func wait(_ seconds: Double, until done: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await done() { return true }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return false
    }

    /// Loads the router's page invisibly and logs in with its own login form.
    func login() async throws {
        ready = false
        stok = nil
        loginError = nil
        pageLoaded = false
        attach()
        guard let url = URL(string: host + "/webpages/index.html") else { throw TPError.message("That address doesn't look right.") }
        web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15))
        guard await wait(20, until: { self.pageLoaded }) else { throw TPError.message("The TP-Link's page didn't load. Are you on its network?") }
        let hasField = await wait(20) {
            ((try? await self.js("return !!document.querySelector('input[type=password]')")) as? Bool) == true
        }
        guard hasField else { throw TPError.message("The TP-Link's login page didn't show a password field.") }
        _ = try? await js(#"""
            const i = document.querySelector('input[type=password]');
            const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
            set.call(i, pw);
            i.dispatchEvent(new Event('input', { bubbles: true }));
            i.dispatchEvent(new Event('change', { bubbles: true }));
            await new Promise(r => setTimeout(r, 300));
            const buttons = [...document.querySelectorAll('button')];
            const b = buttons.find(x => /log\s*in/i.test(x.textContent || '')) || buttons.find(x => /primary/.test(x.className));
            if (b) b.click(); else i.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', keyCode: 13, bubbles: true }));
            return true;
            """#, ["pw": password])
        var nudged = false
        let ok = await wait(25) {
            if self.stok != nil || self.loginError != nil { return true }
            if !nudged, let clicked = (try? await self.js(#"""
                const m = [...document.querySelectorAll('.su-modal button, .su-dialog button, [role=dialog] button')]
                  .find(x => /continue|log\s*in|ok/i.test(x.textContent || ''));
                if (m) { m.click(); return true } return false;
                """#)) as? Bool, clicked { nudged = true }
            return false
        }
        if let e = loginError {
            if e.contains("attemptsAllowed") || e.lowercased().contains("password") { throw TPError.message("Wrong password (the TP-Link said: \(e)).") }
            throw TPError.message("The TP-Link refused the login: \(e)")
        }
        guard ok, stok != nil else { throw TPError.message("The TP-Link's page didn't finish logging in.") }
        let encReady = await wait(10) {
            ((try? await self.js("return typeof window.encrypt === 'function' && typeof window.decrypt === 'function'")) as? Bool) == true
        }
        guard encReady else { throw TPError.message("The TP-Link's page logged in but its encryptor isn't available.") }
        ready = true
    }

    /// One request made by the router's own page code. Returns the "data" of a successful answer.
    func call(_ path: String, _ data: String) async throws -> Any {
        if !ready { try await login() }
        let raw = try await js(#"""
            const e = window.encrypt(data);
            if (!e || !e.sign) return JSON.stringify({ status: -1, body: 'no encryptor' });
            const r = await fetch('/cgi-bin/luci/;stok=' + stok + '/' + path, {
              method: 'POST',
              headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
              body: 'sign=' + e.sign + '&data=' + encodeURIComponent(e.data),
              credentials: 'include'
            });
            const txt = await r.text();
            let out = txt;
            try { const j = JSON.parse(txt); out = (j && typeof j.data === 'string') ? window.decrypt(j.data) : txt; }
            catch (x) { try { out = window.decrypt(txt) || txt } catch (y) {} }
            return JSON.stringify({ status: r.status, body: out });
            """#, ["data": data, "path": path, "stok": stok ?? ""])
        guard let s = raw as? String, let outer = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else {
            throw TPError.message("The TP-Link's page gave no answer for \(path).")
        }
        let status = outer["status"] as? Int ?? 0
        let body = outer["body"] as? String ?? ""
        guard let o = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            if status == 401 || status == 403 || body.contains("timeout") { ready = false }
            throw TPError.message("The TP-Link answered \(path) with HTTP \(status): \(body.prefix(160))")
        }
        if (o["success"] as? Bool) == true { return o["data"] ?? [String: Any]() }
        let code = "\(o["errorcode"] ?? "unknown")"
        if code.contains("timeout") { ready = false }
        throw TPError.message("The TP-Link said no (\(code)) for \(path).")
    }
}

private final class TPBridgeHandler: NSObject, WKScriptMessageHandler {
    weak var bridge: TPWebBridge?
    init(_ b: TPWebBridge) { bridge = b }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let b = m.body as? [String: Any], let k = b["k"] as? String, let v = b["v"] as? String else { return }
        Task { @MainActor in self.bridge?.received(k, v) }
    }
}
