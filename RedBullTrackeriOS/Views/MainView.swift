import Charts
import SwiftUI
import UniformTypeIdentifiers

struct EntrySheet: Identifiable {
  let id = UUID()
  var entry: RedBullEntry?
  var draft: EntryDraft

  static func new() -> EntrySheet {
    EntrySheet(entry: nil, draft: EntryDraft())
  }

  static func edit(_ entry: RedBullEntry) -> EntrySheet {
    EntrySheet(entry: entry, draft: EntryDraft(entry: entry))
  }

  static func draft(_ draft: EntryDraft) -> EntrySheet {
    EntrySheet(entry: nil, draft: draft)
  }
}

struct MainView: View {
  @EnvironmentObject private var store: AppStore
  @State private var entrySheet: EntrySheet?
  @State private var scannerOpen = false
  @State private var resetConfirmationOpen = false
  @State private var exportDocument = JSONExportDocument()
  @State private var exportingJSON = false
  @State private var importingJSON = false

  var body: some View {
    TabView(selection: $store.activeView) {
      OverviewView(
        onAdd: { entrySheet = .new() },
        onScan: { scannerOpen = true },
        onOpenLogbook: { store.activeView = .logbook },
        onOpenSettings: { store.activeView = .settings }
      )
      .tag(AppView.overview)
      .tabItem { Label(AppView.overview.title, systemImage: AppView.overview.symbol) }

      LogbookView(
        onAdd: { entrySheet = .new() },
        onEdit: { entrySheet = .edit($0) }
      )
      .tag(AppView.logbook)
      .tabItem { Label(AppView.logbook.title, systemImage: AppView.logbook.symbol) }

      TrendsView()
        .tag(AppView.trends)
        .tabItem { Label(AppView.trends.title, systemImage: AppView.trends.symbol) }

      SettingsView(
        onExportJSON: prepareExport,
        onImportJSON: { importingJSON = true },
        onReset: { resetConfirmationOpen = true }
      )
      .tag(AppView.settings)
      .tabItem { Label(AppView.settings.title, systemImage: AppView.settings.symbol) }
    }
    .toolbarBackground(.ultraThinMaterial, for: .tabBar)
    .toolbarBackground(.visible, for: .tabBar)
    .sheet(item: $entrySheet) { sheet in
      EntryEditorView(sheet: sheet) { draft in
        store.saveOrWarn(draft, editingId: sheet.entry?.id)
        entrySheet = nil
      }
      .presentationDetents([.large])
      .presentationDragIndicator(.visible)
    }
    .sheet(isPresented: $scannerOpen) {
      BarcodeScannerSheet { draft in
        scannerOpen = false
        store.saveOrWarn(draft)
      } editBeforeAdding: { draft in
        scannerOpen = false
        entrySheet = .draft(draft)
      }
    }
    .fullScreenCover(isPresented: $store.setupOpen) {
      OnboardingView()
        .interactiveDismissDisabled(false)
    }
    .fileExporter(
      isPresented: $exportingJSON,
      document: exportDocument,
      contentType: .json,
      defaultFilename: "red-bull-intake-\(DateFormatters.dateKey.string(from: Date())).json"
    ) { result in
      if case .failure(let error) = result {
        store.syncError = error.localizedDescription
      } else {
        store.notice = "JSON backup exported."
      }
    }
    .fileImporter(isPresented: $importingJSON, allowedContentTypes: [.json]) { result in
      if case .success(let url) = result {
        Task { await store.importJSON(from: url) }
      } else if case .failure(let error) = result {
        store.syncError = error.localizedDescription
      }
    }
    .alert("Delete all entries?", isPresented: $resetConfirmationOpen) {
      Button("Cancel", role: .cancel) {}
      Button("Delete all", role: .destructive) {
        Task { await store.resetAll() }
      }
    } message: {
      Text("This removes every intake entry for your account.")
    }
    // guilt trip dialog. log anyway means you chose violence against your own limits
    .alert("Over your limit?", isPresented: $store.showLimitOverride) {
      Button("Cancel", role: .cancel) {
        store.forgetLimitWarning()
      }
      Button("Log anyway") {
        Task { await store.saveDespiteLimit() }
      }
    } message: {
      Text(store.limitOverrideMessage.isEmpty ? "This intake goes past one of your daily limits." : store.limitOverrideMessage)
    }
  }

  private func prepareExport() {
    do {
      exportDocument = try JSONExportDocument(entries: store.entries)
      exportingJSON = true
    } catch {
      store.syncError = error.localizedDescription
    }
  }
}

