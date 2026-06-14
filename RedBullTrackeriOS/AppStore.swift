import Appwrite
import Foundation
import SwiftUI

enum AuthMode {
  case login
  case signup
}

struct QuickAdd: Identifiable {
  var id: String { label }
  var label: String
  var flavour: String
  var sizeMl: Int
  var pricePerCan: Double
}

let quickAdds: [QuickAdd] = [
  QuickAdd(label: "Original", flavour: "Original", sizeMl: 250, pricePerCan: 1.75),
  QuickAdd(label: "Sugar Free", flavour: "Sugar Free", sizeMl: 250, pricePerCan: 1.75),
  QuickAdd(label: "Ice Edition", flavour: "Ice Edition", sizeMl: 250, pricePerCan: 1.75),
  QuickAdd(label: "473ml Original", flavour: "Original", sizeMl: 473, pricePerCan: 2.85),
]

struct AppAnalytics {
  var allFlavours: [Flavour]
  var entriesInView: [RedBullEntry]
  var dashboard: Dashboard
  var insights: [Insight]
  var limitCheck: LimitCheckResult
  var chartData: [DayPoint]
  var weekData: [WeekPoint]
  var flavourData: [FlavourPoint]
  var favouriteFlavourOverall: String
  var recentEntries: [RedBullEntry]

  static let empty = AppAnalytics(entries: [], filters: EntryFilters(), limits: UserLimits())

  init(entries: [RedBullEntry], filters: EntryFilters, limits: UserLimits) {
    let filteredEntries = Metrics.sorted(Metrics.applyFilters(entries, filters: filters))
    allFlavours = availableFlavours(from: entries)
    entriesInView = filteredEntries
    dashboard = Metrics.dashboard(entries: entries)
    insights = Metrics.insights(entries: entries)
    limitCheck = Limits.evaluate(limits: limits, entries: entries)
    chartData = Metrics.groupByDay(filteredEntries)
    weekData = Metrics.groupByWeek(filteredEntries)
    flavourData = Metrics.groupByFlavour(filteredEntries)
    favouriteFlavourOverall = Metrics.topByCans(entries)
    recentEntries = Array(entries.prefix(5))
  }
}

// one store to rule them all. pray it never crashes
@MainActor
final class AppStore: ObservableObject {
  @Published var user: AppwriteUser?
  @Published var entries: [RedBullEntry] = [] {
    // touch anything and the whole analytics pipeline wakes up screaming
    didSet { refreshAnalytics() }
  }
  @Published var filters = EntryFilters() {
    didSet { refreshAnalytics() }
  }
  @Published var activeView: AppView = .overview
  @Published var themeId: String = UserDefaults.standard.string(forKey: "red-bull-intake-tracker.theme.v2") ?? defaultThemeId
  @Published var userLimits = UserLimits() {
    didSet { refreshAnalytics() }
  }
  @Published var authLoading = true
  @Published var dataLoading = false
  @Published var busyAction: String?
  @Published var notice = "Sync pending."
  @Published var setupStatus: SetupStatus = .checking("Checking sync...")
  @Published var syncError = ""
  @Published private(set) var realtimeConnected = false
  @Published private(set) var realtimeStatus = "Paused"
  @Published var authError = ""
  @Published var setupOpen = false
  @Published var pendingLimitDraft: EntryDraft?
  @Published var pendingLimitEditingId: String?
  @Published var limitOverrideMessage = ""
  @Published var showLimitOverride = false
  @Published private(set) var analytics = AppAnalytics.empty

  let appwrite: AppwriteService
  let intakeRepository: IntakeRepository
  let barcodeRepository: BarcodeRepository
  private var realtimeSubscription: RealtimeSubscription?
  private var realtimeRefreshTask: Task<Void, Never>?
  private var realtimeShouldRun = false

  init(appwrite: AppwriteService = AppwriteService()) {
    self.appwrite = appwrite
    intakeRepository = IntakeRepository(service: appwrite)
    barcodeRepository = BarcodeRepository(service: appwrite)
    themeId = knownThemeId(themeId)
    wireRealtimeCallbacks()
  }

  var activeTheme: AppTheme {
    themeForId(themeId)
  }

  // fifteen wrappers that all just forward to analytics. stunning architecture
  var allFlavours: [Flavour] {
    analytics.allFlavours
  }

  var entriesInView: [RedBullEntry] {
    analytics.entriesInView
  }

  var dashboard: Dashboard {
    analytics.dashboard
  }

  var insights: [Insight] {
    analytics.insights
  }

  var limitCheck: LimitCheckResult {
    analytics.limitCheck
  }

