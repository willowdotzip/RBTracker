import Appwrite
import AppwriteModels
import Foundation
import JSONCodable
import Security

typealias AppwriteUser = AppwriteModels.User<[String: AnyCodable]>

struct AppConfig: Codable {
  var endpoint: String
  var projectId: String
  var databaseId: String
  var intakeTableId: String
  var barcodeTableId: String
  var chatTableId: String
  var coachProxyURL: String

  static func readFromBundle() -> AppConfig {
    guard let url = Bundle.main.url(forResource: "AppConfig", withExtension: "plist"),
          let data = try? Data(contentsOf: url),
          let config = try? PropertyListDecoder().decode(AppConfig.self, from: data)
    else {
      // plist missing? here's a config that definitely won't work. you're welcome
      return AppConfig(
        endpoint: "https://your-appwrite-endpoint/v1",
        projectId: "your-project-id",
        databaseId: "your-database-id",
        intakeTableId: "your-intake-table-id",
        barcodeTableId: "your-barcode-table-id",
        chatTableId: "your-chat-table-id",
        coachProxyURL: ""
      )
    }
    return config
  }
}

enum KeychainSessionStore {
  static let service = "com.example.rbtracker"
  static let account = "appwrite-session-secret"
  private static let fallbackDefaultsKey = "appwrite-session-secret"

  static func read() -> String? {
    #if targetEnvironment(simulator)
    // keychain on simulator? fuck that. userdefaults it is. ship it
    return UserDefaults.standard.string(forKey: fallbackDefaultsKey)
    #else
    return readFromKeychain()
    #endif
  }

  static func save(_ value: String) throws {
    #if targetEnvironment(simulator)
    UserDefaults.standard.set(value, forKey: fallbackDefaultsKey)
    #else
    try saveToKeychain(value)
    #endif
  }

  static func delete() throws {
    #if targetEnvironment(simulator)
    UserDefaults.standard.removeObject(forKey: fallbackDefaultsKey)
    #else
    try deleteFromKeychain()
    #endif
  }

  private static func readFromKeychain() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data,
          let value = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    return value
  }

  private static func saveToKeychain(_ value: String) throws {
    try deleteFromKeychain()
    let data = Data(value.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw keychainError(status)
    }
  }

  private static func deleteFromKeychain() throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw keychainError(status)
    }
  }

  private static func keychainError(_ status: OSStatus) -> NSError {
    NSError(
      domain: "KeychainSessionStore",
      code: Int(status),
      userInfo: [NSLocalizedDescriptionKey: "Keychain failed with status \(status)."]
    )
  }
}

final class AppwriteService {
  let config: AppConfig
  let client: Client
  let account: Account
  let tables: TablesDB
  let realtime: Realtime

  init(config: AppConfig = .readFromBundle()) {
    self.config = config
    let client = Client()
      .setEndpoint(config.endpoint)
      .setProject(config.projectId)
    if let credential = KeychainSessionStore.read(), !credential.isEmpty {
      Self.restoreCredential(credential, to: client)
    }
    self.client = client
    account = Account(client)
    tables = TablesDB(client)
    realtime = Realtime(client)
  }

  func ping() async throws -> String {
    try await client.ping()
  }

  func currentUser() async throws -> AppwriteUser {
    try await account.get()
  }

  func login(email: String, password: String) async throws -> AppwriteUser {
    try KeychainSessionStore.delete()
    forgetStoredCookies()
    try await openEmailSession(email: email, password: password)
    return try await account.get()
  }

  func signup(name: String, email: String, password: String) async throws -> AppwriteUser {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try await account.create(
      userId: ID.unique(),
      email: email,
      password: password,
      name: trimmedName.isEmpty ? nil : trimmedName
    )
    return try await login(email: email, password: password)
  }

  func logout() async throws {
    _ = try? await account.deleteSession(sessionId: "current")
    try KeychainSessionStore.delete()
    forgetStoredCookies()
    _ = client.setCookie("")
    _ = client.setSession("")
  }

  @discardableResult
  func updatePrefs(_ prefs: [String: Any]) async throws -> AppwriteUser {
    try await account.updatePrefs(prefs: prefs)
  }

  static func prefsDictionary(from user: AppwriteUser) -> [String: Any] {
    user.prefs.data.mapValues { unwrapAnyCodable($0) }
  }