struct OverviewView: View {
  @EnvironmentObject private var store: AppStore
  var onAdd: () -> Void
  var onScan: () -> Void
  var onOpenLogbook: () -> Void
  var onOpenSettings: () -> Void

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(spacing: 14) {
          HealthTopBar()
          if !store.syncError.isEmpty || !store.setupStatus.isOK || store.busyAction != nil {
            StatusRail()
          }
          TodayHero(onAdd: onAdd, onScan: onScan)
          QuickAddCarousel()
          TodayLimitsPanel(onOpenSettings: onOpenSettings)
          MetricCarousel()
          RecentEntriesPanel(onAdd: onAdd, onOpenLogbook: onOpenLogbook)
          FlavourSpectrumPanel()
          InsightStack()
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 28)
      }
      .liquidBackground(store.activeTheme)
      .toolbar(.hidden, for: .navigationBar)
      .refreshable {
        await store.refreshEntries()
      }
    }
  }
}

struct HealthTopBar: View {
  @EnvironmentObject private var store: AppStore

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Home")
          .font(.largeTitle.weight(.bold))
        Text("Today at a glance")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 6)

      Text(displayInitial(store.user))
        .font(.subheadline.weight(.bold))
        .foregroundStyle(store.activeTheme.primary)
        .frame(width: 36, height: 36)
        .background(store.activeTheme.primary.opacity(0.10), in: Circle())
    }
    .padding(.vertical, 6)
  }
}

struct LimitHeadroomBadge: View {
  var summary: LimitHeadroomSummary
  var todayCans: Double

  var body: some View {
    if summary.hasConfiguredLimit {
      HStack(spacing: 6) {
        if let cans = summary.cans {
          LimitHeadroomChip(headroom: cans, isTightest: summary.tightest?.kind == .cans)
        }
        if let spend = summary.spend {
          LimitHeadroomChip(headroom: spend, isTightest: summary.tightest?.kind == .spend)
        }
      }
    } else {
      Label("\(Metrics.one(todayCans)) today", systemImage: "drop.fill")
        .font(.caption.weight(.bold))
        .foregroundStyle(Color(hex: "#1F2937"))
        .padding(.horizontal, 11)
        .frame(height: 36)
        .background(.white.opacity(0.82), in: Capsule())
        .overlay(Capsule().stroke(.black.opacity(0.04), lineWidth: 0.8))
        .accessibilityLabel("\(Metrics.one(todayCans)) cans logged today")
    }
  }
}

struct LimitHeadroomChip: View {
  var headroom: LimitHeadroom
  var isTightest: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(headroom.kind.label)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(isTightest ? Color(hex: "#B45309") : .secondary)
      Text("\(headroom.percentLeft)% left")
        .font(.caption.weight(.bold))
        .foregroundStyle(Color(hex: "#1F2937"))
    }
    .padding(.horizontal, 10)
    .frame(height: 36)
    .background(chipBackground, in: Capsule())
    .overlay(Capsule().stroke(chipBorder, lineWidth: isTightest ? 1.2 : 0.8))
    .accessibilityLabel("\(headroom.kind.label), \(headroom.percentLeft) percent left\(isTightest ? ", closest to limit" : "")")
  }

  private var chipBackground: Color {
    isTightest ? Color(hex: "#FEF3C7").opacity(0.95) : .white.opacity(0.82)
  }

  private var chipBorder: Color {
    isTightest ? Color(hex: "#F59E0B").opacity(0.45) : .black.opacity(0.04)
  }
}

struct TodayHero: View {
  @EnvironmentObject private var store: AppStore
  var onAdd: () -> Void
  var onScan: () -> Void

