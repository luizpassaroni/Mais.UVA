import SwiftUI
import WebKit
import Combine
import LocalAuthentication
import UIKit

private let hiddenBackURLs: [String] = [
    "portalaluno.uva.br/LoginMobile",
    "portalaluno.uva.br/Aluno/PortalAluno"
]

class WebViewModel: NSObject, ObservableObject {
    // MARK: - Estado publicado
    @Published var isLoading: Bool = true
    @Published var showError: Bool = false
    @Published var isNoInternetError: Bool = false
    @Published var pageTitle: String = ""
    @Published var canGoBack: Bool = false
    @Published var showBackButton: Bool = false
    @Published var showReloadButton: Bool = false // Novo estado para o botão de reload
    @Published var isPDFPage: Bool = false

    @Published var showSavePasswordPrompt: Bool = false
    @Published var showSettingsSheet: Bool = false
    @Published var hasCredentials: Bool = false

    var capturedUsername: String = ""
    private(set) var capturedPassword: String = ""

    let webView: WKWebView
    let portalURL = URL(string: "https://portalaluno.uva.br/LoginMobile")!

    override init() {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        let controller = webView.configuration.userContentController
        controller.add(self, name: "openSettings")
        controller.add(self, name: "credentialsCapture")

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false

        webView.scrollView.minimumZoomScale = 1.0
        webView.scrollView.maximumZoomScale = 1.0
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.delegate = self

        webView.addObserver(self, forKeyPath: "canGoBack", options: [.new], context: nil)
        webView.addObserver(self, forKeyPath: "title", options: [.new], context: nil)
        webView.addObserver(self, forKeyPath: "URL", options: [.new], context: nil)

        hasCredentials = KeychainManager.shared.hasCredentials()
        loadPortal()
    }

