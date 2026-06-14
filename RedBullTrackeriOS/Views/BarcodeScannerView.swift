import AVFoundation
import SwiftUI

enum BarcodePhase: Equatable {
  case scanning
  case found(String, ResolvedBarcodeProduct)
  case manual(String, String)
}

struct BarcodeScannerSheet: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  var onAddNow: (EntryDraft) -> Void
  var editBeforeAdding: (EntryDraft) -> Void

  @State private var catalog = BarcodeLookupCatalog()
  @State private var phase: BarcodePhase = .scanning
  @State private var typedBarcode = ""
  @State private var manualFlavour = defaultFlavour.name
  @State private var manualSize = "250"
  @State private var manualPrice = "1.75"
  @State private var manualSugarFree = false
  @State private var manualCaffeine = ""
  @State private var savingMapping = false
  @State private var message = "Point your camera at the barcode on the can."

  var body: some View {
    // camera permissions, avfoundation, manual fallback. all for one can of bull
    NavigationStack {
      ScrollView {
        VStack(spacing: 16) {
          cameraPanel
          manualEntryPanel
          resultPanel
        }
        .padding(20)
      }
      .navigationTitle("Scan barcode")
      .navigationBarTitleDisplayMode(.inline)
      .liquidBackground(store.activeTheme)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") {
            dismiss()
          }
        }
      }
      .task {
        catalog = await store.loadBarcodeCatalog()
      }
    }
  }

  private var cameraPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      BarcodeCameraView { code in
        lookUpBarcode(code)
      } onError: { errorMessage in
        message = errorMessage
      }
      .frame(height: 260)
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .stroke(Color.white.opacity(0.5), lineWidth: 1)
      )
    }
    .padding(18)
    .liquidGlass(radius: 28, tint: store.activeTheme.primary)
  }

  private var manualEntryPanel: some View {
    SectionCard(title: "Manual barcode", subtitle: "Use the number if the camera cannot read it") {
      HStack {
        TextField("EAN or UPC number", text: $typedBarcode)
          .keyboardType(.numberPad)
          .textFieldStyle(.roundedBorder)
        Button("Lookup") {
          lookUpBarcode(typedBarcode)
        }
        .glassButton()
      }
    }
  }

  @ViewBuilder
  private var resultPanel: some View {
    switch phase {
    case .scanning:
      EmptyView()
    case .found(let barcode, let product):
      SectionCard(title: "Product found", subtitle: barcode) {
        ProductPreview(product: product)
        HStack {
          Button("Edit first", systemImage: "pencil") {
            editBeforeAdding(BarcodeLookup.entryDraft(product: product, barcode: barcode))
          }
          .glassButton()
          Button("Add now", systemImage: "plus") {
            onAddNow(BarcodeLookup.entryDraft(product: product, barcode: barcode))
          }
          .glassProminentButton()
        }
      }
    case .manual(let barcode, let reason):
      SectionCard(title: "Map product", subtitle: reason) {
        VStack(spacing: 12) {
          Picker("Flavour", selection: $manualFlavour) {
            ForEach(builtInFlavours) { flavour in
              Text(flavour.name).tag(flavour.name)
            }
          }
          .pickerStyle(.menu)
          Picker("Size", selection: $manualSize) {
            Text("250ml").tag("250")
            Text("355ml").tag("355")
            Text("473ml").tag("473")
          }
          .pickerStyle(.segmented)
          TextField("Price per can", text: $manualPrice)
            .keyboardType(.decimalPad)
            .textFieldStyle(.roundedBorder)
          TextField("Caffeine mg/can (optional)", text: $manualCaffeine)
            .keyboardType(.decimalPad)
            .textFieldStyle(.roundedBorder)
          Toggle("Sugar-free / zero sugar", isOn: $manualSugarFree)

          HStack {
            Text("Estimated caffeine")
            Spacer()
            Text("\(Metrics.whole(BarcodeLookup.productCaffeineMg(manualProduct)))mg")
              .fontWeight(.semibold)
          }
          .font(.subheadline)

          Button {
            Task { await saveMappedProduct(barcode: barcode) }
          } label: {
            if savingMapping {
              ProgressView()
            } else {
              Label("Save mapping", systemImage: "tray.and.arrow.down")
            }
          }
          .glassProminentButton()
        }
      }
    }
  }

  private var manualProduct: BarcodeProductDraft {
    BarcodeProductDraft(
      flavourName: manualFlavour,
      sizeMl: Int(manualSize) ?? 250,
      pricePerCan: max(0, Double(manualPrice) ?? 0),
      sugarFree: manualSugarFree || flavourDetails(manualFlavour).sugarFree,
      caffeineMgPerCan: Double(manualCaffeine)
    )
  }

  private func lookUpBarcode(_ value: String) {
    let normalized = BarcodeLookup.normalize(value)
    guard !normalized.isEmpty else {
      message = "Enter a barcode number first."
      return
    }
    typedBarcode = normalized
    switch BarcodeLookup.lookup(normalized, catalog: catalog) {
    case .known(let barcode, let product), .user(let barcode, let product):
      message = "Barcode found."
      phase = .found(barcode, product)
    case .partial(let barcode, let draft, let reason):
      fillManualFields(draft)
      message = "Barcode found, but it needs a product mapping."
      phase = .manual(barcode, reason)
    case .unknown(let barcode):
      fillManualFields(nil)
      message = "Barcode found, but this product is not mapped yet."
      phase = .manual(barcode, "Add the drink details once and future scans can reuse them.")
    }
  }

  private func fillManualFields(_ draft: BarcodeProductDraft?) {
    manualFlavour = builtInFlavours.contains(where: { $0.name == draft?.flavourName }) ? draft?.flavourName ?? defaultFlavour.name : defaultFlavour.name
    let size = draft?.sizeMl ?? 250
    manualSize = [250, 355, 473].contains(size) ? "\(size)" : "250"
    manualPrice = String(format: "%.2f", draft?.pricePerCan ?? Metrics.defaultPrice(for: size))
    manualSugarFree = draft?.sugarFree ?? flavourDetails(manualFlavour).sugarFree
    manualCaffeine = draft?.caffeineMgPerCan.map { Metrics.one($0) } ?? ""
  }

  private func saveMappedProduct(barcode: String) async {
    savingMapping = true
    let mapping = await store.saveBarcodeMapping(barcode: barcode, product: manualProduct)
    if let mapping {
      catalog.userMappings = (catalog.userMappings.filter { $0.barcode != mapping.barcode } + [mapping]).sorted { $0.barcode < $1.barcode }
    }
    let resolved = BarcodeLookup.resolve(manualProduct, source: mapping == nil ? .builtIn : .user)
    phase = .found(barcode, resolved)
    message = mapping == nil ? "Saved locally for future scans." : "Saved to your account and cached locally."
    savingMapping = false
  }
}