  var body: some View {
    let dashboard = store.dashboard
    let check = store.limitCheck
    let theme = store.activeTheme

    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Hi \(displayFirstName(store.user))")
            .font(.title2.weight(.bold))
          Text(DateFormatters.humanDateTime.string(from: Date()))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text("This week: \(dashboard.weekCans)")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(theme.primary)
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
          .background(theme.primary.opacity(0.09), in: Capsule())
      }

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 14) {
          IntakeRing(
            title: "Daily intake",
            value: Metrics.one(check.todayCans),
            unit: "cans",
            progress: ringProgress,
            tint: theme.primary,
            secondary: theme.secondary
          )

          VStack(spacing: 8) {
            HealthMetricPill(
              label: "Caffeine",
              value: dashboard.todayCaffeine,
              symbol: "waveform.path.ecg",
              tint: Color(hex: "#00897B")
            )
            HealthMetricPill(
              label: "Sugar",
              value: dashboard.todaySugar,
              symbol: "cube.transparent",
              tint: Color(hex: "#34A853")
            )
            HealthMetricPill(
              label: "Streak",
              value: "\(dashboard.currentStreak)d",
              symbol: "flame.fill",
              tint: Color(hex: "#5E5CE6")
            )
          }
        }

        VStack(spacing: 12) {
          IntakeRing(
            title: "Daily intake",
            value: Metrics.one(check.todayCans),
            unit: "cans",
            progress: ringProgress,
            tint: theme.primary,
            secondary: theme.secondary
          )
          VStack(spacing: 8) {
            HealthMetricPill(
              label: "Caffeine",
              value: dashboard.todayCaffeine,
              symbol: "waveform.path.ecg",
              tint: Color(hex: "#00897B")
            )
            HealthMetricPill(
              label: "Sugar",
              value: dashboard.todaySugar,
              symbol: "cube.transparent",
              tint: Color(hex: "#34A853")
            )
            HealthMetricPill(
              label: "Streak",
              value: "\(dashboard.currentStreak)d",
              symbol: "flame.fill",
              tint: Color(hex: "#5E5CE6")
            )
          }
        }
      }

      HStack(spacing: 12) {
        HealthActionButton(label: "Add", symbol: "plus", tint: theme.primary, filled: true, action: onAdd)
        HealthActionButton(label: "Scan", symbol: "barcode.viewfinder", tint: theme.primary, action: onScan)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 6)
  }

  private var ringProgress: Double {
    let today = store.limitCheck.todayCans
    if let limit = store.userLimits.dailyCanLimit, limit > 0 {
      return min(1, today / limit)
    }
    return min(1, today / 3)
  }
}

struct IntakeRing: View {
  var title: String
  var value: String
  var unit: String
  var progress: Double
  var tint: Color
  var secondary: Color

  var body: some View {
    ZStack {
      Circle()
        .stroke(Color(.systemGray5), lineWidth: 16)

      Circle()
        .trim(from: 0, to: max(0.04, min(progress, 1)))
        .stroke(tint, style: StrokeStyle(lineWidth: 16, lineCap: .round))
        .rotationEffect(.degrees(-90))

      VStack(spacing: 4) {
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(value)
          .font(.system(size: 34, weight: .bold))
          .minimumScaleFactor(0.75)
        Text(unit)
          .font(.caption.weight(.semibold))
          .foregroundStyle(tint)
      }
      .padding(18)
    }
    .frame(width: 132, height: 132)
  }
}

struct HealthMetricPill: View {
  var label: String
  var value: String
  var symbol: String
  var tint: Color

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.subheadline.weight(.bold))
        .foregroundStyle(tint)
        .frame(width: 32, height: 32)
        .background(tint.opacity(0.10), in: Circle())

      VStack(alignment: .leading, spacing: 2) {
        Text(label)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(value)
          .font(.headline.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .minimumScaleFactor(0.72)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, minHeight: 48)
    .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

struct HealthActionButton: View {
  var label: String
  var symbol: String
  var tint: Color
  var filled = false
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(label, systemImage: symbol)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(filled ? .white : tint)
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .background(filled ? tint : tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(filled ? Color.clear : tint.opacity(0.16), lineWidth: 1)
        }
    }
    .buttonStyle(GentleHapticPlainButtonStyle())
  }
}

struct TodayStat: View {
  var label: String
  var value: String
  var symbol: String

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Image(systemName: symbol)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemGroupedBackground).opacity(0.62), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }
}

struct QuickAddCarousel: View {
  @EnvironmentObject private var store: AppStore

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Quick add")
          .font(.title3.weight(.bold))
        Spacer()
        Text("Tap to log")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          ForEach(quickAdds) { item in
            let accent = Color(hex: flavourDetails(item.flavour).accent)
            Button {
              store.quickAdd(item)
            } label: {
              VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "bolt.fill")
                  .font(.subheadline.weight(.bold))
                  .foregroundStyle(accent)
                  .frame(width: 30, height: 30)
                  .background(accent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                  Text(item.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                  Text("\(item.sizeMl)ml")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              .padding(12)
              .frame(width: 128, height: 106, alignment: .leading)
              .flatSurface(radius: 18, tint: accent)
            }
            .buttonStyle(GentleHapticPlainButtonStyle())
          }
        }
        .padding(.vertical, 1)
      }
    }
  }
}

struct TodayLimitsPanel: View {
  @EnvironmentObject private var store: AppStore
  var onOpenSettings: () -> Void

