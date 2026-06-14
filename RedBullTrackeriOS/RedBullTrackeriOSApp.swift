import SwiftUI

@main
struct RedBullTrackeriOSApp: App {
  @StateObject private var store = AppStore()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(store)
        .tint(store.activeTheme.primary)
        .task {
          await store.bootstrap()
        }
        .onChange(of: scenePhase) { _, newPhase in
          // app came back from the dead. resync everything because we don't trust anything
          if newPhase == .active, store.user != nil {
            Task {
              await store.refreshEntries(showLoader: false)
              await store.startRealtimeSync()
            }
          }
        }
    }
  }
}

struct RootView: View {
  @EnvironmentObject private var store: AppStore

  var body: some View {
    ZStack {
      AppBackground(theme: store.activeTheme)
      if store.authLoading {
        LoadingView()
      } else if store.user == nil {
        // no user no problem. well actually yes problem but at least it's pretty
        AuthView()
      } else {
        MainView()
      }
    }
    .preferredColorScheme(.light)
    .buttonStyle(GentleHapticPlainButtonStyle())
  }
}

struct LoadingView: View {
  @EnvironmentObject private var store: AppStore

  var body: some View {
    VStack(spacing: 20) {
      Image(systemName: "bolt.fill")
        .font(.system(size: 36, weight: .bold))
        .foregroundStyle(store.activeTheme.primary)
        .frame(width: 76, height: 76)
        .liquidGlass(radius: 28, tint: store.activeTheme.primary)

      VStack(spacing: 8) {
        Text("Red Bull Tracker")
          .font(.system(size: 34, weight: .bold))
        Text(store.setupStatus.message)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }

      ProgressView()
        .controlSize(.large)
    }
    .padding(30)
    .frame(maxWidth: 420)
    .liquidGlass(radius: 34, tint: store.activeTheme.primary)
    .padding(22)
  }
}
