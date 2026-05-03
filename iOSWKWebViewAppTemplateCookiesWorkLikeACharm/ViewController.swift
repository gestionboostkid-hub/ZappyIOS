//
//  ViewController.swift
//  Zappy
//

import UIKit
import WebKit
import Security

class ViewController: UIViewController {

    private let webView = WKWebView(frame: .zero)
    private let spinner = UIActivityIndicatorView(style: .large)
    private let statusBarColor = UIColor(red: 0.655, green: 0.545, blue: 0.980, alpha: 1) // #A78BFA

    private let webURL: URL = {
        guard let urlString = Bundle.main.infoDictionary?["AppURL"] as? String,
              let url = URL(string: urlString) else {
            fatalError("AppURL manquante ou invalide dans Info.plist")
        }
        return url
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = statusBarColor

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

        let source = "var meta = document.createElement('meta');" +
            "meta.name = 'viewport';" +
            "meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';" +
            "var head = document.getElementsByTagName('head')[0];" +
            "head.appendChild(meta);"
        let script = WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        webView.configuration.userContentController.addUserScript(script)

        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        spinner.startAnimating()

        CookieManager.loadCookies(for: webURL.host ?? "", into: webView) {
            self.webView.load(URLRequest(url: self.webURL))
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
}

// MARK: - Cookie Manager (stockage Keychain)

class CookieManager {

    private static func keychainKey(for domain: String) -> String {
        return "cookies_\(domain)"
    }

    static func saveCookies(for domain: String, from webView: WKWebView, completion: @escaping () -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let domainCookies = cookies.filter { $0.domain.contains(domain) }
            var cookieArray: [[String: Any]] = []
            for cookie in domainCookies {
                var props: [String: Any] = [
                    "Name": cookie.name,
                    "Value": cookie.value,
                    "Domain": cookie.domain,
                    "Path": cookie.path,
                    "Secure": cookie.isSecure
                ]
                if let expiresDate = cookie.expiresDate {
                    // Stocke une date absolue pour éviter la dérive à la relecture
                    props["Expires"] = expiresDate.timeIntervalSince1970
                }
                cookieArray.append(props)
            }
            guard let data = try? JSONSerialization.data(withJSONObject: cookieArray) else {
                completion()
                return
            }
            let key = keychainKey(for: domain)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: key
            ]
            SecItemDelete(query as CFDictionary)
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: key,
                kSecValueData as String: data,
                // Non exportable hors device, accessible seulement écran déverrouillé
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            SecItemAdd(addQuery as CFDictionary, nil)
            completion()
        }
    }

    static func loadCookies(for domain: String, into webView: WKWebView, completion: @escaping () -> Void) {
        let key = keychainKey(for: domain)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let cookieArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            completion()
            return
        }
        let group = DispatchGroup()
        for props in cookieArray {
            var cookieProps: [HTTPCookiePropertyKey: Any] = [
                .name: props["Name"] as Any,
                .value: props["Value"] as Any,
                .domain: props["Domain"] as Any,
                .path: props["Path"] as Any,
                .secure: props["Secure"] as Any
            ]
            if let expireTimestamp = props["Expires"] as? Double {
                // Restitue la date absolue stockée
                cookieProps[.expires] = Date(timeIntervalSince1970: expireTimestamp)
            }
            if let cookie = HTTPCookie(properties: cookieProps) {
                group.enter()
                webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            completion()
        }
    }
}

// MARK: - WebView delegates

extension ViewController: WKUIDelegate, WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        spinner.isHidden = true
        spinner.stopAnimating()
        // Sauvegarde unique en fin de chargement, pas à chaque réponse HTTP
        guard let host = webURL.host else { return }
        CookieManager.saveCookies(for: host, from: webView) {}
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        spinner.stopAnimating()
        let alert = UIAlertController(
            title: "Pas de connexion",
            message: "Vérifie ta connexion internet et réessaie.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Réessayer", style: .default) { _ in
            self.spinner.isHidden = false
            self.spinner.startAnimating()
            self.webView.load(URLRequest(url: self.webURL))
        })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url,
           let host = url.host,
           let appHost = webURL.host,
           host != appHost && !host.hasSuffix(".\(appHost)") {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