  private func openEmailSession(email: String, password: String) async throws {
    // appwrite auth made this everyone's fucking problem
    let url = try endpointURL(path: "/account/sessions/email")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    client.getHeaders().forEach { key, value in
      request.setValue(value, forHTTPHeaderField: key)
    }
    request.setValue(config.projectId, forHTTPHeaderField: "X-Appwrite-Project")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "email": email,
      "password": password,
    ])

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw AppwriteAuthError.invalidResponse
    }

    guard (200..<400).contains(httpResponse.statusCode) else {
      throw AppwriteAuthError.server(message: Self.messageInResponse(from: data, fallback: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)))
    }

    let cookieHeader = cookieHeader(from: httpResponse, url: url)
    if !cookieHeader.isEmpty {
      try KeychainSessionStore.save("cookie:\(cookieHeader)")
      _ = client.setCookie(cookieHeader)
      rememberCookieHeader(cookieHeader)
      return
    }

    if let secret = Self.secretInResponse(from: data), !secret.isEmpty {
      try KeychainSessionStore.save("session:\(secret)")
      _ = client.setSession(secret)
      return
    }

    throw AppwriteAuthError.missingSessionCookie
  }

  private func endpointURL(path: String) throws -> URL {
    let base = config.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: base + path) else {
      throw AppwriteAuthError.invalidEndpoint
    }
    return url
  }

  private func cookieHeader(from response: HTTPURLResponse, url: URL) -> String {
    // cookie archaeology. dig through headers, storage, pray something matches
    let headerFields = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
      guard let key = pair.key as? String else { return }
      result[key] = String(describing: pair.value)
    }
    let responseCookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
    let storedCookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
    let projectSessionPrefix = "a_session_\(config.projectId)"

    var cookiesByName: [String: HTTPCookie] = [:]
    for cookie in responseCookies + storedCookies where cookie.name.hasPrefix(projectSessionPrefix) {
      cookiesByName[cookie.name] = cookie
    }

    return cookiesByName
      .sorted { $0.key < $1.key }
      .map { "\($0.value.name)=\($0.value.value)" }
      .joined(separator: "; ")
  }

  private func rememberCookieHeader(_ cookieHeader: String) {
    guard let domain = URL(string: config.endpoint)?.host else { return }
    UserDefaults.standard.set([cookieHeader], forKey: domain)
  }

  private func forgetStoredCookies() {
    guard let domain = URL(string: config.endpoint)?.host else { return }
    UserDefaults.standard.removeObject(forKey: domain)
    guard let url = URL(string: config.endpoint) else { return }
    let projectSessionPrefix = "a_session_\(config.projectId)"
    for cookie in HTTPCookieStorage.shared.cookies(for: url) ?? [] where cookie.name.hasPrefix(projectSessionPrefix) {
      HTTPCookieStorage.shared.deleteCookie(cookie)
    }
  }

  private static func restoreCredential(_ credential: String, to client: Client) {
    if credential.hasPrefix("cookie:") {
      _ = client.setCookie(String(credential.dropFirst("cookie:".count)))
    } else if credential.hasPrefix("session:") {
      _ = client.setSession(String(credential.dropFirst("session:".count)))
    } else {
      _ = client.setSession(credential)
    }
  }

  private static func secretInResponse(from data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any],
          let secret = dictionary["secret"] as? String
    else {
      return nil
    }
    return secret
  }

  private static func messageInResponse(from data: Data, fallback: String) -> String {
    guard let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any],
          let message = dictionary["message"] as? String,
          !message.isEmpty
    else {
      return fallback
    }
    return message
  }

  static func unwrapAnyCodable(_ value: Any) -> Any {
    // recursive unwrapping because appwrite nested codable hell never ends
    if let value = value as? AnyCodable {
      return unwrapAnyCodable(value.value)
    }
    if let dictionary = value as? [String: AnyCodable] {
      return dictionary.mapValues { unwrapAnyCodable($0) }
    }
    if let array = value as? [AnyCodable] {
      return array.map { unwrapAnyCodable($0) }
    }
    if value is Void {
      return NSNull()
    }
    return value
  }
}

enum AppwriteAuthError: LocalizedError {
  case invalidEndpoint
  case invalidResponse
  case missingSessionCookie
  case server(message: String)

  var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      return "The Appwrite endpoint in AppConfig.plist is not a valid URL."
    case .invalidResponse:
      return "Appwrite returned an invalid auth response."
    case .missingSessionCookie:
      return "Appwrite logged in but did not return a usable session cookie."
    case .server(let message):
      return message
    }
  }
}

struct IntakeEntryRow: Codable {
  var userId: String
  var cans: Double
  var flavour: String
  var flavourAccent: String
  var sizeMl: Int
  var pricePerCan: Double
  var dateTime: String
  var notes: String?
  var store: String?
  var sugarFree: Bool
  var caffeineMgPerCan: Double?
  var importKey: String
  var source: String
}