  var body: some View {
    let limits = store.userLimits
    let check = store.limitCheck

    GlassSection(
      title: "Daily Limits",
      subtitle: limits.hasAnyLimit ? "BST totals" : "No limits set",
      symbol: "target",
      tint: store.activeTheme.secondary
    ) {
      if !limits.hasAnyLimit {
        Button("Set limits", systemImage: "slider.horizontal.3", action: onOpenSettings)
          .glassButton()
      } else {
        VStack(spacing: 14) {
          if let dailyCanLimit = limits.dailyCanLimit {
            LimitProgressRow(
              label: "Cans",
              value: "\(Metrics.one(check.todayCans)) / \(Metrics.one(dailyCanLimit))",
              progress: Limits.progress(current: check.todayCans, limit: dailyCanLimit),
              isOver: check.violations.contains(.cans)
            )
          }
          if let dailySpendLimit = limits.dailySpendLimit {
            LimitProgressRow(
              label: "Spend",
              value: "\(Metrics.money(check.todaySpend)) / \(Metrics.money(dailySpendLimit))",
              progress: Limits.progress(current: check.todaySpend, limit: dailySpendLimit),
              isOver: check.violations.contains(.spend)
            )
          }
          if let stopTime = limits.stopTime {
            Label(check.pastStopTime ? "Past \(Limits.stopTimeLabel(stopTime))" : "Stop by \(Limits.stopTimeLabel(stopTime))", systemImage: "clock")
              .font(.subheadline.weight(.medium))
              .foregroundStyle(check.pastStopTime ? .red : .secondary)
          }
        }
      }
    }
  }
}

struct MetricCarousel: View {
  @EnvironmentObject private var store: AppStore

  var body: some View {
    let dashboard = store.dashboard
    let theme = store.activeTheme

    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 12) {
        MetricTile(label: "This month", value: dashboard.monthCans, detail: dashboard.monthSpend, symbol: "calendar", color: theme.primary)
        MetricTile(label: "All-time spend", value: dashboard.totalSpend, detail: "\(store.entries.count) entries", symbol: "sterlingsign.circle.fill", color: theme.secondary)
        MetricTile(label: "Favourite", value: dashboard.favouriteFlavour, detail: "by cans", symbol: "heart.fill", color: Color(hex: "#6D5D7A"))
        MetricTile(label: "Days without", value: dashboard.daysWithoutRedBull, detail: "\(dashboard.currentStreak) day streak", symbol: "timer", color: Color(hex: "#7A5D00"))
      }
      .padding(.vertical, 2)
    }
  }
}

struct RecentEntriesPanel: View {
  @EnvironmentObject private var store: AppStore
  var onAdd: () -> Void
  var onOpenLogbook: () -> Void

  var body: some View {
    let recentEntries = store.recentEntries

    GlassSection(title: "Recent", subtitle: "\(recentEntries.count) latest", symbol: "clock.arrow.circlepath", tint: store.activeTheme.primary) {
      if recentEntries.isEmpty {
        EmptyStateView(title: "Nothing logged", copy: "Your newest entries will appear here.", actionLabel: "Add intake", action: onAdd)
      } else {
        VStack(spacing: 10) {
          ForEach(recentEntries) { entry in
            EntryRowView(entry: entry, onEdit: onOpenLogbook) {
              Task { await store.deleteEntry(entry) }
            }
          }

          Button("Open logbook", systemImage: "chevron.right", action: onOpenLogbook)
            .glassButton()
        }
      }
    }
  }
}

struct FlavourSpectrumPanel: View {
  @EnvironmentObject private var store: AppStore

  var body: some View {
    let flavourData = store.flavourData
    let maxValue = max(flavourData.first?.value ?? 1, 1)

    GlassSection(title: "Flavours", subtitle: "Cans by flavour", symbol: "swatchpalette", tint: .pink) {
      if flavourData.isEmpty {
        EmptyStateView(title: "No flavours yet", copy: "Flavour mix appears after your first entry.", systemImage: "swatchpalette")
      } else {
        VStack(spacing: 12) {
          ForEach(flavourData.prefix(6)) { point in
            VStack(spacing: 7) {
              HStack {
                Circle()
                  .fill(Color(hex: point.accent))
                  .frame(width: 10, height: 10)
                Text(point.name)
                  .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Metrics.one(point.value))")
                  .font(.subheadline.weight(.semibold))
              }
              ProgressView(value: point.value / maxValue)
                .tint(Color(hex: point.accent))
            }
          }
        }
      }
    }
  }
}

struct InsightStack: View {
  @EnvironmentObject private var store: AppStore

  var body: some View {
    let insights = Array(store.insights.prefix(3))
    let tint = store.activeTheme.primary

    if !insights.isEmpty {
      VStack(spacing: 10) {
        ForEach(insights) { insight in
          InsightCard(insight: insight, tint: tint)
        }
      }
    }
  }
}

