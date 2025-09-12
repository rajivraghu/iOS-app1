import SwiftUI

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("My App")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.top, 50)

            Image(systemName: "app.badge.checkmark.fill")
                .font(.system(size: 120))
                .foregroundStyle(Color.blue, Color.green)
                .padding()

            Text("Welcome to My App")
                .font(.title2)
                .foregroundColor(.secondary)

            Spacer()

            NavigationLink(destination: TripListView()) {
                Text("Continue")
                    .font(.headline)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal)
            .padding(.bottom, 30)
        }
        .navigationBarHidden(true)
    }
}

struct WelcomeView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            WelcomeView()
                .environmentObject(TripStore()) // For preview
        }
    }
}
