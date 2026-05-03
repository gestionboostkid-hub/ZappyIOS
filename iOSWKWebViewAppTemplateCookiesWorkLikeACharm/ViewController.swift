//
//  ViewController.swift
//  Zappy
//

import UIKit
import WebKit
import Security
import os.log

// Stocke l'URL d'un deep link arrivé avant que ViewController soit prêt (cold start)
enum DeepLinkRouter {
    private static var _pending: URL?
    static func store(_ url: URL) { _pending = url }
    static func consumePending() -> URL? { defer { _pending = nil }; return _pending }
}

class ViewController: UIViewController {

    private var webView: WKWebView!
    private let spinner = UIActivityIndicatorView(style: .large)
    private let progressBar = UIProgressView(progressViewStyle: .bar)
    private let statusBarColor = UIColor(red: 0.655, green: 0.545, blue: 0.980, alpha: 1)
    private var progressObservation: NSKeyValueObservation?

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

        NotificationCenter.default.addObserver(self, selector: #selector(handleDeepLink(_:)),
                                               name: .zappyDeepLink, object: nil)
        loadInitialPage()
    }

    // MARK: - Setup

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

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
        let refresh = UIRefreshControl()
        refresh.tintColor = .white
        refresh.addTarget(self, action: #selector(refreshPage), for: .valueChanged)
        webView.scrollView.refreshControl = refresh
    }

    private func loadInitialPage() {
        CookieManager.loadCookies(for: webURL.host ?? "", into: webView) { [weak self] in
            guard let self else { return }
            // Si un deep link est arrivé avant qu'on soit prêt (cold start), on le prioritise
            let target = DeepLinkRouter.consumePending() ?? webURL
            webView.load(URLRequest(url: target))
        }
    }

    // MARK: - Actions

    @objc private func refreshPage() {
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

// MARK: - Cookie Manager

enum CookieManager {

    private static let logger = Logger(subsystem: "com.zappy", category: "CookieManager")

    private enum Key {
        static let name = "Name"
        static let value = "Value"
        static let domain = "Domain"
        static let path = "Path"
        static let secure = "Secure"
        static let expires = "Expires"
    }

    private static func keychainKey(for domain: String) -> String {
        "cookies_\(domain)"
    }

    static func saveCookies(for domain: String, from webView: WKWebView, completion: @escaping () -> Void) {
        guard !domain.isEmpty else { completion(); return }
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let domainCookies = cookies.filter {
                $0.domain == domain || $0.domain.hasSuffix(".\(domain)")
            }
            var cookieArray: [[String: Any]] = []
            for cookie in domainCookies {
                var props: [String: Any] = [
                    Key.name: cookie.name,
                    Key.value: cookie.value,
                    Key.domain: cookie.domain,
                    Key.path: cookie.path,
                    Key.secure: cookie.isSecure
                ]
                if let expiresDate = cookie.expiresDate {
                    props[Key.expires] = expiresDate.timeIntervalSince1970
                }
                cookieArray.append(props)
            }
            guard let data = try? JSONSerialization.data(withJSONObject: cookieArray) else {
                completion(); return
            }
            DispatchQueue.global(qos: .utility).async {
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
                let status = SecItemAdd(addQuery as CFDictionary, nil)
                if status != errSecSuccess {
                    logger.error("SecItemAdd failed: \(status)")
                }
                DispatchQueue.main.async { completion() }
            }
        }
    }

    static func loadCookies(for domain: String, into webView: WKWebView, completion: @escaping () -> Void) {
        guard !domain.isEmpty else { completion(); return }
        let key = keychainKey(for: domain)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]
        DispatchQueue.global(qos: .userInitiated).async {
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess,
                  let data = result as? Data,
                  let cookieArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                DispatchQueue.main.async { completion() }
                return
            }
            let now = Date()
            let group = DispatchGroup()
            for props in cookieArray {
                if let expireTimestamp = props[Key.expires] as? Double,
                   Date(timeIntervalSince1970: expireTimestamp) < now {
                    continue
                }
                var cookieProps: [HTTPCookiePropertyKey: Any] = [
                    .name: props[Key.name] as Any,
                    .value: props[Key.value] as Any,
                    .domain: props[Key.domain] as Any,
                    .path: props[Key.path] as Any,
                    .secure: props[Key.secure] as Any
                ]
                if let expireTimestamp = props[Key.expires] as? Double {
                    cookieProps[.expires] = Date(timeIntervalSince1970: expireTimestamp)
                }
                if let cookie = HTTPCookie(properties: cookieProps) {
                    group.enter()
                    DispatchQueue.main.async {
                        webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                            group.leave()
                        }
                    }
                }
            }
            group.notify(queue: .main) { completion() }
        }
    }
}

// MARK: - WebView delegates

extension ViewController: WKUIDelegate, WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideLoadingState()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard let host = webURL.host else { return }
        CookieManager.saveCookies(for: host, from: webView) {}
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showNetworkError()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showNetworkError()
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