  var chartData: [DayPoint] {
    analytics.chartData
  }

  var weekData: [WeekPoint] {
    analytics.weekData
  }

  var flavourData: [FlavourPoint] {
    analytics.flavourData
  }

  var favouriteFlavourOverall: String {
    analytics.favouriteFlavourOverall
  }

  var recentEntries: [RedBullEntry] {
    analytics.recentEntries
  }

  func bootstrap() async {
    authLoading = true
    authError = ""
    do {
      _ = try await appwrite.ping()
      setupStatus = .ok("Sync ready.")
    } catch {
      setupStatus = .error(error.localizedDescription)
    }

    do {
      let currentUser = try await appwrite.currentUser()
      adoptUser(currentUser)
      notice = "Signed in as \(currentUser.email.isEmpty ? currentUser.name : currentUser.email)."
      if !finishedOnboarding(currentUser) {
        setupOpen = true
      }
      await refreshEntries(showLoader: true)
      await startRealtimeSync()
    } catch {
      await stopRealtimeSync()
      user = nil
      entries = []
      notice = "Sign in to sync entries across devices."
    }
    authLoading = false
  }

  func login(email: String, password: String) async {
    busyAction = "auth"
    authError = ""
    do {
      let currentUser = try await appwrite.login(email: email, password: password)
      adoptUser(currentUser)
      notice = "Signed in as \(currentUser.email)."
      if !finishedOnboarding(currentUser) {
        setupOpen = true
      }
      await refreshEntries(showLoader: true)
      await startRealtimeSync()
    } catch {
      authError = appwriteErrorMessage(error)
    }
    busyAction = nil
  }

  func signup(name: String, email: String, password: String) async {
    busyAction = "auth"
    authError = ""
    do {
      let currentUser = try await appwrite.signup(name: name, email: email, password: password)
      adoptUser(currentUser)
      notice = "Welcome, \(currentUser.name.isEmpty ? currentUser.email : currentUser.name)."
      setupOpen = true
      await refreshEntries(showLoader: true)
      await startRealtimeSync()
    } catch {
      authError = appwriteErrorMessage(error)
    }
    busyAction = nil
  }

  func logout() async {
    busyAction = "logout"
    syncError = ""
    do {
      await stopRealtimeSync()
      try await appwrite.logout()
      user = nil
      entries = []
      notice = "Logged out."
    } catch {
      syncError = appwriteErrorMessage(error)
    }
    busyAction = nil
  }

  func refreshEntries(showLoader: Bool = true, updateNotice: Bool = true) async {
    guard let user else { return }
    if showLoader {
      dataLoading = true
    }
    syncError = ""
    do {
      let remoteEntries = try await intakeRepository.listEntries(userId: user.id)
      entries = Metrics.sorted(remoteEntries)
      if updateNotice {
        notice = "\(remoteEntries.count) \(remoteEntries.count == 1 ? "entry" : "entries") up to date."
      }
    } catch {
      syncError = appwriteErrorMessage(error)
      notice = "Sync failed."
    }
    if showLoader {
      dataLoading = false
    }
  }