struct InsightCard: View {
  var insight: Insight
  var tint: Color

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "sparkle.magnifyingglass")
        .font(.headline.weight(.semibold))
        .foregroundStyle(tint)
        .frame(width: 38, height: 38)
        .background(tint.opacity(0.10), in: Circle())
      VStack(alignment: .leading, spacing: 3) {
        Text(insight.label)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(insight.value)
          .font(.headline)
        Text(insight.detail)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer(minLength: 0)
    }
    .padding(16)
    .liquidGlass(radius: 22, tint: tint)
  }
}

struct LogbookView: View {
  @EnvironmentObject private var store: AppStore
  var onAdd: () -> Void
  var onEdit: (RedBullEntry) -> Void

  var body: some View {
    let entriesInView = store.entriesInView

    NavigationStack {
      List {
        if !store.syncError.isEmpty || !store.setupStatus.isOK || store.busyAction != nil {
          Section {
            StatusRail()
              .listRowInsets(EdgeInsets())
              .listRowBackground(Color.clear)
          }
        }

        Section {
          FiltersCard()
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowBackground(Color.clear)
        }

        Section {
          if entriesInView.isEmpty {
            EmptyStateView(title: "No entries found", copy: "Add an entry or clear the filters.", actionLabel: "Add intake", action: onAdd)
              .listRowBackground(Color.clear)
          } else {
            ForEach(entriesInView) { entry in
              EntryRowView(entry: entry, onEdit: { onEdit(entry) }) {
                Task { await store.deleteEntry(entry) }
              }
              .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
              .listRowSeparator(.hidden)
              .listRowBackground(Color.clear)
            }
          }
        } header: {
          Text("\(entriesInView.count) entries")
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .contentMargins(.horizontal, 20, for: .scrollContent)
      .liquidBackground(store.activeTheme)
      .navigationTitle("Logbook")
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("Log intake", systemImage: "plus", action: onAdd)
        }
      }
      .tint(store.activeTheme.primary)
      .refreshable {
        await store.refreshEntries()
      }
    }
  }
}

struct FiltersCard: View {
  @EnvironmentObject private var store: AppStore

  var body: some View {
    GlassSection(title: "Filters", symbol: "line.3.horizontal.decrease.circle", tint: store.activeTheme.secondary) {
      VStack(spacing: 14) {
        Picker("Flavour", selection: $store.filters.flavour) {
          Text("All flavours").tag("all")
          ForEach(store.allFlavours) { flavour in
            Text(flavour.name).tag(flavour.name)
          }
        }
        .pickerStyle(.menu)

        Picker("Date range", selection: $store.filters.dateRange) {
          ForEach(DateFilter.allCases) { filter in
            Text(filter.label).tag(filter)
          }
        }
        .pickerStyle(.segmented)

        if store.filters.dateRange == .custom {
          DatePicker("From", selection: $store.filters.from, displayedComponents: .date)
          DatePicker("To", selection: $store.filters.to, displayedComponents: .date)
        }

        TextField("Store or location", text: $store.filters.store)
          .textFieldStyle(.roundedBorder)

        Button("Clear filters", systemImage: "xmark") {
          store.filters = EntryFilters()
        }
        .glassButton()
      }
    }
  }
}

struct TrendsView: View {
  @EnvironmentObject private var store: AppStore
  @State private var projectionDays = 30

