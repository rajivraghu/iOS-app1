import SwiftUI
import FirebaseCore

@main
struct MyFirstAppApp: App {
    // Create the data store here as a StateObject
    @StateObject private var store = TripStore()

    init() {
        // Configure Firebase once at app start
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if store.isInitialLoad {
                    LoadingView()
                } else {
                    TripListView()
                }
            }
            .environmentObject(store)
        }
    }
}