  func startRealtimeSync() async {
    guard user != nil, realtimeSubscription == nil else { return }
    realtimeShouldRun = true
    realtimeStatus = "Connecting..."

    do {
      let channel = try Channel.tablesdb(appwrite.config.databaseId)
        .table(appwrite.config.intakeTableId)
        .row()
      realtimeSubscription = try await appwrite.realtime.subscribe(channel: channel) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.queueRealtimeRefresh()
        }
      }
      realtimeConnected = true
      realtimeStatus = "Live"
    } catch {
      realtimeShouldRun = false
      realtimeConnected = false
      realtimeStatus = "Unavailable"
    }
  }

  func stopRealtimeSync() async {
    realtimeShouldRun = false
    realtimeRefreshTask?.cancel()
    realtimeRefreshTask = nil
    if let realtimeSubscription {
      try? await realtimeSubscription.close()
    } else {
      try? await appwrite.realtime.disconnect()
    }
    realtimeSubscription = nil
    realtimeConnected = false
    realtimeStatus = "Paused"
  }

  func saveUserLimits(_ next: UserLimits) async {
    guard let user else { return }
    busyAction = "save-limits"
    syncError = ""
    do {
      let prefs = Limits.merge(existing: AppwriteService.prefsDictionary(from: user), limits: next)
      let currentUser = try await appwrite.updatePrefs(prefs)
      adoptUser(currentUser)
      notice = "Daily limits saved to your account."
    } catch {
      syncError = appwriteErrorMessage(error)
    }
    busyAction = nil
  }

  func saveOnboarding(limits: UserLimits, onboardingThemeId: String) async {
    guard let user else { return }
    busyAction = "save-onboarding"
    syncError = ""
    do {
      var prefs = Limits.merge(existing: AppwriteService.prefsDictionary(from: user), limits: limits)
      prefs["themeId"] = onboardingThemeId
      prefs["onboarded"] = true
      let currentUser = try await appwrite.updatePrefs(prefs)
      adoptUser(currentUser)
      setThemeId(onboardingThemeId, sync: false)
      setupOpen = false
      notice = "Setup saved."
    } catch {
      syncError = appwriteErrorMessage(error)
    }
    busyAction = nil
  }

  func setThemeId(_ nextThemeId: String, sync: Bool = true) {
    let normalised = knownThemeId(nextThemeId)
    themeId = normalised
    UserDefaults.standard.set(normalised, forKey: "red-bull-intake-tracker.theme.v2")
    guard sync else { return }
    Task { await saveThemePreference(normalised) }
  }

  func saveThemePreference(_ nextThemeId: String) async {
    guard let user else { return }
    do {
      var prefs = AppwriteService.prefsDictionary(from: user)
      prefs["themeId"] = nextThemeId
      let currentUser = try await appwrite.updatePrefs(prefs)
      adoptUser(currentUser)
    } catch {
      syncError = appwriteErrorMessage(error)
    }
  }

  func saveOrWarn(_ draft: EntryDraft, editingId: String? = nil) {
    // limits exist to be ignored. this dialog is the ceremonial part
    let check = Limits.evaluate(limits: userLimits, entries: entries, draft: draft, excludeEntryId: editingId)
    if check.violations.isEmpty {
      Task { await saveEntryDraft(draft, editingId: editingId) }
      return
    }
    pendingLimitDraft = draft
    pendingLimitEditingId = editingId
    limitOverrideMessage = Limits.statusMessage(violations: check.violations, check: check, limits: userLimits)
    showLimitOverride = true
  }

  func saveDespiteLimit() async {
    guard let draft = pendingLimitDraft else { return }
    let editingId = pendingLimitEditingId
    forgetLimitWarning()
    await saveEntryDraft(draft, editingId: editingId)
  }

  func forgetLimitWarning() {
    pendingLimitDraft = nil
    pendingLimitEditingId = nil
    limitOverrideMessage = ""
    showLimitOverride = false
  }

  func saveEntryDraft(_ draft: EntryDraft, editingId: String? = nil) async {
    guard let user else { return }
    busyAction = editingId == nil ? "save-entry" : "update-entry"
    syncError = ""
    do {
      let saved: RedBullEntry
      if let editingId {
        saved = try await intakeRepository.updateEntry(userId: user.id, id: editingId, draft: draft)
        entries = Metrics.sorted(entries.map { $0.id == saved.id ? saved : $0 })
        notice = "Entry updated."
      } else {
        saved = try await intakeRepository.createEntry(userId: user.id, draft: draft)
        entries = Metrics.sorted([saved] + entries)
        notice = "Entry saved."
      }
    } catch {
      syncError = appwriteErrorMessage(error)
    }
    busyAction = nil
  }

  func quickAdd(_ item: QuickAdd) {
    var draft = EntryDraft()
    let meta = flavourDetails(item.flavour)
    draft.cans = 1
    draft.flavour = item.flavour
    draft.flavourAccent = meta.accent
    draft.sizeMl = item.sizeMl
    draft.pricePerCan = item.pricePerCan
    draft.date = Date()
    draft.sugarFree = meta.sugarFree
    draft.notes = "Quick add"
    draft.store = ""
    draft.source = .quickAdd
    saveOrWarn(draft)
  }

  func deleteEntry(_ entry: RedBullEntry) async {
    busyAction = "delete-\(entry.id)"
    syncError = ""
    do {
      try await intakeRepository.deleteEntry(id: entry.id)
      entries.removeAll { $0.id == entry.id }
      notice = "Entry deleted."
    } catch {
      syncError = appwriteErrorMessage(error)
    }
    busyAction = nil
  }

  func resetAll() async {
    busyAction = "reset"
    syncError = ""
    do {
      // delete them one by one like a psychopath. batch delete? never heard of her
      for entry in entries {
        try await intakeRepository.deleteEntry(id: entry.id)
      }
      entries = []
      filters = EntryFilters()
      notice = "All entries deleted."
    } catch {
      syncError = appwriteErrorMessage(error)
    }
    busyAction = nil
  }

  func importJSON(from url: URL) async {
    guard let user else { return }
    busyAction = "json-import"
    syncError = ""
    do {
      // security scoped resource dance. ios file access is a fucking joke
      let accessed = url.startAccessingSecurityScopedResource()
      defer {
        if accessed {
          url.stopAccessingSecurityScopedResource()
        }
      }
      let data = try Data(contentsOf: url)
      let drafts = try ImportParser.parseJSON(data)
      let uniqueDrafts = drafts.filter { !Metrics.alreadyImported(existing: entries, draft: $0) }
      guard !uniqueDrafts.isEmpty else {
        notice = "No new JSON entries found."
        busyAction = nil
        return
      }
      let saved = try await intakeRepository.createEntries(userId: user.id, drafts: uniqueDrafts)
      entries = Metrics.sorted(saved + entries)
      notice = "\(saved.count) JSON \(saved.count == 1 ? "entry" : "entries") saved."
    } catch {
      syncError = error.localizedDescription
    }
    busyAction = nil
  }

  func loadBarcodeCatalog() async -> BarcodeLookupCatalog {
    guard let user else { return BarcodeLookupCatalog() }
    return await barcodeRepository.listCatalog(userId: user.id)
  }

  func saveBarcodeMapping(barcode: String, product: BarcodeProductDraft) async -> UserBarcodeMapping? {
    guard let user else { return nil }
    return await barcodeRepository.upsertUserMapping(userId: user.id, barcodeValue: barcode, product: product)
  }

  private func adoptUser(_ currentUser: AppwriteUser) {
    user = currentUser
    let prefs = AppwriteService.prefsDictionary(from: currentUser)
    userLimits = Limits.parse(prefs)
    if let theme = prefs["themeId"] as? String, !theme.isEmpty {
      setThemeId(theme, sync: false)
    }
  }

  private func finishedOnboarding(_ currentUser: AppwriteUser) -> Bool {
    let prefs = AppwriteService.prefsDictionary(from: currentUser)
    return readBool(prefs["onboarded"]) ?? false
  }

  private func refreshAnalytics() {
    analytics = AppAnalytics(entries: entries, filters: filters, limits: userLimits)
  }

  private func wireRealtimeCallbacks() {
    // same handler copy-pasted three times. DRY is for other people's repos
    appwrite.realtime.onOpen { [weak self] in
      Task { @MainActor [weak self] in
        guard self?.realtimeShouldRun == true else { return }
        self?.realtimeConnected = true
        self?.realtimeStatus = "Live"
      }
    }
    appwrite.realtime.onClose { [weak self] in
      Task { @MainActor [weak self] in
        guard self?.realtimeShouldRun == true else { return }
        self?.realtimeConnected = false
        self?.realtimeStatus = "Reconnecting..."
      }
    }
    appwrite.realtime.onError { [weak self] _, _ in
      Task { @MainActor [weak self] in
        guard self?.realtimeShouldRun == true else { return }
        self?.realtimeConnected = false
        self?.realtimeStatus = "Reconnecting..."
      }
    }
  }

  private func queueRealtimeRefresh() {
    realtimeRefreshTask?.cancel()
    realtimeRefreshTask = Task { [weak self] in
      // 350ms debounce because realtime fires like a machine gun and we're not animals
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }
      await self?.refreshEntries(showLoader: false, updateNotice: false)
    }
  }
}

