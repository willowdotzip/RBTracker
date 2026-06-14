import SwiftUI

struct EntryEditorView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  var sheet: EntrySheet
  var onSave: (EntryDraft) -> Void

  @State private var cans: String
  @State private var pricePerCan: String
  @State private var selectedFlavour: String
  @State private var customFlavour: String
  @State private var customAccent: String
  @State private var sizePreset: String
  @State private var customSize: String
  @State private var caffeineOverride: String
  @State private var date: Date
  @State private var storeName: String
  @State private var notes: String
  @State private var sugarFree: Bool

  init(sheet: EntrySheet, onSave: @escaping (EntryDraft) -> Void) {
    self.sheet = sheet
    self.onSave = onSave
    // twelve @State vars because swiftui hates simple forms
    let draft = sheet.draft
    let isCustomFlavour = !builtInFlavours.contains(where: { $0.name == draft.flavour })
    _cans = State(initialValue: "\(max(1, Int(draft.cans.rounded(.toNearestOrAwayFromZero))))")
    _pricePerCan = State(initialValue: String(format: "%.2f", draft.pricePerCan))
    _selectedFlavour = State(initialValue: isCustomFlavour ? "Other" : draft.flavour)
    _customFlavour = State(initialValue: isCustomFlavour ? draft.flavour : "")
    _customAccent = State(initialValue: draft.flavourAccent.isEmpty ? "#b85d84" : draft.flavourAccent)
    _sizePreset = State(initialValue: Self.preset(for: draft.sizeMl))
    _customSize = State(initialValue: "\(draft.sizeMl)")
    _caffeineOverride = State(initialValue: draft.caffeineMgPerCan.map { Metrics.one($0) } ?? "")
    _date = State(initialValue: draft.date)
    _storeName = State(initialValue: draft.store)
    _notes = State(initialValue: draft.notes)
    _sugarFree = State(initialValue: draft.sugarFree)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("How many?") {
          Text("Log whole cans so your daily total stays easy to understand.")
            .font(.footnote)
            .foregroundStyle(.secondary)

          HStack(spacing: 16) {
            Button {
              nudgeCanCount(by: -1)
            } label: {
              Image(systemName: "minus")
            }
            .glassButton()
            .disabled(canCount <= 1)

            VStack(spacing: 2) {
              Text("\(canCount)")
                .font(.largeTitle.weight(.bold))
              Text(canCount == 1 ? "can" : "cans")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            Button {
              nudgeCanCount(by: 1)
            } label: {
              Image(systemName: "plus")
            }
            .glassButton()
            .disabled(canCount >= 20)
          }
        }

        Section("Drink") {
          Picker("Flavour", selection: $selectedFlavour) {
            ForEach(store.allFlavours) { flavour in
              Text(flavour.name).tag(flavour.name)
            }
          }
          .onChange(of: selectedFlavour) { _, newValue in
            guard newValue != "Other" else { return }
            let meta = flavourDetails(newValue)
            customAccent = meta.accent
            sugarFree = meta.sugarFree
          }

          if selectedFlavour == "Other" {
            TextField("Custom flavour", text: $customFlavour)
          }

          VStack(alignment: .leading, spacing: 8) {
            Text("Can size")
              .font(.subheadline)
              .foregroundStyle(.secondary)
            Picker("Can size", selection: $sizePreset) {
              Text("250").tag("250")
              Text("355").tag("355")
              Text("473").tag("473")
              Text("Other").tag("custom")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
          }
          .onChange(of: sizePreset) { _, newValue in
            guard newValue != "custom", let size = Int(newValue) else { return }
            customSize = newValue
            pricePerCan = String(format: "%.2f", Metrics.defaultPrice(for: size))
            caffeineOverride = ""
          }

          if sizePreset == "custom" {
            HStack {
              Text("Custom size")
              Spacer()
              TextField("250", text: $customSize)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 90)
              Text("ml")
                .foregroundStyle(.secondary)
            }
          }

          HStack {
            Text("Price per can")
            Spacer()
            Text("£")
              .foregroundStyle(.secondary)
            TextField("0.00", text: $pricePerCan)
              .keyboardType(.decimalPad)
              .multilineTextAlignment(.trailing)
              .frame(maxWidth: 90)
          }

          Toggle("Count as sugar-free / zero sugar", isOn: $sugarFree)

          DisclosureGroup("More drink details") {
            VStack(spacing: 12) {
              if selectedFlavour == "Other" {
                TextField("Colour hex", text: $customAccent)
                  .textInputAutocapitalization(.never)
              }
              HStack {
                Text("Caffeine per can")
                Spacer()
                TextField("Automatic", text: $caffeineOverride)
                  .keyboardType(.decimalPad)
                  .multilineTextAlignment(.trailing)
                  .frame(maxWidth: 100)
                Text("mg")
                  .foregroundStyle(.secondary)
              }
            }
            .padding(.top, 8)
          }
        }

        Section("When and where") {
          DatePicker("Date and time", selection: $date)
          TextField("Location or store", text: $storeName)
          TextField("Notes", text: $notes, axis: .vertical)
            .lineLimit(3...6)
        }

        Section("Summary") {
          LabeledContent("Amount") {
            Text("\(canCount) \(canCount == 1 ? "can" : "cans"), \(numericSize)ml")
              .fontWeight(.semibold)
          }
          LabeledContent("Caffeine per can") {
            Text("\(Metrics.whole(caffeinePreview))mg")
              .fontWeight(.semibold)
          }
          LabeledContent("Estimated spend") {
            Text(Metrics.money(Double(canCount) * (Double(pricePerCan) ?? 0)))
              .fontWeight(.semibold)
          }
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .liquidBackground(store.activeTheme)
      .navigationTitle(sheet.entry == nil ? "Add intake" : "Edit entry")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(sheet.entry == nil ? "Log" : "Save") {
            onSave(draftFromForm())
          }
          .disabled(!isValid)
        }
      }
    }
  }

  private var isValid: Bool {
    (Double(pricePerCan) ?? -1) >= 0 &&
      numericSize > 0 &&
      !finalFlavour.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var canCount: Int {
    min(20, max(1, Int(cans) ?? 1))
  }

  private var numericSize: Int {
    if sizePreset == "custom" {
      return max(1, Int(customSize) ?? 250)
    }
    return Int(sizePreset) ?? 250
  }

  private var finalFlavour: String {
    selectedFlavour == "Other" ? (customFlavour.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Other" : customFlavour) : selectedFlavour
  }

  private var caffeinePreview: Double {
    Metrics.caffeinePerCan(sizeMl: numericSize, override: Double(caffeineOverride))
  }

  private func draftFromForm() -> EntryDraft {
    let meta = flavourDetails(finalFlavour)
    var draft = EntryDraft()
    draft.cans = Double(canCount)
    draft.flavour = finalFlavour
    draft.flavourAccent = selectedFlavour == "Other" ? (customAccent.isEmpty ? customFlavourAccent(finalFlavour) : customAccent) : meta.accent
    draft.sizeMl = numericSize
    draft.pricePerCan = max(0, Double(pricePerCan) ?? 0)
    draft.date = date
    draft.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
    draft.store = storeName.trimmingCharacters(in: .whitespacesAndNewlines)
    draft.sugarFree = sugarFree || meta.sugarFree
    draft.caffeineMgPerCan = Double(caffeineOverride)
    draft.source = sheet.entry?.source ?? sheet.draft.source
    return draft
  }

  private func nudgeCanCount(by amount: Int) {
    cans = "\(min(20, max(1, canCount + amount)))"
  }

  private static func preset(for size: Int) -> String {
    [250, 355, 473].contains(size) ? "\(size)" : "custom"
  }
}