  var body: some View {
    let chartData = store.chartData
    let weekData = store.weekData
    let flavourData = store.flavourData
    let theme = store.activeTheme

    NavigationStack {
      ScrollView {
        LazyVStack(spacing: 18) {
          if !store.syncError.isEmpty || !store.setupStatus.isOK || store.busyAction != nil {
            StatusRail()
          }
          TrendsFilterBar()
          TrendsSummary()

          TrendChartCard(title: "Cans over time", subtitle: "How many you logged each day", symbol: "chart.bar.fill") {
            if chartData.isEmpty {
              EmptyStateView(title: "No daily pattern yet", copy: "Log an intake to start seeing your pattern.")
            } else {
              Chart(chartData) { point in
                BarMark(x: .value("Day", point.label), y: .value("Cans", point.cans))
                  .foregroundStyle(theme.primary)
              }
              .chartYAxisLabel("Cans")
              .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5))
              }
              .frame(height: 210)
            }
          }

          TrendChartCard(title: "Caffeine over time", subtitle: "Estimated amount on each logged day", symbol: "waveform.path.ecg") {
            if chartData.isEmpty {
              EmptyStateView(title: "No caffeine pattern yet", copy: "Caffeine estimates appear after you log an intake.")
            } else {
              Chart(chartData) { point in
                BarMark(x: .value("Day", point.label), y: .value("Caffeine", point.caffeine))
                  .foregroundStyle(theme.secondary)
              }
              .chartYAxisLabel("mg")
              .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5))
              }
              .frame(height: 210)
            }
          }

          TrendChartCard(title: "Weekly spending", subtitle: "What you spent each week", symbol: "sterlingsign.circle") {
            if weekData.isEmpty {
              EmptyStateView(title: "No weekly spending yet", copy: "A weekly view appears as your history grows.")
            } else {
              Chart(weekData) { point in
                BarMark(x: .value("Week", point.label), y: .value("Spend", point.spend))
                  .foregroundStyle(theme.primary)
              }
              .chartYAxisLabel("Spend")
              .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4))
              }
              .frame(height: 210)
            }
          }

          TrendChartCard(
            title: store.filters.flavour == "all" ? "Flavours logged" : "Flavours in this view",
            subtitle: flavourChartSubtitle,
            symbol: "swatchpalette"
          ) {
            if flavourData.isEmpty {
              EmptyStateView(
                title: "No flavours in this view",
                copy: "Try widening your filters or log another intake."
              )
            } else {
              Chart(flavourData.prefix(6)) { point in
                BarMark(x: .value("Cans", point.value), y: .value("Flavour", point.name))
                  .foregroundStyle(Color(hex: point.accent))
              }
              .chartXAxisLabel("Cans")
              .frame(height: 230)
            }
          }

          SpendForecastCard(projectionDays: $projectionDays)
          InsightStack()
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 28)
      }
      .liquidBackground(store.activeTheme)
      .navigationTitle("Trends")
      .refreshable {
        await store.refreshEntries()
      }
    }
  }

  private var flavourChartSubtitle: String {
    if store.filters.flavour != "all" {
      return "Counts for the flavour filter you have selected"
    }
    return "Most logged first in the current date range"
  }
}

struct TrendsFilterBar: View {
  @EnvironmentObject private var store: AppStore

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        Menu {
          ForEach(DateFilter.allCases) { filter in
            Button(filter.label) {
              store.filters.dateRange = filter
            }
          }
        } label: {
          Label(store.filters.dateRange.label, systemImage: "calendar")
            .font(.subheadline.weight(.medium))
        }

        Menu {
          Button("All flavours") {
            store.filters.flavour = "all"
          }
          ForEach(store.allFlavours) { flavour in
            Button(flavour.name) {
              store.filters.flavour = flavour.name
            }
          }
        } label: {
          Label(
            store.filters.flavour == "all" ? "All flavours" : store.filters.flavour,
            systemImage: "swatchpalette"
          )
          .font(.subheadline.weight(.medium))
          .lineLimit(1)
        }

        Spacer(minLength: 0)
      }
      .foregroundStyle(store.activeTheme.primary)

      if store.filters.dateRange == .custom {
        HStack {
          DatePicker("From", selection: $store.filters.from, displayedComponents: .date)
          DatePicker("To", selection: $store.filters.to, displayedComponents: .date)
        }
        .font(.caption)
      }
    }
  }
}

struct TrendsSummary: View {
  @EnvironmentObject private var store: AppStore