    deinit {
        webView.removeObserver(self, forKeyPath: "canGoBack")
        webView.removeObserver(self, forKeyPath: "title")
        webView.removeObserver(self, forKeyPath: "URL")
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "openSettings")
        controller.removeScriptMessageHandler(forName: "credentialsCapture")
    }

    func loadPortal() {
        let request = URLRequest(url: portalURL, cachePolicy: .useProtocolCachePolicy)
        webView.load(request)
    }

    func goBack() { webView.goBack() }
    
    func reload() {
        showError = false
        isNoInternetError = false
        isLoading = true
        if webView.url == nil || webView.url?.absoluteString == "about:blank" {
            loadPortal()
        } else {
            webView.reload()
        }
    }

    // MARK: - Biometria / Autofill
    func autofillWithBiometrics() {
        Task {
            do {
                let credentials = try await KeychainManager.shared.loadCredentials()
                await MainActor.run {
                    self.fillLoginForm(username: credentials.username, password: credentials.password)
                }
            } catch {
                print("Biometria falhou: \(error.localizedDescription)")
            }
        }
    }

    private func fillLoginForm(username: String, password: String) {
        let js = """
        (function() {
            var userField = document.getElementById('LoginEntrada_login');
            var passField = document.getElementById('LoginEntrada_senha');
            if (userField && passField) {
                userField.value = \(jsString(username));
                passField.value = \(jsString(password));
                [userField, passField].forEach(el => {
                    el.dispatchEvent(new Event('input', { bubbles: true }));
                    el.dispatchEvent(new Event('change', { bubbles: true }));
                });
                setTimeout(() => { document.getElementById('btn_logar')?.click(); }, 150);
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func savePassword() {
        guard !capturedUsername.isEmpty, !capturedPassword.isEmpty else { return }
        try? KeychainManager.shared.saveCredentials(username: capturedUsername, password: capturedPassword)
        hasCredentials = true
        injectScript(in: self.webView)
        showSavePasswordPrompt = false
    }

    // MARK: - KVO & UI Helpers
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard let wv = object as? WKWebView else { return }
        DispatchQueue.main.async {
            if keyPath == "canGoBack" { self.canGoBack = wv.canGoBack }
            if keyPath == "title" { self.pageTitle = wv.title ?? "" }
            self.updateUIStates(url: wv.url)
        }
    }

    private func updateUIStates(url: URL?) {
        guard let urlString = url?.absoluteString else {
            showBackButton = false
            showReloadButton = false
            return
        }
        
        let isHiddenPage = hiddenBackURLs.contains(where: { urlString.contains($0) })
        
        // Botão de voltar: apenas se puder voltar e não for página "home"
        showBackButton = canGoBack && !isHiddenPage
        
        // Botão de recarregar: aparece em qualquer lugar exceto talvez na tela de login pura
        // Ou conforme sua preferência, aqui coloco para aparecer sempre que o Back aparecer
        showReloadButton = !isHiddenPage
    }

    private func renderSFSymbol(named name: String, size: CGFloat, color: UIColor) -> String {
        let config = UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
        guard let image = UIImage(systemName: name, withConfiguration: config)?.withTintColor(color, renderingMode: .alwaysOriginal),
              let pngData = image.pngData() else { return "" }
        return pngData.base64EncodedString()
    }

    // MARK: - JavaScript Injection
    private func injectScript(in webView: WKWebView) {
        guard let urlString = webView.url?.absoluteString else { return }
        if urlString.lowercased().hasSuffix(".pdf") { return }

        let isLogin = urlString.contains("LoginMobile")
        let isPortalHome = urlString.contains("Aluno/PortalAluno")
        let isPortal = urlString.contains("portalaluno.uva.br")

        var script = "(function() {"
        
        if isPortal { script += "\ndocument.body.style.backgroundColor = '#004B78';" }

        // Customização da tela de Login
        if isLogin {
            script += """
            var buttons = document.querySelectorAll('button.btn-style, button.button-type-mobile');
            buttons.forEach(btn => { btn.style.backgroundColor = '#FFD000'; btn.style.color = '#004B78'; });
            document.querySelectorAll('a, .text-white, label').forEach(el => el.style.color = 'white');
            
            var btnLogar = document.getElementById('btn_logar');
            if (btnLogar && !btnLogar.dataset.hooked) {
                btnLogar.dataset.hooked = 'true';
                btnLogar.addEventListener('click', () => {
                    var u = document.getElementById('LoginEntrada_login')?.value;
                    var p = document.getElementById('LoginEntrada_senha')?.value;
                    if (u && p) window.webkit.messageHandlers.credentialsCapture.postMessage(JSON.stringify({username:u, password:p}));
                }, true);
            }
            """

            if hasCredentials {
                let context = LAContext()
                var error: NSError?
                let canBio = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
                let bioType = context.biometryType
                
                let sfName = bioType == .faceID ? "faceid" : (bioType == .touchID ? "touchid" : "lock.fill")
                let label = bioType == .faceID ? "Entrar com Face ID" : "Entrar com Biometria"
                let icon64 = renderSFSymbol(named: sfName, size: 60, color: .white)

                script += """
                if (!document.getElementById('mais-uva-bio-block')) {
                    document.querySelectorAll('.form-group, .input-group, input, #btn_logar, label[for]').forEach(el => el.style.display = 'none');
                    var block = document.createElement('div');
                    block.id = 'mais-uva-bio-block';
                    block.style.cssText = 'display:flex;flex-direction:column;align-items:center;gap:20px;padding:40px 20px;';
                    block.innerHTML = `
                        <img src="data:image/png;base64,\(icon64)" style="width:64px;height:64px;">
                        <button onclick="window.webkit.messageHandlers.openSettings.postMessage('biometry')" style="background:#FFD000;color:#004B78;border:none;border-radius:10px;padding:15px 0;font-size:16px;font-weight:bold;width:90%;">\(label)</button>
                        <a href="#" onclick="location.reload()" style="color:white;text-size:12px;margin-top:10px;text-decoration:underline;">Usar outra conta</a>
                    `;
                    (document.querySelector('.card-body') || document.body).appendChild(block);
                }
                """
            }
        }

        // Ícone de Configurações na Home (Corrigido usando SFSymbol)
        if isPortalHome {
            let gear64 = renderSFSymbol(named: "gearshape.fill", size: 24, color: .white)
            script += """
            var cardClass = document.querySelector('.card-class');
            if (cardClass && !document.getElementById('mais-uva-settings-btn')) {
                var gear = document.createElement('div');
                gear.id = 'mais-uva-settings-btn';
                gear.style.cssText = 'display:inline-flex;align-items:center;justify-content:center;margin-left:12px;vertical-align:middle;cursor:pointer;padding:4px;';
                gear.innerHTML = '<img src="data:image/png;base64,\(gear64)" style="width:24px;height:24px;">';
                gear.onclick = () => window.webkit.messageHandlers.openSettings.postMessage('open');
                cardClass.appendChild(gear);
            }
            """
        }

        script += "\n})();"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func jsString(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}

// MARK: - Handlers & Navigation
extension WebViewModel: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        DispatchQueue.main.async {
            if message.name == "openSettings" {
                if message.body as? String == "biometry" { self.autofillWithBiometrics() }
                else { self.showSettingsSheet = true }
            } else if message.name == "credentialsCapture" {
                guard let body = message.body as? String, let data = body.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
                self.capturedUsername = json["username"] ?? ""
                self.capturedPassword = json["password"] ?? ""
            }
        }
    }
}

extension WebViewModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation n: WKNavigation!) {
        DispatchQueue.main.async { self.isLoading = true; self.showError = false; self.isNoInternetError = false }
    }

    func webView(_ webView: WKWebView, didFinish n: WKNavigation!) {
        DispatchQueue.main.async {
            self.isLoading = false
            self.updateUIStates(url: webView.url)
            if webView.url?.absoluteString.contains("Aluno/PortalAluno") == true, !self.capturedUsername.isEmpty, !KeychainManager.shared.hasCredentials() {
                self.showSavePasswordPrompt = true
            }
        }
        injectScript(in: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        if (e as NSError).code == NSURLErrorCancelled { return }
        DispatchQueue.main.async { self.isLoading = false; self.isNoInternetError = true; self.showError = true }
    }
}

extension WebViewModel: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

extension WebViewModel: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        let isPDF = webView.url?.absoluteString.lowercased().hasSuffix(".pdf") ?? false
        return isPDF ? scrollView.subviews.first : nil
    }
}
