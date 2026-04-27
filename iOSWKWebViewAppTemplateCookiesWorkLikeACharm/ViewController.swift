//
//  ViewController.swift
//  Zappy
//

import UIKit
import WebKit

class ViewController: UIViewController {
    
    private let webView = WKWebView(frame: .zero)
    private let webURL = URL(string: "https://zappy-family.com")!
    private let statusBarColor = UIColor(red: 0.655, green: 0.545, blue: 0.980, alpha: 1) // #A78BFA
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let statusBarHeight: CGFloat = UIApplication.shared.statusBarFrame.size.height
        
        let statusbarView = UIView()
        statusbarView.backgroundColor = statusBarColor
        view.addSubview(statusbarView)
        
        statusbarView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusbarView.heightAnchor.constraint(equalToConstant: statusBarHeight),
            statusbarView.widthAnchor.constraint(equalTo: view.widthAnchor),
            statusbarView.topAnchor.constraint(equalTo: view.topAnchor),
            statusbarView.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
        
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leftAnchor.constraint(equalTo: view.leftAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.rightAnchor.constraint(equalTo: view.rightAnchor),
            webView.topAnchor.constraint(equalTo: statusbarView.bottomAnchor) // WebView commence SOUS la status bar
        ])
        
        webView.uiDelegate = self
        webView.navigationDelegate = self
        
        // Désactive le pinch-to-zoom
        let source = "var meta = document.createElement('meta');" +
            "meta.name = 'viewport';" +
            "meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';" +
            "var head = document.getElementsByTagName('head')[0];" +
            "head.appendChild(meta);"
        let script = WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        webView.configuration.userContentController.addUserScript(script)
        
        webView.load(URLRequest(url: webURL))
        
        view.bringSubviewToFront(statusbarView)
    }
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
}

// MARK: - Cookie persistence

extension WKWebView {
    
    enum PrefKey {
        static let cookie = "cookies"
    }
    
    func writeDiskCookies(for domain: String, completion: @escaping () -> ()) {
        fetchInMemoryCookies(for: domain) { data in
            UserDefaults.standard.setValue(data, forKey: PrefKey.cookie + domain)
            completion()
        }
    }
    
    func loadDiskCookies(for domain: String, completion: @escaping () -> ()) {
        if let diskCookie = UserDefaults.standard.dictionary(forKey: PrefKey.cookie + domain) {
            fetchInMemoryCookies(for: domain) { freshCookie in
                let mergedCookie = diskCookie.merging(freshCookie) { (_, new) in new }
                for (_, cookieConfig) in mergedCookie {
                    guard let cookie = cookieConfig as? [String: Any] else { continue }
                    var expire: Any? = nil
                    if let expireTime = cookie["Expires"] as? Double {
                        expire = Date(timeIntervalSinceNow: expireTime)
                    }
                    if let newCookie = HTTPCookie(properties: [
                        .domain: cookie["Domain"] as Any,
                        .path: cookie["Path"] as Any,
                        .name: cookie["Name"] as Any,
                        .value: cookie["Value"] as Any,
                        .secure: cookie["Secure"] as Any,
                        .expires: expire as Any
                    ]) {
                        self.configuration.websiteDataStore.httpCookieStore.setCookie(newCookie)
                    }
                }
                completion()
            }
        } else {
            completion()
        }
    }
    
    func fetchInMemoryCookies(for domain: String, completion: @escaping ([String: Any]) -> ()) {
        var cookieDict = [String: AnyObject]()
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            for cookie in cookies where cookie.domain.contains(domain) {
                cookieDict[cookie.name] = cookie.properties as AnyObject?
            }
            completion(cookieDict)
        }
    }
}

// MARK: - WebView delegates

extension ViewController: WKUIDelegate, WKNavigationDelegate {
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let host = webURL.host else {
            decisionHandler(.cancel)
            return
        }
        webView.loadDiskCookies(for: host) {
            decisionHandler(.allow)
        }
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // Recharge la page si le réseau est indispo au démarrage
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.webView.load(URLRequest(url: self.webURL))
        }
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let host = webURL.host else {
            decisionHandler(.cancel)
            return
        }
        webView.writeDiskCookies(for: host) {
            decisionHandler(.allow)
        }
    }
}
