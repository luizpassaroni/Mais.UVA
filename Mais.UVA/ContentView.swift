import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = WebViewModel()
    let uvaBlue = Color(red: 0/255, green: 75/255, blue: 120/255)

    var body: some View {
        VStack(spacing: 0) {
            // NavBar Customizada
            if (viewModel.showBackButton || viewModel.showReloadButton) && !viewModel.isLoading {
                HStack {
                    if viewModel.showBackButton {
                        Button(action: { viewModel.goBack() }) {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.left")
                                Text("Voltar")
                            }
                            .font(.system(size: 17, weight: .semibold))
                        }
                        .padding(.leading)
                    }
                    
                    Spacer()
                    
                    if viewModel.showReloadButton {
                        Button(action: { viewModel.reload() }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 18, weight: .bold))
                        }
                        .padding(.trailing)
                    }
                }
                .frame(height: 50)
                .background(uvaBlue)
                .foregroundColor(.white)
            }

            ZStack {
                uvaBlue.ignoresSafeArea()
                
                WebViewRepresentable(webView: viewModel.webView)
                    .opacity(viewModel.showError ? 0 : 1)
                
                if viewModel.isLoading && !viewModel.showError {
                    VStack {
                        ProgressView().tint(.yellow).scaleEffect(1.5)
                        Text("Carregando...").padding().foregroundColor(.white)
                    }
                }
                
                if viewModel.showError {
                    VStack(spacing: 20) {
                        Image(systemName: "wifi.slash").font(.largeTitle)
                        Text("Sem conexão com a internet")
                        Button("Tentar novamente") { viewModel.reload() }
                            .buttonStyle(.borderedProminent)
                            .tint(.yellow)
                            .foregroundColor(uvaBlue)
                    }
                    .foregroundColor(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
        .alert("Salvar senha?", isPresented: $viewModel.showSavePasswordPrompt) {
            Button("Salvar com Face ID") { viewModel.savePassword() }
            Button("Agora não", role: .cancel) { viewModel.discardSavePassword() }
        } message: {
            Text("Deseja usar a biometria para entrar automaticamente na próxima vez?")
        }
        .sheet(isPresented: $viewModel.showSettingsSheet) {
            SettingsView(viewModel: viewModel)
        }
    }
}

// Representable simples para o WebView
struct WebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct SettingsView: View {
    @ObservedObject var viewModel: WebViewModel
    @Environment(\.dismiss) var dismiss
    @State private var showingDeleteAlert = false

    var body: some View {
        NavigationView {
            List {
                Section("Segurança") {
                    if viewModel.hasCredentials {
                        Button(role: .destructive) { showingDeleteAlert = true } label: {
                            Label("Esquecer senha salva", systemImage: "trash")
                        }
                    } else {
                        Text("Nenhuma senha salva no dispositivo.")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Configurações")
            .toolbar {
                Button("Fechar") { dismiss() }
            }
            .confirmationDialog("Excluir senha?", isPresented: $showingDeleteAlert) {
                Button("Excluir", role: .destructive) {
                    viewModel.deleteCredentials()
                    dismiss()
                }
            }
        }
    }
}
