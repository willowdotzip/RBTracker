import SwiftUI

struct AuthView: View {
  @EnvironmentObject private var store: AppStore
  @State private var mode: AuthMode = .login
  @State private var name = ""
  @State private var email = ""
  @State private var password = ""
  @FocusState private var focusedField: AuthField?

  var body: some View {
    ScrollView {
      VStack(spacing: 28) {
        AuthHeader()
          .padding(.top, 44)

        VStack(spacing: 18) {
          Picker("Mode", selection: $mode) {
            Text("Log in").tag(AuthMode.login)
            Text("Sign up").tag(AuthMode.signup)
          }
          .pickerStyle(.segmented)

          VStack(spacing: 12) {
            if mode == .signup {
              AuthInputRow(symbol: "person", placeholder: "Name") {
                TextField("Name", text: $name)
                  .textContentType(.name)
                  .textFieldStyle(.plain)
                  .focused($focusedField, equals: .name)
              }
            }

            AuthInputRow(symbol: "at", placeholder: "Email") {
              TextField("Email", text: $email)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .email)
            }

            AuthInputRow(symbol: "lock", placeholder: "Password") {
              SecureField("Password", text: $password)
                .textContentType(mode == .signup ? .newPassword : .password)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .password)
            }
          }

          if !store.authError.isEmpty {
            Label(store.authError, systemImage: "exclamationmark.circle.fill")
              .statusStyle(color: .red)
          } else if !store.setupStatus.isOK {
            Label(store.setupStatus.message, systemImage: "exclamationmark.triangle.fill")
              .statusStyle(color: .orange)
          }

          Button {
            focusedField = nil
            Task {
              if mode == .signup {
                await store.signup(name: name, email: email, password: password)
              } else {
                await store.login(email: email, password: password)
              }
            }
          } label: {
            HStack(spacing: 10) {
              if store.busyAction == "auth" {
                ProgressView()
              } else {
                Image(systemName: mode == .signup ? "person.badge.plus" : "person.crop.circle.badge.checkmark")
              }
              Text(mode == .signup ? "Create account" : "Log in")
                .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
          }
          .controlSize(.large)
          .glassProminentButton()
          // 8 chars minimum. security theater but at least it's something
          .disabled(store.busyAction == "auth" || email.isEmpty || password.count < 8)
        }
        .padding(18)
        .liquidGlass(radius: 32, tint: store.activeTheme.primary)

        LegalFootnote()
          .padding(.horizontal, 18)
      }
      .padding(.horizontal, 22)
      .padding(.bottom, 28)
    }
    .liquidBackground(store.activeTheme)
  }
}

private enum AuthField {
  case name
  case email
  case password
}

private struct AuthHeader: View {
  @EnvironmentObject private var store: AppStore

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "bolt.fill")
        .font(.system(size: 40, weight: .bold))
        .foregroundStyle(store.activeTheme.primary)
        .frame(width: 82, height: 82)
        .liquidGlass(radius: 30, tint: store.activeTheme.primary)

      VStack(spacing: 7) {
        Text("Red Bull Tracker")
          .font(.system(size: 38, weight: .bold))
          .multilineTextAlignment(.center)
          .minimumScaleFactor(0.75)
        Text("Track today. Sync everywhere.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct AuthInputRow<Content: View>: View {
  var symbol: String
  var placeholder: String
  @ViewBuilder var content: Content

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 28, height: 28)
        .background(.thinMaterial, in: Circle())
      content
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 13)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .accessibilityLabel(placeholder)
  }
}
