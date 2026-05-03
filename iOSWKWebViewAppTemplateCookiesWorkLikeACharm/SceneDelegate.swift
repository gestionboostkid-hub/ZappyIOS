//
//  SceneDelegate.swift
//  iOSWKWebViewAppTemplateCookiesWorkLikeACharm
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let _ = (scene as? UIWindowScene) else { return }

        // Gère les deep links arrivés au démarrage cold
        if let url = connectionOptions.urlContexts.first?.url {
            handleDeepLink(url)
        }
    }

    // FEATURE: deep links — ouverture depuis notifications, Safari, autres apps
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        handleDeepLink(url)
    }

    private func handleDeepLink(_ url: URL) {
        NotificationCenter.default.post(name: .zappyDeepLink, object: url)
    }

    func sceneDidDisconnect(_ scene: UIScene) {}
    func sceneDidBecomeActive(_ scene: UIScene) {}
    func sceneWillResignActive(_ scene: UIScene) {}
    func sceneWillEnterForeground(_ scene: UIScene) {}
    func sceneDidEnterBackground(_ scene: UIScene) {}
}
