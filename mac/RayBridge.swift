import AppKit
import Carbon
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate,
                         WKScriptMessageHandlerWithReply {
    private struct AutomationApp {
        let name: String
        let bundleIdentifier: String
    }
    private let commonAutomationApps = [
        AutomationApp(name: "Finder", bundleIdentifier: "com.apple.finder"),
        AutomationApp(name: "Safari", bundleIdentifier: "com.apple.Safari"),
        AutomationApp(name: "Mail", bundleIdentifier: "com.apple.mail"),
        AutomationApp(name: "Messages", bundleIdentifier: "com.apple.MobileSMS"),
        AutomationApp(name: "Calendar", bundleIdentifier: "com.apple.iCal"),
        AutomationApp(name: "Notes", bundleIdentifier: "com.apple.Notes"),
        AutomationApp(name: "Reminders", bundleIdentifier: "com.apple.reminders"),
        AutomationApp(name: "Contacts", bundleIdentifier: "com.apple.AddressBook"),
        AutomationApp(name: "Music", bundleIdentifier: "com.apple.Music")
    ]
    private var window: NSWindow!
    private var web: WKWebView!
    private var process: Process?
    private var logPipe: Pipe?
    private var started = false
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit RayBridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = NSMenuItem(); item.submenu = appMenu; menu.addItem(item); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 850),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "RayBridge"; window.center(); window.minSize = NSSize(width: 640, height: 600)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "raybridge")
        web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self; web.uiDelegate = self
        window.contentView = web; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        web.loadHTMLString("<html><body style='font:22px -apple-system;padding:60px;color:#245e51'><h1>RayBridge</h1><p>Starting your Mac bridge…</p></body></html>", baseURL: nil)
        guard let resources = Bundle.main.resourceURL else { return }
        let process = Process()
        process.executableURL = resources.appendingPathComponent("runtime/node")
        process.arguments = [resources.appendingPathComponent("app/bridge/server.mjs").path]
        process.currentDirectoryURL = resources.appendingPathComponent("app")
        var environment = ProcessInfo.processInfo.environment
        environment["RAYBRIDGE_CODEX"] = resources.appendingPathComponent("runtime/codex").path
        process.environment = environment
        let pipe = Pipe(); logPipe = pipe; process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if String(decoding: data, as: UTF8.self).contains("RayBridge is ready") {
                DispatchQueue.main.async {
                    guard let self, !self.started else { return }
                    self.started = true
                    self.web.load(URLRequest(url: URL(string: "http://127.0.0.1:8844")!))
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.quitting else { return }
                self.showError("The Mac bridge stopped. Another copy may already be running, or ports 8844 and 8845 may be in use. Quit other copies and reopen RayBridge.")
            }
        }
        self.process = process
        do { try process.run() } catch { showError("Could not launch the bundled runtime. Rebuild RayBridge on this Mac.") }
    }
    private func showError(_ message: String) {
        let alert = NSAlert(); alert.messageText = "RayBridge could not start"; alert.informativeText = message
        alert.runModal()
    }
    func applicationWillTerminate(_ notification: Notification) {
        quitting = true; logPipe?.fileHandleForReading.readabilityHandler = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "raybridge", contentWorld: .page)
        if process?.isRunning == true { process?.terminate() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "https" { NSWorkspace.shared.open(url); decisionHandler(.cancel) }
        else if url.scheme == "about" || (url.host == "127.0.0.1" && url.port == 8844) { decisionHandler(.allow) }
        else { decisionHandler(.cancel) }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme == "https" { NSWorkspace.shared.open(url) }
        return nil
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.securityOrigin.host == "127.0.0.1",
              let request = message.body as? [String: Any], let type = request["type"] as? String else {
            replyHandler(nil, "RayBridge rejected an untrusted app-access request.")
            return
        }
        switch type {
        case "prepareAppAccess":
            replyHandler(["results": prepareAppAccess()], nil)
        case "openAutomationSettings":
            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
                  NSWorkspace.shared.open(url) else {
                replyHandler(nil, "Could not open Automation settings.")
                return
            }
            replyHandler(["opened": true], nil)
        default:
            replyHandler(nil, "RayBridge does not support that Mac request.")
        }
    }
    private func prepareAppAccess() -> [[String: String]] {
        commonAutomationApps.map { app in
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) != nil else {
                return ["name": app.name, "status": "unavailable"]
            }
            let target = NSAppleEventDescriptor(bundleIdentifier: app.bundleIdentifier)
            let status = AEDeterminePermissionToAutomateTarget(
                target.aeDesc, typeWildCard, typeWildCard, true)
            if status == noErr { return ["name": app.name, "status": "allowed"] }
            if status == errAEEventNotPermitted { return ["name": app.name, "status": "notAllowed"] }
            return ["name": app.name, "status": "unavailable"]
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