final class IntakeRepository {
  private let service: AppwriteService

  init(service: AppwriteService) {
    self.service = service
  }

  func listEntries(userId: String) async throws -> [RedBullEntry] {
    var rows: [AppwriteModels.Row<IntakeEntryRow>] = []
    let limit = 100
    var offset = 0

    // yes this keeps asking until the server gets bored or we run out of memory
    while true {
      let response = try await service.tables.listRows(
        databaseId: service.config.databaseId,
        tableId: service.config.intakeTableId,
        queries: [
          Query.equal("userId", value: userId),
          Query.orderDesc("dateTime"),
          Query.limit(limit),
          Query.offset(offset),
        ],
        nestedType: IntakeEntryRow.self
      )
      rows.append(contentsOf: response.rows)
      if response.rows.count < limit {
        break
      }
      offset += limit
    }

    return Metrics.sorted(rows.map(Self.entryFromRow))
  }

  func createEntry(userId: String, draft: EntryDraft) async throws -> RedBullEntry {
    let entry = Metrics.makeEntry(userId: userId, draft: draft)
    let row = try await service.tables.createRow(
      databaseId: service.config.databaseId,
      tableId: service.config.intakeTableId,
      rowId: ID.custom(entry.id),
      data: Self.entryRowData(entry),
      permissions: Self.ownerPermissions(userId),
      nestedType: IntakeEntryRow.self
    )
    return Self.entryFromRow(row)
  }

  func createEntries(userId: String, drafts: [EntryDraft]) async throws -> [RedBullEntry] {
    // n+1 network calls. what could possibly go wrong with 500 imports
    var saved: [RedBullEntry] = []
    for draft in drafts {
      saved.append(try await createEntry(userId: userId, draft: draft))
    }
    return saved
  }

  func updateEntry(userId: String, id: String, draft: EntryDraft) async throws -> RedBullEntry {
    let entry = Metrics.makeEntry(userId: userId, draft: draft, id: id)
    let row = try await service.tables.updateRow(
      databaseId: service.config.databaseId,
      tableId: service.config.intakeTableId,
      rowId: id,
      data: Self.entryRowData(entry),
      permissions: Self.ownerPermissions(userId),
      nestedType: IntakeEntryRow.self
    )
    return Self.entryFromRow(row)
  }

  func deleteEntry(id: String) async throws {
    _ = try await service.tables.deleteRow(
      databaseId: service.config.databaseId,
      tableId: service.config.intakeTableId,
      rowId: id
    )
  }

  private static func entryFromRow(_ row: AppwriteModels.Row<IntakeEntryRow>) -> RedBullEntry {
    let data = row.data
    return RedBullEntry(
      id: row.id,
      userId: data.userId,
      cans: data.cans,
      flavour: data.flavour,
      flavourAccent: data.flavourAccent,
      sizeMl: data.sizeMl,
      pricePerCan: data.pricePerCan,
      dateTime: data.dateTime,
      notes: data.notes ?? "",
      store: data.store ?? "",
      sugarFree: data.sugarFree,
      caffeineMgPerCan: data.caffeineMgPerCan,
      importKey: data.importKey,
      source: EntrySource(rawValue: data.source) ?? .manual,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt
    )
  }

  private static func entryRowData(_ entry: RedBullEntry) -> [String: Any] {
    var data: [String: Any] = [
      "userId": entry.userId,
      "cans": entry.cans,
      "flavour": entry.flavour,
      "flavourAccent": entry.flavourAccent,
      "sizeMl": entry.sizeMl,
      "pricePerCan": entry.pricePerCan,
      "dateTime": entry.dateTime,
      "notes": entry.notes,
      "store": entry.store,
      "sugarFree": entry.sugarFree,
      "importKey": entry.importKey,
      "source": entry.source.rawValue,
    ]
    if let caffeine = entry.caffeineMgPerCan {
      data["caffeineMgPerCan"] = caffeine
    }
    return data
  }

  private static func ownerPermissions(_ userId: String) -> [String] {
    let role = Role.user(userId)
    return [
      Permission.read(role),
      Permission.update(role),
      Permission.delete(role),
    ]
  }
}

struct BarcodeRow: Codable {
  var scope: String
  var ownerUserId: String?
  var barcode: String
  var flavourName: String
  var sizeMl: Int
  var pricePerCan: Double
  var sugarFree: Bool
  var caffeineMgPerCan: Double?
  var verifiedBy: String?
  var sourceName: String?
  var sourceUrl: String?
  var variant: String?
  var notes: String?
}