  var body: some View {
    let theme = store.activeTheme
    let totalCans = store.chartData.reduce(0) { $0 + $1.cans }
    let totalSpend = store.chartData.reduce(0) { $0 + $1.spend }
    let favourite = store.favouriteFlavourOverall
    let filteredFlavour = store.filters.flavour
    let hasFlavourFilter = filteredFlavour != "all"

    VStack(alignment: .leading, spacing: 16) {
      Text("Your trends")
        .font(.title2.weight(.bold))

      if store.chartData.isEmpty {
        Text("Log an intake to start building a readable picture of your habits.")
          .font(.body)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 12) {
          TrendsBulletRow {
            Text("In this view you logged ")
            + Text(Metrics.one(totalCans)).fontWeight(.semibold).foregroundStyle(theme.primary)
            + Text(" cans across ")
            + Text("\(store.chartData.count)").fontWeight(.semibold).foregroundStyle(theme.primary)
            + Text(store.chartData.count == 1 ? " day." : " days.")
          }

          TrendsBulletRow {
            Text("That comes to ")
            + Text(Metrics.money(totalSpend)).fontWeight(.semibold).foregroundStyle(theme.primary)
            + Text(" spent in the selected range.")
          }

          if hasFlavourFilter {
            TrendsBulletRow {
              Text("You are only looking at ")
              + Text(filteredFlavour).fontWeight(.semibold).foregroundStyle(theme.primary)
              + Text(" entries here, not your full history.")
            }
          }

          if let leadingInView = store.flavourData.first?.name, store.flavourData.count > 1 || !hasFlavourFilter {
            TrendsBulletRow {
              Text("Most logged in this view: ")
              + Text(leadingInView).fontWeight(.semibold).foregroundStyle(theme.primary)
              + Text(".")
            }
          }

          TrendsBulletRow {
            Text("All-time favourite across every entry: ")
            + Text(favourite).fontWeight(.semibold).foregroundStyle(theme.primary)
            + Text(".")
          }

          if !store.filters.store.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            TrendsBulletRow {
              Text("Store filter: ")
              + Text(store.filters.store).fontWeight(.semibold).foregroundStyle(theme.primary)
              + Text(".")
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct TrendsBulletRow: View {
  @ViewBuilder var content: Text

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Text("•")
        .font(.body)
        .foregroundStyle(.secondary)
        .padding(.top, 1)
      content
        .font(.body)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct TrendChartCard<Content: View>: View {
  @EnvironmentObject private var store: AppStore
  var title: String
  var subtitle: String
  var symbol: String
  @ViewBuilder var content: Content

  var body: some View {
    GlassSection(title: title, subtitle: subtitle, symbol: symbol, tint: store.activeTheme.primary) {
      content
    }
  }
}

struct SpendForecastCard: View {
  @EnvironmentObject private var store: AppStore
  @Binding var projectionDays: Int

  var body: some View {
    let forecast = Metrics.spendForecast(entries: store.entries, limits: store.userLimits, projectionDays: projectionDays)

    GlassSection(title: "What you may spend", subtitle: forecastSubtitle(forecast), symbol: "sterlingsign.arrow.circlepath", tint: .green) {
      if !forecast.hasData {
        EmptyStateView(title: "No spending estimate yet", copy: "Log an intake to see an estimate.")
      } else {
        VStack(spacing: 16) {
          Picker("Time ahead", selection: $projectionDays) {
            Text("Week").tag(7)
            Text("Month").tag(30)
            Text("3 months").tag(90)
            Text("Year").tag(365)
          }
          .pickerStyle(.segmented)

          HStack(spacing: 10) {
            ForecastStat(label: "At your current pace", value: Metrics.money(forecast.projectedSpend), note: "about \(Metrics.one(forecast.projectedCans)) cans")
            ForecastStat(label: "With 20% less", value: Metrics.money(forecast.projectedSpend * 0.8), note: "about \(Metrics.one(forecast.projectedCans * 0.8)) cans")
          }

          Button("Set a 20% lower daily limit", systemImage: "target") {
            Task {
              var limits = store.userLimits
              limits.dailyCanLimit = Double(max(1, Int(ceil(forecast.avgDailyCans * 0.8))))
              limits.dailySpendLimit = Limits.recommendedSpendLimit(
                forCanLimit: limits.dailyCanLimit,
                sizeMl: limits.dailyLimitCanSizeMl
              )
              await store.saveUserLimits(limits)
            }
          }
          .glassButton()
        }
      }
    }
  }

  private func forecastSubtitle(_ forecast: SpendForecast) -> String {
    forecast.hasData
      ? "Based on your average of \(Metrics.money(forecast.avgDailySpend)) per day"
      : "Based on your recent entries"
  }
}

struct ForecastStat: View {
  var label: String
  var value: String
  var note: String

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.headline)
        .lineLimit(1)
        .minimumScaleFactor(0.72)
      Text(note)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemGroupedBackground).opacity(0.62), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }
}

struct SettingsView: View {
  @EnvironmentObject private var store: AppStore
  var onExportJSON: () -> Void
  var onImportJSON: () -> Void
  var onReset: () -> Void

  var body: some View {
    NavigationStack {
      Form {
        if !store.syncError.isEmpty || !store.setupStatus.isOK || store.busyAction != nil {
          Section {
            StatusRail()
              .listRowBackground(Color.clear)
          }
        }

        Section("Daily Limits") {
          LimitsSettingsEditor()
        }

        Section("Appearance") {
          Text("Themes match Red Bull can editions.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        Section("Core") {
          ForEach(coreAppThemes) { theme in
            themePickerButton(theme)
          }
        }

        Section("Editions") {
          ForEach(editionAppThemes) { theme in
            themePickerButton(theme)
          }
        }

        Section {
          Button("Sync now", systemImage: "arrow.triangle.2.circlepath") {
            Task { await store.refreshEntries() }
          }
          Button("Export JSON", systemImage: "doc.badge.arrow.up", action: onExportJSON)
            .disabled(store.entries.isEmpty)
          Button("Import JSON", systemImage: "square.and.arrow.down", action: onImportJSON)
          Button("Delete all", systemImage: "trash", role: .destructive, action: onReset)
            .disabled(store.entries.isEmpty)
        } header: {
          Text("Data")
        } footer: {
          Text("\(store.entries.count) entries synced for this account.")
        }

        Section("Sync") {
          LabeledContent("Realtime") {
            Label(store.realtimeStatus, systemImage: store.realtimeConnected ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
              .foregroundStyle(store.realtimeConnected ? .green : .secondary)
          }
          Text("Changes from your other devices appear automatically while the app is open.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        Section("Account") {
          HStack(spacing: 12) {
            Text(displayInitial(store.user))
              .font(.headline.weight(.bold))
              .foregroundStyle(.white)
              .frame(width: 44, height: 44)
              .background(store.activeTheme.primary, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
              Text(accountDisplayName)
                .font(.headline)
              Text(store.user?.email ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
          }

          Button("Run setup again", systemImage: "sparkles") {
            store.setupOpen = true
          }

          Button("Log out", systemImage: "rectangle.portrait.and.arrow.right") {
            Task { await store.logout() }
          }
        }

      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .liquidBackground(store.activeTheme)
      .navigationTitle("Settings")
    }
  }

  private var accountDisplayName: String {
    guard let user = store.user else { return "Account" }
    return user.name.isEmpty ? "Account" : user.name
  }

  @ViewBuilder
  private func themePickerButton(_ theme: AppTheme) -> some View {
    Button {
      store.setThemeId(theme.id)
    } label: {
      ThemePickerRow(theme: theme, isSelected: knownThemeId(store.themeId) == theme.id)
    }
    .buttonStyle(.plain)
  }
}

struct LimitsSettingsEditor: View {
  @EnvironmentObject private var store: AppStore
  @State private var limitEnabled = true
  @State private var dailyCans = 2
  @State private var canSizeMl = 250
  @State private var stopInput = Date()
  @State private var stopEnabled = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Toggle("Daily can and spend limit", isOn: $limitEnabled)
      if limitEnabled {
        Stepper(value: $dailyCans, in: 1...10) {
          LabeledContent("Cans per day") {
            Text("\(dailyCans)")
              .fontWeight(.semibold)
          }
        }
        VStack(alignment: .leading, spacing: 8) {
          Text("Your can size")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Picker("Your can size", selection: $canSizeMl) {
            ForEach(Limits.standardLimitCanSizes, id: \.self) { size in
              Text("\(size)ml").tag(size)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
        }
        LabeledContent("Matched spend limit") {
          Text(Metrics.money(linkedSpendLimit))
            .fontWeight(.semibold)
        }
        Text("This allows \(dailyCans) x \(canSizeMl)ml \(dailyCans == 1 ? "can" : "cans") at the typical price, rounded up.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Toggle("Stop drinking by", isOn: $stopEnabled)
      if stopEnabled {
        DatePicker("Stop time", selection: $stopInput, displayedComponents: .hourAndMinute)
      }
      if store.userLimits.hasAnyLimit {
        LabeledContent("Today") {
          Text("\(Metrics.one(store.limitCheck.todayCans)) cans, \(Metrics.money(store.limitCheck.todaySpend))")
        }
      }
      Button("Save limits", systemImage: "target") {
        Task {
          var limits = UserLimits()
          if limitEnabled {
            limits.dailyCanLimit = Double(dailyCans)
            limits.dailyLimitCanSizeMl = canSizeMl
            limits.dailySpendLimit = linkedSpendLimit
          }
          if stopEnabled {
            limits.stopTime = DateFormatters.bstTime.string(from: stopInput)
          }
          await store.saveUserLimits(limits)
        }
      }
      .glassProminentButton()
      .frame(maxWidth: .infinity)
    }
    .onAppear(perform: loadSavedLimits)
    .onChange(of: store.userLimits) { _, _ in loadSavedLimits() }
  }

  private var linkedSpendLimit: Double {
    Limits.recommendedSpendLimit(forCanLimit: Double(dailyCans), sizeMl: canSizeMl) ?? 0
  }

  private func loadSavedLimits() {
    limitEnabled = store.userLimits.dailyCanLimit != nil
    dailyCans = Int(Limits.wholeCanLimit(store.userLimits.dailyCanLimit) ?? 2)
    canSizeMl = store.userLimits.dailyLimitCanSizeMl
    if let stop = store.userLimits.stopTime {
      stopEnabled = true
      // strings pretending to be dates. fucking brilliant
      let parts = stop.split(separator: ":").compactMap { Int(String($0)) }
      if parts.count == 2 {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = parts[0]
        components.minute = parts[1]
        stopInput = Calendar.current.date(from: components) ?? Date()
      }
    } else {
      stopEnabled = false
    }
  }
}
