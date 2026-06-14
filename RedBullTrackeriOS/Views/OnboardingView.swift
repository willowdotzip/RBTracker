import SwiftUI

struct OnboardingView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var step = 1
  @State private var dailyCanLimit: Double? = 2
  @State private var dailyLimitCanSizeMl = 250
  @State private var stopTime = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()
  @State private var stopEnabled = true
  @State private var selectedThemeId: String = defaultThemeId

  // six steps to tell an app how many redbulls you'll regret today
  private let stepCount = 6

  var body: some View {
    NavigationStack {
      VStack(spacing: 18) {
        VStack(spacing: 10) {
          HStack {
            Text("Setup")
              .font(.title2.weight(.semibold))
            Spacer()
            Text("\(step) of \(stepCount)")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
          }
          ProgressView(value: Double(step), total: Double(stepCount))
            .tint(themeForId(selectedThemeId).primary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)

        TabView(selection: $step) {
          welcomeStep.tag(1)
          themeStep.tag(2)
          canStep.tag(3)
          spendStep.tag(4)
          stopStep.tag(5)
          finishStep.tag(6)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))

        HStack {
          Button("Back", systemImage: "chevron.left") {
            step = max(1, step - 1)
          }
          .glassButton()
          .disabled(step == 1)

          Spacer()

          if step < stepCount {
            Button("Continue", systemImage: "chevron.right") {
              step = min(stepCount, step + 1)
            }
            .glassProminentButton()
          } else {
            Button("Save setup", systemImage: "checkmark") {
              Task {
                await store.saveOnboarding(limits: limits, onboardingThemeId: selectedThemeId)
                dismiss()
              }
            }
            .glassProminentButton()
            .disabled(store.busyAction == "save-onboarding")
          }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
      }
      .liquidBackground(themeForId(selectedThemeId))
      .navigationTitle("Welcome")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") {
            dismiss()
          }
        }
      }
      .onAppear {
        selectedThemeId = store.themeId
      }
    }
  }

  private var welcomeStep: some View {
    OnboardingPanel {
      Text("Hey \(displayFirstName(store.user)). Set your baseline.")
        .font(.system(size: 38, weight: .bold))
        .minimumScaleFactor(0.65)
      Text("Choose a colour and a simple daily plan. Your spending limit will stay matched to your can limit.")
        .font(.body)
        .foregroundStyle(.secondary)
    }
  }

  private var themeStep: some View {
    OnboardingPanel {
      Text("Choose your edition theme.")
        .font(.largeTitle.weight(.bold))
      ThemePickerList(selectedThemeId: selectedThemeId) { themeId in
        selectedThemeId = themeId
        store.setThemeId(themeId, sync: false)
      }
    }
  }

  private var canStep: some View {
    OnboardingPanel {
      Text("What is your daily can ceiling?")
        .font(.largeTitle.weight(.bold))
      Stepper(value: Binding(
        get: { dailyCanLimit ?? 0 },
        set: { dailyCanLimit = $0 <= 0 ? nil : $0 }
      ), in: 0...10, step: 1) {
        Text(dailyCanLimit.map { "\(Metrics.one($0)) cans per day" } ?? "No daily cap")
          .font(.title2.weight(.semibold))
      }
      Text("Can limits use whole cans, so the daily target is always clear.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 8) {
        Text("What size cans do you usually drink?")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Picker("Can size", selection: $dailyLimitCanSizeMl) {
          ForEach(Limits.standardLimitCanSizes, id: \.self) { size in
            Text("\(size)ml").tag(size)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
      Button(dailyCanLimit == nil ? "Use 2 cans" : "No daily cap") {
        dailyCanLimit = dailyCanLimit == nil ? 2 : nil
      }
      .glassButton()
    }
  }

  private var spendStep: some View {
    OnboardingPanel {
      Text("Your daily plan.")
        .font(.largeTitle.weight(.bold))
      if let dailyCanLimit, let linkedSpendLimit {
        Text("You've chosen \(Metrics.one(dailyCanLimit)) Red Bulls a day with a \(Metrics.money(linkedSpendLimit)) limit.")
          .font(.title2.weight(.semibold))
        VStack(alignment: .leading, spacing: 12) {
          coverageRow(size: 250)
          coverageRow(size: 355)
          coverageRow(size: 473)
        }
        .padding(.vertical, 8)
        Text("The spending limit is rounded up from the typical price of \(Metrics.one(dailyCanLimit)) x \(dailyLimitCanSizeMl)ml cans.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else {
        Text("You have not set a daily can or spending limit.")
          .font(.title2.weight(.semibold))
      }
    }
  }

  private var stopStep: some View {
    OnboardingPanel {
      Text("Pick a stop time.")
        .font(.largeTitle.weight(.bold))
      Toggle("Enable stop-time warning", isOn: $stopEnabled)
      if stopEnabled {
        DatePicker("Stop by", selection: $stopTime, displayedComponents: .hourAndMinute)
      }
      Text("Warnings use Europe/London time.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }

  private var finishStep: some View {
    OnboardingPanel {
      Text("Ready.")
        .font(.system(size: 52, weight: .bold))
      VStack(alignment: .leading, spacing: 8) {
        Label(dailyCanLimit.map { "\(Metrics.one($0)) cans/day" } ?? "No can cap", systemImage: "bolt.fill")
        Label(linkedSpendLimit.map { "\(Metrics.money($0))/day" } ?? "No spend cap", systemImage: "sterlingsign.circle.fill")
        Label(stopEnabled ? "Stop by \(DateFormatters.clock.string(from: stopTime))" : "No stop time", systemImage: "clock.fill")
        Label("\(themeForId(selectedThemeId).label) theme", systemImage: "paintpalette.fill")
      }
      .font(.headline)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var limits: UserLimits {
    var limits = UserLimits()
    limits.dailyCanLimit = dailyCanLimit
    limits.dailyLimitCanSizeMl = dailyLimitCanSizeMl
    limits.dailySpendLimit = linkedSpendLimit
    if stopEnabled {
      limits.stopTime = DateFormatters.bstTime.string(from: stopTime)
    }
    return limits
  }

  private var linkedSpendLimit: Double? {
    Limits.recommendedSpendLimit(forCanLimit: dailyCanLimit, sizeMl: dailyLimitCanSizeMl)
  }

  private func coverageRow(size: Int) -> some View {
    let price = Metrics.defaultPrice(for: size)
    let count = price > 0 ? Int((linkedSpendLimit ?? 0) / price) : 0
    return Label("\(Metrics.money(linkedSpendLimit ?? 0)) can get you \(count) x \(size)ml cans", systemImage: "checkmark.circle")
      .font(.headline)
      .foregroundStyle(themeForId(selectedThemeId).primary)
  }
}

struct OnboardingPanel<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        content
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 18)
      .frame(maxWidth: 560, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}