final class BarcodeRepository {
  private let service: AppwriteService

  init(service: AppwriteService) {
    self.service = service
  }

  func listCatalog(userId: String) async -> BarcodeLookupCatalog {
    var catalog = BarcodeLookupCatalog(
      verifiedProducts: Self.readBundledProducts(),
      userMappings: Self.readLocalMappings(userId: userId)
    )

    do {
      let cloud = try await listCloudCatalog()
      if !cloud.verifiedProducts.isEmpty {
        catalog.verifiedProducts = cloud.verifiedProducts
      }
      catalog.userMappings = mergeMappings(catalog.userMappings, cloud.userMappings)
    } catch {
      // cloud shat itself. pretend local storage was the plan all along
      return catalog
    }

    return catalog
  }

  func upsertUserMapping(userId: String, barcodeValue: String, product: BarcodeProductDraft) async -> UserBarcodeMapping {
    let barcode = BarcodeLookup.normalize(barcodeValue)
    do {
      let row = try await upsertCloudUserMapping(userId: userId, barcode: barcode, product: product)
      Self.saveLocalMapping(userId: userId, mapping: row)
      return row
    } catch {
      return Self.saveLocalMapping(userId: userId, barcode: barcode, product: product)
    }
  }

  private func listCloudCatalog() async throws -> BarcodeLookupCatalog {
    var verified: [String: BarcodeSeedProduct] = [:]
    var userMappings: [UserBarcodeMapping] = []
    let limit = 200
    var offset = 0

    while true {
      let response = try await service.tables.listRows(
        databaseId: service.config.databaseId,
        tableId: service.config.barcodeTableId,
        queries: [
          Query.orderAsc("barcode"),
          Query.limit(limit),
          Query.offset(offset),
        ],
        nestedType: BarcodeRow.self
      )

      response.rows.forEach { row in
        if row.data.scope == "verified" {
          verified[row.data.barcode] = Self.seedProduct(from: row.data)
        } else {
          userMappings.append(Self.mappingFromRow(from: row))
        }
      }

      if response.rows.count < limit {
        break
      }
      offset += limit
    }

    return BarcodeLookupCatalog(verifiedProducts: verified, userMappings: userMappings)
  }

  private func upsertCloudUserMapping(userId: String, barcode: String, product: BarcodeProductDraft) async throws -> UserBarcodeMapping {
    let existing = try await findUserBarcodeRow(userId: userId, barcode: barcode)
    let data = Self.mappingRowData(userId: userId, barcode: barcode, product: product)

    if let existing {
      let row = try await service.tables.updateRow(
        databaseId: service.config.databaseId,
        tableId: service.config.barcodeTableId,
        rowId: existing.id,
        data: data,
        permissions: Self.ownerPermissions(userId),
        nestedType: BarcodeRow.self
      )
      return Self.mappingFromRow(from: row)
    }

    let row = try await service.tables.createRow(
      databaseId: service.config.databaseId,
      tableId: service.config.barcodeTableId,
      rowId: ID.unique(),
      data: data,
      permissions: Self.ownerPermissions(userId),
      nestedType: BarcodeRow.self
    )
    return Self.mappingFromRow(from: row)
  }

  private func findUserBarcodeRow(userId: String, barcode: String) async throws -> AppwriteModels.Row<BarcodeRow>? {
    let response = try await service.tables.listRows(
      databaseId: service.config.databaseId,
      tableId: service.config.barcodeTableId,
      queries: [
        Query.equal("scope", value: "user"),
        Query.equal("ownerUserId", value: userId),
        Query.equal("barcode", value: barcode),
        Query.limit(1),
      ],
      nestedType: BarcodeRow.self
    )
    return response.rows.first
  }

  private static func readBundledProducts() -> [String: BarcodeSeedProduct] {
    let candidates = [
      Bundle.main.url(forResource: "verified-barcodes", withExtension: "json"),
      Bundle.main.url(forResource: "verified-barcodes", withExtension: "json", subdirectory: "Data"),
    ]
    guard let url = candidates.compactMap({ $0 }).first,
          let data = try? Data(contentsOf: url),
          let decoded = try? JSONDecoder().decode([String: BarcodeSeedProduct].self, from: data)
    else {
      return [:]
    }
    return decoded
  }