enum SetupStatus: Equatable {
  case checking(String)
  case ok(String)
  case error(String)

  var message: String {
    switch self {
    case .checking(let message), .ok(let message), .error(let message):
      message
    }
  }

  var isOK: Bool {
    if case .ok = self {
      return true
    }
    return false
  }
}

func readBool(_ value: Any?) -> Bool? {
  // prefs come back as bool, number, or string. because why would json be consistent
  switch value {
  case let bool as Bool:
    return bool
  case let number as NSNumber:
    return number.boolValue
  case let string as String:
    if ["true", "1", "yes"].contains(string.lowercased()) { return true }
    if ["false", "0", "no"].contains(string.lowercased()) { return false }
    return nil
  default:
    return nil
  }
}

func displayFirstName(_ user: AppwriteUser?) -> String {
  guard let user else { return "there" }
  let fallback = user.email.split(separator: "@").first.map(String.init) ?? "there"
  let value = (user.name.isEmpty ? fallback : user.name).trimmingCharacters(in: .whitespacesAndNewlines)
  return value.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "there"
}

func displayInitial(_ user: AppwriteUser?) -> String {
  let value = user?.name.isEmpty == false ? user?.name : user?.email
  return String(value?.trimmingCharacters(in: .whitespacesAndNewlines).first ?? "R").uppercased()
}
