import SwiftUI
import WebKit
import Combine
import LocalAuthentication
import UIKit

// URLs onde o botão de voltar NÃO deve aparecer
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
    @Published var isPDFPage: Bool = false

    // MARK: - Estado de credenciais
    @Published var showSavePasswordPrompt: Bool = false
    @Published var showSettingsSheet: Bool = false
    @Published var hasCredentials: Bool = false

    // Credenciais temporárias capturadas do formulário
    var capturedUsername: String = ""
    private(set) var capturedPassword: String = ""

    // MARK: - WebView compartilhada
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
            function triggerEvents(el) {
                el.dispatchEvent(new Event('focus', { bubbles: true }));
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
                el.dispatchEvent(new Event('blur', { bubbles: true }));
            }
            var userField = document.getElementById('LoginEntrada_login');
            var passField = document.getElementById('LoginEntrada_senha');
            if (userField && passField) {
                userField.value = \(jsString(username));
                triggerEvents(userField);
                passField.value = \(jsString(password));
                triggerEvents(passField);
                setTimeout(function() {
                    var btn = document.getElementById('btn_logar');
                    if (btn) { btn.click(); }
                }, 100);
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func savePassword() {
        guard !capturedUsername.isEmpty, !capturedPassword.isEmpty else { return }
        do {
            try KeychainManager.shared.saveCredentials(username: capturedUsername, password: capturedPassword)
            hasCredentials = true
            injectScript(in: self.webView)
        } catch {
            print("Erro ao salvar no Keychain: \(error.localizedDescription)")
        }
        capturedUsername = ""
        capturedPassword = ""
        showSavePasswordPrompt = false
    }

    func discardSavePassword() {
        capturedUsername = ""
        capturedPassword = ""
        showSavePasswordPrompt = false
    }

    func deleteCredentials() {
        KeychainManager.shared.deleteCredentials()
        hasCredentials = false
        injectScript(in: self.webView)
    }

    // MARK: - KVO
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard let wv = object as? WKWebView else { return }
        switch keyPath {
        case "canGoBack":
            DispatchQueue.main.async {
                self.canGoBack = wv.canGoBack
                self.updateBackButtonVisibility(url: wv.url)
            }
        case "title":
            DispatchQueue.main.async { self.pageTitle = wv.title ?? "" }
        case "URL":
            DispatchQueue.main.async { self.updateBackButtonVisibility(url: wv.url) }
        default: break
        }
    }

    private func updateBackButtonVisibility(url: URL?) {
        guard let urlString = url?.absoluteString else { showBackButton = false; return }
        let isHiddenPage = hiddenBackURLs.contains(where: { urlString.contains($0) })
        showBackButton = canGoBack && !isHiddenPage
    }

    private func availableBiometryType() -> LABiometryType {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) ? context.biometryType : .none
    }

    private func renderSFSymbol(named name: String, size: CGFloat, color: UIColor) -> String {
        let config = UIImage.SymbolConfiguration(pointSize: size, weight: .thin)
        guard let image = UIImage(systemName: name, withConfiguration: config)?.withTintColor(color, renderingMode: .alwaysOriginal),
              let pngData = image.pngData() else { return "" }
        return pngData.base64EncodedString()
    }

    // MARK: - JavaScript Injection
    private func injectScript(in webView: WKWebView) {
        guard let urlString = webView.url?.absoluteString else { return }
        if urlString.lowercased().hasSuffix(".pdf") { return }

        let isLogin        = urlString.contains("LoginMobile")
        let isEsqueciSenha = urlString.contains("EsqueciSenha")
        let isPortalHome   = urlString.contains("Aluno/PortalAluno")
        let isPortal       = urlString.contains("portalaluno.uva.br")

        var script = "(function() {"
        
        if isPortal { script += "\ndocument.body.style.backgroundColor = '#004B78';" }

        if isLogin || isEsqueciSenha {
            script += """
            var buttons = document.querySelectorAll('button.btn-style, button.button-type-mobile');
            buttons.forEach(function(btn) { btn.style.backgroundColor = '#FFD000'; btn.style.color = '#004B78'; });
            var links = document.querySelectorAll('a, .text-white, label');
            links.forEach(function(el) { el.style.color = 'white'; });
            var header = document.querySelector('.header') || document.querySelector('.navbar-header');
            if (header) {
                header.style.background = '#004B78';
                header.style.display = 'flex';
                header.style.justifyContent = 'center';
                header.style.padding = '20px 0';
                header.innerHTML = '<img src="https://i.imgur.com/SzxKhmN.jpeg" style="max-width: 180px; height: auto;">';
            }
            """
        }

        if isLogin {
            script += """
            (function() {
                var btn = document.getElementById('btn_logar');
                if (btn && !btn.dataset.maisUvaHooked) {
                    btn.dataset.maisUvaHooked = 'true';
                    btn.addEventListener('click', function() {
                        var userField = document.getElementById('LoginEntrada_login');
                        var passField = document.getElementById('LoginEntrada_senha');
                        if (userField && passField && userField.value && passField.value) {
                            window.webkit.messageHandlers.credentialsCapture.postMessage(
                                JSON.stringify({ username: userField.value, password: passField.value })
                            );
                        }
                    }, true);
                }
            })();
            """

            if hasCredentials {
                let biometryType = availableBiometryType()
                let sfName = biometryType == .faceID ? "faceid" : (biometryType == .touchID ? "touchid" : "lock.fill")
                let label = biometryType == .faceID ? "Entrar com Face ID" : (biometryType == .touchID ? "Entrar com Touch ID" : "Entrar com biometria")
                let icon64 = renderSFSymbol(named: sfName, size: 80, color: .white)

                script += """
                (function() {
                    if (document.getElementById('mais-uva-bio-block')) return;
                    var forgotLink = document.querySelector('a[href*="EsqueciSenha"]');
                    document.querySelectorAll('.form-group, .input-group, input, #btn_logar, label[for]').forEach(el => el.style.display = 'none');
                    var block = document.createElement('div');
                    block.id = 'mais-uva-bio-block';
                    block.style.cssText = 'display:flex;flex-direction:column;align-items:center;gap:20px;padding:40px 24px;width:100%;';
                    block.innerHTML = `
                        <img src="data:image/png;base64,\(icon64)" style="width:72px;height:72px;opacity:0.9;">
                        <button onclick="window.webkit.messageHandlers.openSettings.postMessage('biometry')" style="background:#FFD000;color:#004B78;border:none;border-radius:10px;padding:14px 0;font-size:16px;font-weight:bold;width:85%;">\(label)</button>
                    `;
                    if (forgotLink) {
                        forgotLink.style.cssText = 'color:white;text-decoration:underline;font-size:14px;margin-top:10px;display:block;';
                        block.appendChild(forgotLink);
                    }
                    (document.querySelector('.card-body') || document.querySelector('form') || document.body).appendChild(block);
                })();
                """
            }
        }

        if isPortalHome {
            // STRING BASE64 CORRIGIDA ABAIXO
            let gearBase64 = "PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0id2hpdGUiPjxwYXRoIGZpbGwtcnVsZT0iZXZlbm9kZCIgZD0iTTExLjA3OCAyLjI1Yy0uOTE3IDAtMS42OTkuNjYzLTEuODUgMS41NjdMOS4wNSA0Ljg4OWMtLjAyLjEyLS4xMTUuMjYtLjI5Ny4zNDhhNy40OTMgNy40OTMgMCAwIDAtLjk4Ni41N2MtLjE2Ni4xMTUtLjMzNC4xMjYtLjQ1LjA4M0w2LjMgNS41MDhhMS44NzUgMS44NzUgMCAwIDAtMi4yODIuODE5bC0uOTIyIDEuNTk3YTEuODc1IDEuODc1IDAgMCAwIC40MzIgMi4zODVsLjg0LjY5MmMuMDk1LjA3OC4xNy4yMjkuMTU0LjQzYTcuNTk4IDcuNTk4IDAgMCAwIDAtMS4xMzljLjAxNS4yLS4wNTkuMzUyLS4xNTMuNDNsLS44NDEuNjkyYTEuODc1IDEuODc1IDAgMCAwLS40MzIgMi4zODVsLjkyMiAxLjU5N2ExLjg3NSAxLjg3NSAwIDAgMCAyLjI4Mi44MThsMS4wMTktLjM4MmMuMTE1LS4wNDMuMjgzLS4wMzEuNDUuMDgyLjMxMi4yMTQuNjQxLjQwNS45ODUuNTcuMTgyLjA4OC4yNzcuMjI4LjI5Ny4zNWwuMTc4IDEuMDcxYy4xNTEuOTA0LjkzMyAxLjU2NyAxLjg1IDEuNTY3aDEuODQ0Yy45MTYgMCAxLjY5OS0uNjYzIDEuODUtMS41NjdsLjE3OC0xLjA3MmMuMDItLjEyLjExNC0uMjYuMjk3LS4zNDkuMzQ0LS4xNjUuNjczLS4zNTYuOTg1LS41Ny4xNjctLjExNC4zMzUtLjEyNS40NS0uMDgybDEuMDIuMzgyYTEuODc1IDEuODc1IDAgMCAwIDIuMjgtLjgxOWwuOTIzLTEuNTk3YTEuODc1IDEuODc1IDAgMCAwLS40MzItMi4zODVsLS44NC0uNjkyYy0uMDk1LS4wNzgtLjE3LS4yMjktLjE1NC0uNDNhNy42MTQgNy42MTQgMCAwIDAgMCAxLjEzOWMtLjAxNi0uMi4wNTktLjM1Mi4xNTMtLjQzbC44NC0uNjkyYy43MDgtLjU4Mi44OTEtMS41OS40MzMtMi4zODVsLS45MjItMS41OTdhMS44NzUgMS44NzUgMCAwIDAtMi4yODIuODE4bC0xLjAyLjM4MmMtLjExNC4wNDMtLjI4Mi4wMzEtLjQ0OS0uMDgzYTcuNDkgNy40OSAwIDAgMC0uOTg1LS41N2MtLjE4My0uMDg3LS4yNzctLjIyNy0uMjk3LS4zNDhsLS4xNzktMS4wNzJhMS44NzUgMS44NzUgMCAwIDAtMS44NS0xLjU2N2gtMS44NDNaTTEyIDE1Ljc1YTMuNzUgMy43NSAwIDEgMCAwLTcuNSAzLjc1IDMuNzUgMCAwIDAgMCA3LjVaIiBjbGlwLXJ1bGU9ImV2ZW5vZGQiLz48L3N2Zz4="

            script += """
            var imgLogo = document.getElementById('image-logo');
            if (imgLogo) imgLogo.src = '/image/uva/desktop/logo_footer.svg';
            var cardClass = document.querySelector('.card-class');
            if (cardClass && !document.getElementById('mais-uva-settings-btn')) {
                var gear = document.createElement('label');
                gear.id = 'mais-uva-settings-btn';
                gear.style.marginLeft = '10px';
                gear.innerHTML = '<img style="width:26px;height:26px;cursor:pointer;" src="data:image/svg+xml;base64,\(gearBase64)">';
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

// MARK: - Delegates
extension WebViewModel: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "openSettings" {
            DispatchQueue.main.async { if message.body as? String == "biometry" { self.autofillWithBiometrics() } else { self.showSettingsSheet = true } }
        } else if message.name == "credentialsCapture" {
            guard let body = message.body as? String, let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let u = json["username"], let p = json["password"] else { return }
            DispatchQueue.main.async { self.capturedUsername = u; self.capturedPassword = p }
        }
    }
}

extension WebViewModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        DispatchQueue.main.async { self.isLoading = true; self.showError = false; self.isNoInternetError = false }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.async {
            self.isLoading = false
            self.canGoBack = webView.canGoBack
            self.pageTitle = webView.title ?? ""
            self.updateBackButtonVisibility(url: webView.url)
            let isPDF = webView.url?.absoluteString.lowercased().hasSuffix(".pdf") ?? false
            self.isPDFPage = isPDF
            webView.scrollView.minimumZoomScale = isPDF ? 0.5 : 1.0
            webView.scrollView.maximumZoomScale = isPDF ? 5.0 : 1.0
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
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { isPDFPage ? scrollView.subviews.first : nil }
}
