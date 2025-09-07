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
            // Set TripListView as the starting view and pass the store into the environment
            TripListView()
                .environmentObject(store)
        }
    }
}
