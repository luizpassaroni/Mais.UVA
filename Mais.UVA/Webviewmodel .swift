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

        // Configuração de Handlers
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

        // KVO
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
                userField.value = '';
                passField.value = '';
                
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
    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
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
        default:
            break
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
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        return context.biometryType
    }

    private func renderSFSymbol(named name: String, size: CGFloat, color: UIColor) -> String {
        let config = UIImage.SymbolConfiguration(pointSize: size, weight: .thin)
        guard let image = UIImage(systemName: name, withConfiguration: config)?
                .withTintColor(color, renderingMode: .alwaysOriginal),
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

        var script = """
        (function() {
            var meta = document.querySelector('meta[name="viewport"]') || document.createElement('meta');
            meta.name = 'viewport';
            meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
            document.getElementsByTagName('head')[0].appendChild(meta);
        """

        if isPortal { script += "\ndocument.body.style.backgroundColor = '#004B78';" }

        if isLogin || isEsqueciSenha {
            script += """
            var buttons = document.querySelectorAll('button.btn-style, button.button-type-mobile');
            buttons.forEach(function(btn) {
                btn.style.backgroundColor = '#FFD000';
                btn.style.color = '#004B78';
            });
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
                let sfSymbolName = biometryType == .faceID ? "faceid" : (biometryType == .touchID ? "touchid" : "lock.fill")
                let buttonLabel  = biometryType == .faceID ? "Entrar com Face ID" : (biometryType == .touchID ? "Entrar com Touch ID" : "Entrar com biometria")
                let base64Icon   = renderSFSymbol(named: sfSymbolName, size: 80, color: .white)

                script += """
                (function() {
                    if (document.getElementById('mais-uva-bio-block')) return;
                    var forgotLink = document.querySelector('a[href*="EsqueciSenha"]');
                    var fieldsToHide = document.querySelectorAll('.form-group, .input-group, input, #btn_logar, label[for]');
                    fieldsToHide.forEach(function(el) { el.style.display = 'none'; });

                    var block = document.createElement('div');
                    block.id = 'mais-uva-bio-block';
                    block.style.cssText = 'display:flex;flex-direction:column;align-items:center;gap:20px;padding:40px 24px;width:100%;';

                    var icon = document.createElement('img');
                    icon.src = 'data:image/png;base64,\(base64Icon)';
                    icon.style.cssText = 'width:72px;height:72px;opacity:0.9;';
                    block.appendChild(icon);

                    var bioBtn = document.createElement('button');
                    bioBtn.textContent = '\(buttonLabel)';
                    bioBtn.style.cssText = 'background:#FFD000;color:#004B78;border:none;border-radius:10px;padding:14px 0;font-size:16px;font-weight:bold;width:85%;';
                    bioBtn.addEventListener('click', function() {
                        window.webkit.messageHandlers.openSettings.postMessage('biometry');
                    });
                    block.appendChild(bioBtn);

                    if (forgotLink) {
                        forgotLink.style.cssText = 'color:white;text-decoration:underline;font-size:14px;margin-top:10px;display:block;';
                        block.appendChild(forgotLink);
                    }

                    var container = document.querySelector('.card-body') || document.querySelector('form') || document.body;
                    container.appendChild(block);
                })();
                """
            }
        }

        if isPortalHome {
            script += """
            var imgLogo = document.getElementById('image-logo');
            if (imgLogo) imgLogo.src = '/image/uva/desktop/logo_footer.svg';

            var cardClass = document.querySelector('.card-class');
            if (cardClass && !document.getElementById('mais-uva-settings-btn')) {
                var refLabel = document.querySelector('.card-class label');
                var refClass = refLabel ? refLabel.className : '';
                var gear = document.createElement('label');
                gear.id = 'mais-uva-settings-btn';
                gear.className = refClass;
                gear.innerHTML = '<img style="width:26px;height:26px;" src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0id2hpdGUiPjxwYXRoIGZpbGwtcnVsZT0iZXZlbm9kZCIgZD0iTTExLjA3OCAyLjI1Yy0uOTE3IDAtMS42OTkuNjYzLTEuODUgMS41NjdMOS4wNSA0Ljg4OWMtLjAyLjEyLS4xMTUuMjYtLjI5Ny4zNDhhNy40OTMgNy40OTMgMCAwIDAtLjk4Ni41N2MtLjE2Ni4xMTUtLjMzNC4xMjYtLjQ1LjA4M0w2LjMgNS41MDhhMS44NzUgMS44NzUgMCAwIDAtMi4yODIuODE5bC0uOTIyIDEuNTk3YTEuODc1IDEuODc1IDAgMCAwIC40MzIgMi4zODVsLjg0LjY5MmMuMDk1LjA3OC4xNy4yMjkuMTU0LjQzYTcuNTk4IDcuNTk4IDAgMCAwIDAtMS4xMzljLjAxNS4yLS4wNTkuMzUyLS4xNTMuNDNsLS44NDEuNjkyYTEuODc1IDEuODc1IDAgMCAwLS40MzIgMi4zODVsLjkyMiAxLjU5N2ExLjg3NSAxLjg3NSAwIDAgMCAyLjI4Mi44MThsMS4wMTktLjM4MmMuMTE1LS4wNDMuMjgzLS4wMzEuNDUuMDgyLjMxMi4yMTQuNjQxLjQwNS45ODUuNTcuMTgyLjA4OC4yNzcuMjI4LjI5Ny4zNWwuMTc4IDEuMDcxYy4xNTEuOTA0LjkzMyAxLjU2NyAxLjg1IDEuNTY3aDEuODQ0Yy45MTYgMCAxLjY5OS0uNjYzIDEuODUtMS41NjdsLjE3OC0xLjA3MmMuMDIpLTMuMzQ5LjM0NC0uMTY1LjY3My0uMzU2Ljk4NS0uNTcuMTY3LS4xMTQuMzM1LS4xMjUuNDUtLjA4MmwxLjAyLjM4MmExLjg3NSAxLjg3NSAwIDAgMCAyLjI4LS4groupLWwuOTIzLTEuNTk3YTEuODc1IDEuODc1IDAgMCAwLS40MzItMi4zODVsLS44NC0uNjkyYy0uMDk1LS4wNzgtLjE3LS4yMjktLjE1NC0uNDNhNy42MTQgNy42MTQgMCAwIDAgMCAxLjEzOWMtLjAxNi0uMi4wNTktLjM1Mi4xNTMtLjQzbC44NC0uNjkyYy43MDgtLjU4Mi44OTEtMS41OS40MzMtMi4zODVsLS45MjItMS41OTdhMS44NzUgMS44NzUgMCAwIDAtMi4yODItLjgxOGwtMS4wMi4zODJjLS4xMTQuMDQzLS4yODIuMDMxLS40NDktLjA4M2E3LjQ5IDcuNDkgMCAwIDAtLjk4NS0uNTdjLS4xODMtLjA4Ny0uMjc3LS4yMjctLjI5Ny0uMzQ4bC0uMTc5LTEuMDcyYTEuODc1IDEuODc1IDAgMCAwLTEuODUtMS41NjdoLTEuODQzWk0xMiAxNS43NWEzLjc1IDMuNzUgMCAxIDAgMC03LjUgMy43NSAzLjc1IDAgMCAwIDAgNy41WiIgY2xpcC1ydWxlPSJldmVub2RkIi8+PC9zdmc+">';
                gear.addEventListener('click', function() {
                    window.webkit.messageHandlers.openSettings.postMessage('open');
                });
                cardClass.appendChild(gear);
            }
            """
        }

        script += "\n})();"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func jsString(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                               .replacingOccurrences(of: "\"", with: "\\\"")
                               .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}

// MARK: - WKScriptMessageHandler
extension WebViewModel: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "openSettings":
            DispatchQueue.main.async {
                if message.body as? String == "biometry" {
                    self.autofillWithBiometrics()
                } else {
                    self.showSettingsSheet = true
                }
            }
        case "credentialsCapture":
            guard let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let username = json["username"], !username.isEmpty,
                  let password = json["password"], !password.isEmpty else { return }
            DispatchQueue.main.async {
                self.capturedUsername = username
                self.capturedPassword = password
            }
        default: break
        }
    }
}

// MARK: - WKNavigationDelegate
extension WebViewModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        DispatchQueue.main.async {
            self.isLoading = true
            self.showError = false
            self.isNoInternetError = false // Limpa o estado de erro ao começar nova carga
        }
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

            guard let urlString = webView.url?.absoluteString else { return }

            if urlString.contains("Aluno/PortalAluno"), !self.capturedUsername.isEmpty, !KeychainManager.shared.hasCredentials() {
                self.showSavePasswordPrompt = true
            }
        }
        injectScript(in: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        
        // CORREÇÃO DO BUG: Ignora o erro -999 (operação cancelada)
        // Isso acontece quando o WebView cancela uma carga para iniciar um redirecionamento
        if nsError.code == NSURLErrorCancelled {
            return
        }

        DispatchQueue.main.async {
            self.isLoading = false
            self.isNoInternetError = true
            self.showError = true
        }
    }
    
    // Opcional: Adicionar tratamento de falha na navegação principal também
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        
        DispatchQueue.main.async {
            self.isLoading = false
            self.showError = true
        }
    }
}

// MARK: - WKUIDelegate e UIScrollViewDelegate
extension WebViewModel: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

extension WebViewModel: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return isPDFPage ? scrollView.subviews.first : nil
    }
}

// Removi o WeakMessageHandler duplicado pois você já implementa o WKScriptMessageHandler na WebViewModel principal.
