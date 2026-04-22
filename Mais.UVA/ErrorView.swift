import SwiftUI

struct ErrorView: View {
    var isNoInternet: Bool
    var retryAction: () -> Void

    let uvaBlue = Color(red: 0/255, green: 75/255, blue: 120/255)

    var body: some View {
        ZStack {
            uvaBlue.ignoresSafeArea()

            VStack(spacing: 25) {
                Image(systemName: isNoInternet ? "wifi.exclamationmark" : "icloud.slash.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.white.opacity(0.8))

                VStack(spacing: 10) {
                    Text(isNoInternet ? "Sem Conexão" : "Portal Indisponível")
                        .font(.title2)
                        .bold()
                        .foregroundColor(.white)

                    Text(isNoInternet ?
                         "Verifique sua conexão com a internet e tente novamente." :
                         "O servidor da UVA parece estar offline. Tente novamente em instantes.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 30)
                }

                Button(action: retryAction) {
                    Text("TENTAR NOVAMENTE")
                        .fontWeight(.bold)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.yellow)
                        .foregroundColor(uvaBlue)
                        .cornerRadius(10)
                        .shadow(radius: 5)
                }
                .padding(.horizontal, 50)
                .padding(.top, 10)
            }
        }
    }
}
