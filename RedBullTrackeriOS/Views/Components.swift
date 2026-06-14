import SwiftUI

extension View {
  func materialCard(radius: CGFloat = 24) -> some View {
    liquidGlass(radius: radius)
  }

  func liquidGlass(radius: CGFloat = 24, tint: Color? = nil) -> some View {
    // this does absolutely fucking nothing
    self
  }

  func flatSurface(radius: CGFloat = 20, tint: Color? = nil) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    return self
      .background {
        shape.fill(Color(.secondarySystemGroupedBackground).opacity(0.82))
        if let tint {
          shape.fill(tint.opacity(0.055))
        }
      }
      .overlay(shape.stroke((tint ?? .primary).opacity(0.10), lineWidth: 1))
  }

  @ViewBuilder
  func liquidBackground(_ theme: AppTheme) -> some View {
    self
      .background {
        AppBackground(theme: theme)
      }
  }

  @ViewBuilder
  func glassButton() -> some View {
    self.buttonStyle(GentleHapticButtonStyle())
  }

  @ViewBuilder
  func glassProminentButton() -> some View {
    self.buttonStyle(GentleHapticButtonStyle(prominent: true))
  }
}

struct GentleHapticButtonStyle: ButtonStyle {
  var prominent = false
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(prominent ? Color.white : Color.accentColor)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(
        prominent ? Color.accentColor : Color(.tertiarySystemFill),
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .opacity(isEnabled ? (configuration.isPressed ? 0.76 : 1) : 0.42)
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
      .sensoryFeedback(.impact(weight: .light, intensity: 0.22), trigger: configuration.isPressed) { _, isPressed in
        isPressed
      }
  }
}

struct GentleHapticPlainButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(isEnabled ? (configuration.isPressed ? 0.68 : 1) : 0.42)
      .scaleEffect(configuration.isPressed ? 0.99 : 1)
      .sensoryFeedback(.impact(weight: .light, intensity: 0.22), trigger: configuration.isPressed) { _, isPressed in
        isPressed
      }
  }
}

struct AppBackground: View {
  var theme: AppTheme

  var body: some View {
    ZStack {
      Color(.systemGroupedBackground)
      RadialGradient(
        colors: [
          theme.background.opacity(0.12),
          Color.clear,
        ],
        center: .top,
        startRadius: 0,
        endRadius: 420
      )
    }
    .ignoresSafeArea()
  }
}

struct ThemePickerRow: View {
  var theme: AppTheme
  var isSelected: Bool

  var body: some View {
    HStack(spacing: 14) {
      Circle()
        .fill(theme.swatch)
        .frame(width: 32, height: 32)
        .overlay {
          Circle()
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }

      Text(theme.label)
        .font(.body.weight(.medium))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)

      Spacer(minLength: 8)

      if isSelected {
        Image(systemName: "checkmark.circle.fill")
          .font(.title3)
          .foregroundStyle(theme.primary)
      }
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }
}

struct ThemePickerList: View {
  var selectedThemeId: String
  var onSelect: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      themeRows(title: "Core", themes: coreAppThemes)
      themeRows(title: "Editions", themes: editionAppThemes)
    }
  }

  @ViewBuilder
  private func themeRows(title: String, themes: [AppTheme]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.leading, 2)

      VStack(spacing: 6) {
        ForEach(themes) { theme in
          Button {
            onSelect(theme.id)
          } label: {
            ThemePickerRow(theme: theme, isSelected: knownThemeId(selectedThemeId) == theme.id)
              .padding(.horizontal, 14)
              .padding(.vertical, 10)
              .background(
                knownThemeId(selectedThemeId) == theme.id
                  ? theme.primary.opacity(0.10)
                  : Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
              )
          }
          .buttonStyle(GentleHapticPlainButtonStyle())
        }
      }
    }
  }
}

struct GlassSection<Content: View>: View {
  var title: String
  var subtitle: String?
  var symbol: String?
  var tint: Color?
  @ViewBuilder var content: Content

  init(title: String, subtitle: String? = nil, symbol: String? = nil, tint: Color? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.subtitle = subtitle
    self.symbol = symbol
    self.tint = tint
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 12) {
        if let symbol {
          Image(systemName: symbol)
            .font(.headline.weight(.semibold))
            .foregroundStyle(tint ?? .primary)
            .frame(width: 30, height: 30)
            .background((tint ?? .primary).opacity(0.10), in: Circle())
        }
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.headline)
          if let subtitle {
            Text(subtitle)
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 0)
      }

      content
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .liquidGlass(radius: 22, tint: tint)
  }
}

struct SectionCard<Content: View>: View {
  var title: String
  var subtitle: String?
  @ViewBuilder var content: Content

