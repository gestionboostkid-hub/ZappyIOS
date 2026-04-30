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
        
        // Couleur de fond = couleur status bar (évite le flash blanc au démarrage)
        view.backgroundColor = statusBarColor
        
        // WebView couvre tout sauf la safe area top
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leftAnchor.constraint(equalTo: view.leftAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.rightAnchor.constraint(equalTo: view.rightAnchor),
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
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
        
        // Charge les cookies disk une seule fois avant le premier load
        CookieManager.loadDiskCookies(for: webURL.host ?? "", into: webView) {
            self.webView.load(URLRequest(url: self.webURL))
        }
    }
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
}

// MARK: - Cookie Manager (helper séparé, évite d'étendre WKWebView système)

class CookieManager {
    
    enum PrefKey {
        static let cookie = "cookies"
    }
    
    static func writeDiskCookies(for domain: String, from webView: WKWebView, completion: @escaping () -> Void) {
        fetchInMemoryCookies(for: domain) { data in
            UserDefaults.standard.setValue(data, forKey: PrefKey.cookie + domain)
            completion()
        }
    }
    
    static func loadDiskCookies(for domain: String, into webView: WKWebView, completion: @escaping () -> Void) {
        guard let diskCookie = UserDefaults.standard.dictionary(forKey: PrefKey.cookie + domain) else {
            completion()
            return
        }
        fetchInMemoryCookies(for: domain) { freshCookie in
            let mergedCookie = diskCookie.merging(freshCookie) { (_, new) in new }
            let group = DispatchGroup()
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
                    group.enter()
                    webView.configuration.websiteDataStore.httpCookieStore.setCookie(newCookie) {
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) {
                completion()
            }
        }
    }
    
    static func fetchInMemoryCookies(for domain: String, completion: @escaping ([String: Any]) -> Void) {
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
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let alert = UIAlertController(
            title: "Pas de connexion",
            message: "Vérifie ta connexion internet et réessaie.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Réessayer", style: .default) { _ in
            self.webView.load(URLRequest(url: self.webURL))
        })
        present(alert, animated: true)
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let host = webURL.host else {
            decisionHandler(.cancel)
            return
        }
        CookieManager.writeDiskCookies(for: host, from: webView) {
            decisionHandler(.allow)
        }
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }
}
