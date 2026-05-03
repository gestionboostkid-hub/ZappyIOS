//
//  ViewController.swift
//  Zappy
//

import UIKit
import WebKit
import Security
import os.log

class ViewController: UIViewController {

    private var webView: WKWebView!
    private let spinner = UIActivityIndicatorView(style: .large)
    private let progressBar = UIProgressView(progressViewStyle: .bar)
    private let statusBarColor = UIColor(red: 0.655, green: 0.545, blue: 0.980, alpha: 1)
    private var progressObservation: NSKeyValueObservation?

    // FIX: fallback gracieux au lieu de fatalError
    private lazy var webURL: URL = {
        if let urlString = Bundle.main.infoDictionary?["AppURL"] as? String,
           let url = URL(string: urlString) {
            return url
        }
        return URL(string: "https://zappy-family.com")!
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = statusBarColor
        setupWebView()
        setupProgressBar()
        setupSpinner()
        setupRefreshControl()
        loadInitialPage()

        // Deep link : rechargement si l'app est ouverte depuis l'extérieur
        NotificationCenter.default.addObserver(self, selector: #selector(handleDeepLink(_:)),
                                               name: .zappyDeepLink, object: nil)
    }

    // MARK: - Setup

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        // FIX: injection de script filtrée au domaine cible uniquement
        let targetHost = webURL.host ?? ""
        let source = """
        (function() {
            var h = window.location.hostname;
            if (h === '\(targetHost)' || h.endsWith('.\(targetHost)')) {
                if (!document.querySelector('meta[name=viewport]')) {
                    var m = document.createElement('meta');
                    m.name = 'viewport';
                    m.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
                    document.getElementsByTagName('head')[0].appendChild(m);
                }
            }
        })();
        """
        let script = WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(script)

        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        // FEATURE: swipe arrière/avant natif
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.bounces = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.leftAnchor.constraint(equalTo: view.leftAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.rightAnchor.constraint(equalTo: view.rightAnchor),
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        ])

        // FEATURE: barre de progression liée à estimatedProgress
        progressObservation = webView.observe(\.estimatedProgress, options: .new) { [weak self] _, change in
            guard let self, let progress = change.newValue else { return }
            DispatchQueue.main.async {
                self.progressBar.setProgress(Float(progress), animated: true)
                self.progressBar.isHidden = progress >= 1.0
            }
        }
    }

    private func setupProgressBar() {
        progressBar.progressTintColor = .white
        progressBar.trackTintColor = statusBarColor
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressBar)
        NSLayoutConstraint.activate([
            progressBar.leftAnchor.constraint(equalTo: view.leftAnchor),
            progressBar.rightAnchor.constraint(equalTo: view.rightAnchor),
            progressBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2)
        ])
    }

    private func setupSpinner() {
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        spinner.startAnimating()
    }

    private func setupRefreshControl() {
        // FEATURE: pull-to-refresh
        let refresh = UIRefreshControl()
        refresh.tintColor = .white
        refresh.addTarget(self, action: #selector(refreshPage), for: .valueChanged)
        webView.scrollView.refreshControl = refresh
    }

    private func loadInitialPage() {
        CookieManager.loadCookies(for: webURL.host ?? "", into: webView) {
            self.webView.load(URLRequest(url: self.webURL))
        }
    }

    // MARK: - Actions

    @objc private func refreshPage() {
        // FEATURE: haptic au refresh
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        webView.reload()
    }

    @objc private func handleDeepLink(_ notification: Notification) {
        guard let url = notification.object as? URL else { return }
        webView.load(URLRequest(url: url))
    }

    // MARK: - State helpers

    private func hideLoadingState() {
        spinner.isHidden = true
        spinner.stopAnimating()
        webView.scrollView.refreshControl?.endRefreshing()
    }

    private func showNetworkError() {
        hideLoadingState()
        // FEATURE: haptic d'erreur
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        let alert = UIAlertController(
            title: "Pas de connexion",
            message: "Vérifie ta connexion internet et réessaie.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Réessayer", style: .default) { [weak self] _ in
            guard let self else { return }
            spinner.isHidden = false
            spinner.startAnimating()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            webView.load(URLRequest(url: webURL))
        })
        present(alert, animated: true)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    deinit {
        progressObservation?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Cookie Manager (stockage Keychain)

class CookieManager {

    private static let logger = Logger(subsystem: "com.zappy", category: "CookieManager")

    private static func keychainKey(for domain: String) -> String {
        return "cookies_\(domain)"
    }

    static func saveCookies(for domain: String, from webView: WKWebView, completion: @escaping () -> Void) {
        // FIX: guard domain vide
        guard !domain.isEmpty else { completion(); return }
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
                    props["Expires"] = expiresDate.timeIntervalSince1970
                }
                cookieArray.append(props)
            }
            guard let data = try? JSONSerialization.data(withJSONObject: cookieArray) else {
                completion()
                return
            }
            let key = keychainKey(for: domain)
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: key
            ]
            SecItemDelete(deleteQuery as CFDictionary)
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: key,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            // FIX: vérification du status Keychain
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            if status != errSecSuccess {
                logger.error("SecItemAdd failed: \(status)")
            }
            completion()
        }
    }

    static func loadCookies(for domain: String, into webView: WKWebView, completion: @escaping () -> Void) {
        // FIX: guard domain vide
        guard !domain.isEmpty else { completion(); return }
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
        hideLoadingState()
        // FEATURE: haptic de succès au chargement
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard let host = webURL.host else { return }
        CookieManager.saveCookies(for: host, from: webView) {}
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // FIX: spinner.isHidden correctement géré via hideLoadingState()
        showNetworkError()
    }

    // FIX: erreurs mid-navigation également capturées
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showNetworkError()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
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

// MARK: - Notification name

extension Notification.Name {
    static let zappyDeepLink = Notification.Name("zappyDeepLink")
}