  var body: some View {
    GlassSection(title: title, subtitle: subtitle, content: { content })
  }
}

struct MetricTile: View {
  var label: String
  var value: String
  var detail: String
  var symbol: String
  var color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Image(systemName: symbol)
        .font(.headline.weight(.semibold))
        .foregroundStyle(color)
        .frame(width: 34, height: 34)
        .background(color.opacity(0.10), in: Circle())

      VStack(alignment: .leading, spacing: 4) {
        Text(value)
          .font(.title3.weight(.semibold))
          .lineLimit(2)
          .minimumScaleFactor(0.72)
        Text(label)
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        Text(detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(16)
    .frame(width: 150, height: 136, alignment: .topLeading)
    .liquidGlass(radius: 18, tint: color)
  }
}

struct EmptyStateView: View {
  var title: String
  var copy: String
  var actionLabel: String?
  var systemImage: String = "bolt.fill"
  var action: (() -> Void)?

  init(title: String, copy: String, actionLabel: String? = nil, systemImage: String = "bolt.fill", action: (() -> Void)? = nil) {
    self.title = title
    self.copy = copy
    self.actionLabel = actionLabel
    self.systemImage = systemImage
    self.action = action
  }

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: systemImage)
        .font(.title3.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 48, height: 48)
        .background(.thinMaterial, in: Circle())
      VStack(spacing: 5) {
        Text(title)
          .font(.headline)
        Text(copy)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      if let actionLabel, let action {
        Button(actionLabel, systemImage: "plus", action: action)
          .glassButton()
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
  }
}

struct StatusRail: View {
  @EnvironmentObject private var store: AppStore

  var body: some View {
    VStack(spacing: 10) {
      if let busy = store.busyAction {
        StatusCapsule(text: "Working on \(busy.replacingOccurrences(of: "-", with: " "))", symbol: "arrow.triangle.2.circlepath", color: .blue)
      }
      if !store.syncError.isEmpty {
        StatusCapsule(text: store.syncError, symbol: "exclamationmark.triangle.fill", color: .red)
      }
      if !store.setupStatus.isOK {
        StatusCapsule(text: store.setupStatus.message, symbol: "exclamationmark.circle.fill", color: .orange)
      }
    }
  }
}

struct StatusCapsule: View {
  var text: String
  var symbol: String
  var color: Color

  var body: some View {
    Label(text, systemImage: symbol)
      .font(.footnote.weight(.medium))
      .foregroundStyle(color)
      .padding(.horizontal, 13)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(color.opacity(0.11), in: Capsule())
  }
}

extension View {
  func statusStyle(color: Color) -> some View {
    self
      .font(.footnote.weight(.medium))
      .foregroundStyle(color)
      .padding(.horizontal, 13)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

struct LimitProgressRow: View {
  var label: String
  var value: String
  var progress: Double
  var isOver: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(label)
          .font(.subheadline.weight(.medium))
        Spacer()
        Text(value)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(isOver ? .red : .primary)
      }
      ProgressView(value: progress)
        .tint(isOver ? .red : progress >= 0.75 ? .orange : .green)
    }
  }
}

struct EntryRowView: View {
  var entry: RedBullEntry
  var onEdit: () -> Void
  var onDelete: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(Color(hex: flavourAccent(for: entry)))
        .frame(width: 5)

      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(entry.flavour)
            .font(.headline)
          Text(entry.source.rawValue)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }

        if let date = DateCodec.date(from: entry.dateTime) {
          Text(DateFormatters.humanDateTime.string(from: date))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        HStack(spacing: 10) {
          Label("\(Metrics.one(entry.cans))", systemImage: "bolt.fill")
          Label(Metrics.money(Metrics.spend(for: entry)), systemImage: "sterlingsign")
          Label("\(Metrics.whole(Metrics.caffeine(for: entry)))mg", systemImage: "waveform.path.ecg")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)

        if !entry.store.isEmpty || !entry.notes.isEmpty {
          Text([entry.store, entry.notes].filter { !$0.isEmpty }.joined(separator: " . "))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }

      Spacer(minLength: 0)

      Menu {
        Button("Edit", systemImage: "pencil", action: onEdit)
        Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
      } label: {
        Image(systemName: "ellipsis")
          .font(.headline.weight(.semibold))
          .frame(width: 36, height: 36)
          .contentShape(Circle())
      }
      .glassButton()
    }
    .padding(14)
    .background(Color(.secondarySystemGroupedBackground).opacity(0.62), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
  }
}

struct LegalFootnote: View {
  var body: some View {
    Text("Your intake history stays synced to your account.")
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}