struct ProductPreview: View {
  var product: ResolvedBarcodeProduct

  var body: some View {
    HStack(spacing: 12) {
      Circle()
        .fill(Color(hex: flavourDetails(product.flavourName).accent))
        .frame(width: 18, height: 18)
      VStack(alignment: .leading, spacing: 3) {
        Text(product.flavourName)
          .font(.headline)
        Text("\(product.sizeMl)ml, \(Metrics.money(product.pricePerCan)), \(Metrics.whole(Metrics.caffeinePerCan(sizeMl: product.sizeMl, override: product.caffeineMgPerCan)))mg caffeine")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if product.sugarFree {
        Text("zero")
          .font(.caption.weight(.bold))
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.green.opacity(0.15), in: Capsule())
      }
    }
    .padding(12)
    .background(Color(.secondarySystemGroupedBackground).opacity(0.62), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }
}

struct BarcodeCameraView: UIViewControllerRepresentable {
  var onCode: (String) -> Void
  var onError: (String) -> Void

  func makeUIViewController(context: Context) -> BarcodeCameraViewController {
    let controller = BarcodeCameraViewController()
    controller.onCode = onCode
    controller.onError = onError
    return controller
  }

  func updateUIViewController(_ uiViewController: BarcodeCameraViewController, context: Context) {}
}

final class BarcodeCameraViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
  var onCode: ((String) -> Void)?
  var onError: ((String) -> Void)?
  private let session = AVCaptureSession()
  private var previewLayer: AVCaptureVideoPreviewLayer?
  private var lastCode: String?
  private var lastCodeAt = Date.distantPast

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    askForCameraThenStart()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    previewLayer?.frame = view.bounds
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if !session.isRunning {
      DispatchQueue.global(qos: .userInitiated).async {
        self.session.startRunning()
      }
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    if session.isRunning {
      session.stopRunning()
    }
  }

  private func askForCameraThenStart() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      buildCaptureSession()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        DispatchQueue.main.async {
          granted ? self?.buildCaptureSession() : self?.onError?("Camera permission is needed to scan barcodes.")
        }
      }
    default:
      onError?("Camera permission is needed to scan barcodes.")
    }
  }

  private func buildCaptureSession() {
    guard let device = AVCaptureDevice.default(for: .video) else {
      onError?("No camera is available on this device.")
      return
    }

    do {
      let input = try AVCaptureDeviceInput(device: device)
      if session.canAddInput(input) {
        session.addInput(input)
      }

      let output = AVCaptureMetadataOutput()
      if session.canAddOutput(output) {
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        output.metadataObjectTypes = output.availableMetadataObjectTypes.filter {
          [.ean13, .ean8, .upce, .code128, .code39, .code93].contains($0)
        }
      }

      let layer = AVCaptureVideoPreviewLayer(session: session)
      layer.videoGravity = .resizeAspectFill
      layer.frame = view.bounds
      view.layer.insertSublayer(layer, at: 0)
      previewLayer = layer
    } catch {
      onError?(error.localizedDescription)
    }
  }

  func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
    guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
          let raw = object.stringValue
    else {
      return
    }

    let normalized = BarcodeLookup.normalize(raw)
    let now = Date()
    // scanners love shouting the same number. shut up already
    if normalized == lastCode, now.timeIntervalSince(lastCodeAt) < 1.5 {
      return
    }
    lastCode = normalized
    lastCodeAt = now
    onCode?(normalized)
  }
}
