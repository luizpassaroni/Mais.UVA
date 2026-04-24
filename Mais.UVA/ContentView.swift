import SwiftUI
import WebKit

struct ContentView: View {
    @StateObject private var viewModel = WebViewModel()

    let uvaBlue = Color(red: 0/255, green: 75/255, blue: 120/255)

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.showBackButton && !viewModel.isLoading {
                NavBar(viewModel: viewModel)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: viewModel.showBackButton)
            }

            //
            ZStack {
                uvaBlue.ignoresSafeArea()

                WebView(viewModel: viewModel)
                    .opacity(viewModel.showError ? 0 : 1)
                    .ignoresSafeArea(edges: .bottom)

                if viewModel.showError {
                    ErrorView(isNoInternet: viewModel.isNoInternetError) {
                        viewModel.reload()
                    }
                }

                if viewModel.isLoading && !viewModel.showError {
                    ZStack {
                        uvaBlue.ignoresSafeArea()
                        VStack(spacing: 20) {
                            ProgressView()
                                .tint(.yellow)
                                .scaleEffect(2.0)
                            Text("Carregando...")
                                .foregroundColor(.white)
                                .font(.headline)
                        }
                    }
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .preferredColorScheme(.dark)
        .alert("Salvar senha?", isPresented: $viewModel.showSavePasswordPrompt) {
            Button("Salvar com Face ID") { viewModel.savePassword() }
            Button("Agora não", role: .cancel) { viewModel.discardSavePassword() }
        } message: {
            Text("Salve sua senha de forma segura para entrar automaticamente com Face ID ou Touch ID.")
        }
        .sheet(isPresented: $viewModel.showSettingsSheet) {
            SettingsSheet(viewModel: viewModel)
        }
    }
}

// MARK: - Barra de navegação atualizada

struct NavBar: View {
    @ObservedObject var viewModel: WebViewModel
    let uvaBlue = Color(red: 0/255, green: 75/255, blue: 120/255)

    var body: some View {
        HStack {
            // Botão de Voltar (Esquerda)
            Button(action: { viewModel.goBack() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Voltar")

            Spacer()

            // Botão de Recarregar (Direita)
            Button(action: { viewModel.reload() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Recarregar página")
        }
        .padding(.horizontal, 4)
        .frame(height: 44)
        .background(uvaBlue)
    }
}

// MARK: - Sheet de Configurações

struct SettingsSheet: View {
    @ObservedObject var viewModel: WebViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    if viewModel.hasCredentials {
                        HStack {
                            Image(systemName: "faceid")
                                .foregroundColor(.green)
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Senha salva")
                                    .font(.headline)
                                Text("Entrada automática com biometria ativa")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)

                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Esquecer senha salva", systemImage: "trash")
                        }
                    } else {
                        HStack {
                            Image(systemName: "faceid")
                                .foregroundColor(.secondary)
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Nenhuma senha salva")
                                    .font(.headline)
                                Text("Faça login e salve sua senha com Face ID")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Acesso rápido")
                }

                Section {
                    Text("Suas credenciais são armazenadas exclusivamente neste dispositivo, protegidas pelo Secure Enclave do iOS. Nunca são enviadas para servidores externos.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text("Segurança")
                }
            }
            .navigationTitle("Configurações")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Fechar") { dismiss() }
                }
            }
        }
        .confirmationDialog("Esquecer senha salva?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Esquecer senha", role: .destructive) {
                viewModel.deleteCredentials()
                dismiss()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Você precisará digitar sua senha manualmente no próximo acesso.")
        }
    }
}