  private static func seedProduct(from row: BarcodeRow) -> BarcodeSeedProduct {
    BarcodeSeedProduct(
      flavourName: row.flavourName,
      sizeMl: row.sizeMl,
      pricePerCan: row.pricePerCan,
      sugarFree: row.sugarFree,
      caffeineMgPerCan: row.caffeineMgPerCan,
      verifiedBy: row.verifiedBy ?? "Verified source",
      sourceName: row.sourceName,
      sourceUrl: row.sourceUrl,
      notes: row.notes,
      variant: row.variant
    )
  }

  private static func mappingFromRow(from row: AppwriteModels.Row<BarcodeRow>) -> UserBarcodeMapping {
    UserBarcodeMapping(
      barcode: row.data.barcode,
      flavourName: row.data.flavourName,
      sizeMl: row.data.sizeMl,
      pricePerCan: row.data.pricePerCan,
      sugarFree: row.data.sugarFree,
      caffeineMgPerCan: row.data.caffeineMgPerCan,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt
    )
  }

  private static func mappingRowData(userId: String, barcode: String, product: BarcodeProductDraft) -> [String: Any] {
    var data: [String: Any] = [
      "scope": "user",
      "ownerUserId": userId,
      "barcode": barcode,
      "flavourName": product.flavourName,
      "sizeMl": product.sizeMl,
      "pricePerCan": product.pricePerCan,
      "sugarFree": product.sugarFree ?? false,
      "verifiedBy": "User saved mapping",
      "sourceName": "",
      "sourceUrl": "",
      "variant": "user",
      "notes": "",
    ]
    if let caffeine = product.caffeineMgPerCan {
      data["caffeineMgPerCan"] = caffeine
    }
    return data
  }

  private static func ownerPermissions(_ userId: String) -> [String] {
    let role = Role.user(userId)
    return [
      Permission.read(role),
      Permission.update(role),
      Permission.delete(role),
    ]
  }

  private static func localMappingsKey(userId: String) -> String {
    "red-bull-barcode-mappings:v1:\(userId)"
  }

  private static func readLocalMappings(userId: String) -> [UserBarcodeMapping] {
    guard let data = UserDefaults.standard.data(forKey: localMappingsKey(userId: userId)),
          let decoded = try? JSONDecoder().decode([UserBarcodeMapping].self, from: data)
    else {
      return []
    }
    return decoded
  }

  private static func writeLocalMappings(userId: String, mappings: [UserBarcodeMapping]) {
    if let data = try? JSONEncoder().encode(mappings) {
      UserDefaults.standard.set(data, forKey: localMappingsKey(userId: userId))
    }
  }

  @discardableResult
  private static func saveLocalMapping(userId: String, barcode: String, product: BarcodeProductDraft) -> UserBarcodeMapping {
    let now = DateCodec.isoString(from: Date())
    let existing = readLocalMappings(userId: userId).first(where: { $0.barcode == barcode })
    let mapping = UserBarcodeMapping(
      barcode: barcode,
      flavourName: product.flavourName,
      sizeMl: product.sizeMl,
      pricePerCan: product.pricePerCan,
      sugarFree: product.sugarFree,
      caffeineMgPerCan: product.caffeineMgPerCan,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now
    )
    saveLocalMapping(userId: userId, mapping: mapping)
    return mapping
  }

  private static func saveLocalMapping(userId: String, mapping: UserBarcodeMapping) {
    let existing = readLocalMappings(userId: userId)
    let next = existing.contains(where: { $0.barcode == mapping.barcode })
      ? existing.map { $0.barcode == mapping.barcode ? mapping : $0 }
      : existing + [mapping]
    writeLocalMappings(userId: userId, mappings: next)
  }

  private func mergeMappings(_ left: [UserBarcodeMapping], _ right: [UserBarcodeMapping]) -> [UserBarcodeMapping] {
    var byBarcode: [String: UserBarcodeMapping] = [:]
    (left + right).forEach { mapping in
      byBarcode[mapping.barcode] = mapping
    }
    return byBarcode.values.sorted { $0.barcode < $1.barcode }
  }
}

func appwriteErrorMessage(_ error: Error) -> String {
  if let appwriteError = error as? AppwriteError {
    let message = appwriteError.message
    // regex because appwrite errors are vibes not documentation
    if message.range(of: #"permissions?.*create|action 'create'|create.*permissions?"#, options: [.regularExpression, .caseInsensitive]) != nil {
      return "Appwrite table permissions need Users -> Create, with row security enabled on the intake table."
    }
    if message.range(of: #"not authorized|401|unauthorized"#, options: [.regularExpression, .caseInsensitive]) != nil {
      return "Appwrite denied the table request. Enable row security and per-user row permissions."
    }
    return message
  }
  return error.localizedDescription
}
