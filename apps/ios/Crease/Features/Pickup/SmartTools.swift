import ARKit
import PhotosUI
import SwiftUI

/// Everything the on-device tools add to one booking, shared by the order
/// sheet and checkout so neither has to thread half a dozen bindings.
@MainActor
final class OrderExtras: ObservableObject {
    @Published var photos: [OrderPhoto] = []
    /// What care labels said, as notes for the shop.
    @Published var careNotes: [String] = []
    /// The claim ticket, for a Return only order.
    @Published var ticket: String = ""
    /// A time the customer named in "Describe your order", for checkout to adopt.
    @Published var requestedPickup: Date?
    /// The photo weight estimate the customer used, recorded on the order.
    @Published var weightEstimate: (pounds: Double, method: String)?

    var canAddPhoto: Bool { photos.count < OrderPhoto.maxPerOrder }

    func addHandoff(_ image: UIImage) {
        guard canAddPhoto else { return }
        photos.append(OrderPhoto(image: image, kind: .handoff))
    }

    func shopNote(returnOnly: Bool) -> String? {
        photos.shopNote(careNotes: careNotes, ticket: returnOnly ? ticket : nil)
    }
}

// MARK: - Getting an image

/// Camera where there is one, photo library otherwise, behind one button.
struct ImageSourceButton<Label: View>: View {
    let onImage: (UIImage) -> Void
    @ViewBuilder let label: () -> Label

    @State private var choosing = false
    @State private var usingCamera = false
    @State private var usingLibrary = false
    @State private var picked: PhotosPickerItem?

    private var hasCamera: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    var body: some View {
        Button {
            if hasCamera { choosing = true } else { usingLibrary = true }
        } label: { label() }
        .confirmationDialog("Add a photo", isPresented: $choosing) {
            Button("Take Photo") { usingCamera = true }
            Button("Choose from Library") { usingLibrary = true }
        }
        .fullScreenCover(isPresented: $usingCamera) {
            CameraPicker { image in
                usingCamera = false
                if let image { onImage(image) }
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $usingLibrary, selection: $picked, matching: .images)
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    onImage(image)
                }
                picked = nil
            }
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onDone: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onDone: (UIImage?) -> Void
        init(onDone: @escaping (UIImage?) -> Void) { self.onDone = onDone }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onDone(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onDone(nil) }
    }
}

// MARK: - Speaking a note

/// A microphone button that fills a text binding with what was said, then
/// (where Apple Intelligence is available) tidies it with `polish`.
struct DictateButton: View {
    @Binding var text: String
    var polish: ((String) async -> String?)? = nil

    @StateObject private var dictation = Dictation()
    @State private var polishing = false

    var body: some View {
        if Dictation.isSupported {
            Button {
                Task { await toggle() }
            } label: {
                Group {
                    if dictation.isPreparing || polishing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: dictation.isListening ? "stop.circle.fill" : "mic.fill")
                            .symbolEffect(.pulse, isActive: dictation.isListening)
                    }
                }
                .frame(width: 36, height: 36)
                .background(Color(.tertiarySystemFill), in: Circle())
            }
            .accessibilityLabel(dictation.isListening ? "Stop speaking" : "Speak your note")
            .onChange(of: dictation.transcript) { _, words in
                if dictation.isListening, !words.isEmpty { text = words }
            }
            .alert("Can't listen", isPresented: Binding(
                get: { dictation.problem != nil },
                set: { if !$0 { dictation.problem = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(dictation.problem ?? "")
            }
        }
    }

    private func toggle() async {
        if dictation.isListening {
            let said = await dictation.stop()
            guard !said.isEmpty else { return }
            text = said
            if let polish {
                polishing = true
                if let better = await polish(said) { text = better }
                polishing = false
            }
        } else {
            await dictation.start()
        }
    }
}

// MARK: - The order sheet's helpers

/// "Describe it", "Scan your clothes" and "Read a care label", at the top of
/// the order sheet. Each fills in the same steppers the customer would have
/// tapped, so everything it does is visible and undoable on the same screen.
struct SmartOrderTools: View {
    let menu: [ServiceItem]
    let offered: [ServiceKind]
    @Binding var kind: ServiceKind
    @Binding var quantities: [UUID: Double]
    @ObservedObject var extras: OrderExtras

    @State private var description = ""
    @State private var working = false
    @State private var result: String?
    @State private var estimatingWeight = false
    @FocusState private var typing: Bool

    /// The shop's by-the-pound line, when wash & fold is what's on screen.
    private var weighedLine: ServiceItem? {
        guard kind == .washFold || !offered.contains(.dryClean) else { return nil }
        return menu.first { $0.isByWeight }
    }

    var body: some View {
        Section {
            HStack(spacing: 8) {
                TextField("e.g. 2 suits and a coat, tomorrow 9am", text: $description, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($typing)
                    .submitLabel(.done)
                    .onSubmit { Task { await fillFromText() } }
                    .accessibilityLabel("Describe your order")
                DictateButton(text: $description)
                Button("Fill in") { Task { await fillFromText() } }
                    .buttonStyle(.bordered)
                    .disabled(description.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }

            if let laundry = weighedLine {
                Button {
                    estimatingWeight = true
                } label: {
                    Label("Estimate weight from a photo", systemImage: "scalemass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .font(.subheadline)
                .sheet(isPresented: $estimatingWeight) {
                    WeightEstimateView(line: laundry) { estimate, method, photo in
                        kind = .washFold
                        quantities[laundry.id] = max(estimate.pounds, ServicePricing.startingUnits(laundry))
                        extras.weightEstimate = (estimate.pounds, method)
                        if let photo { extras.addHandoff(photo) }
                        result = "Set to \(Int(estimate.pounds)) lb. \(laundry.label) is weighed at the counter, and that's what you pay."
                        estimatingWeight = false
                    }
                    .presentationDetents([.large])
                }
            }

            HStack(spacing: 10) {
                ImageSourceButton(onImage: { image in Task { await scanClothes(image) } }) {
                    Label("Scan clothes", systemImage: "camera.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                ImageSourceButton(onImage: { image in Task { await readCareLabel(image) } }) {
                    Label("Care label", systemImage: "tag")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .font(.subheadline)

            if working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking…").font(.caption).foregroundStyle(Theme.muted)
                }
            } else if let result {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .accessibilityIdentifier("smart-result")
            }
        } header: {
            Text("Quick add")
        } footer: {
            Text("Runs on your iPhone. Photos and words stay on your phone unless you add a photo for the shop at checkout.")
        }
    }

    private func fillFromText() async {
        typing = false
        working = true
        defer { working = false }
        var parsed = OrderTextParser.parse(description, menu: menu)
        parsed = await OnDeviceLanguage.improve(parsed, text: description, menu: menu)
        guard !parsed.isEmpty else {
            result = "Couldn't match that to \(menu.isEmpty ? "this shop" : "this shop's") price list. Try naming the items, like \"3 shirts\"."
            return
        }
        if let service = parsed.service, offered.contains(service) { kind = service }
        for (id, qty) in parsed.quantities { quantities[id] = qty }
        if let when = parsed.pickupAt { extras.requestedPickup = when }
        var said: [String] = []
        let names = parsed.quantities.compactMap { id, _ in menu.first { $0.id == id }?.label }
        if !names.isEmpty { said.append("Added \(names.sorted().joined(separator: ", ")).") }
        if let when = parsed.pickupAt {
            said.append("Pickup set for \(when.formatted(date: .abbreviated, time: .shortened)).")
        }
        if !parsed.unmatched.isEmpty {
            said.append("Not on this shop's list: \(parsed.unmatched.joined(separator: ", ")).")
        }
        result = said.joined(separator: " ")
    }

    private func scanClothes(_ image: UIImage) async {
        working = true
        defer { working = false }
        let labels = await OnDeviceVision.classify(image)
        let found = GarmentMatcher.suggestions(labels: labels, menu: menu)
        guard !found.isEmpty else {
            result = "Couldn't tell what's in that photo. Add the items below."
            return
        }
        if let first = found.first, let service = ServiceKind(rawValue: first.serviceType), offered.contains(service) {
            kind = service
        }
        for item in found where item.serviceType == kind.rawValue && (quantities[item.id] ?? 0) <= 0 {
            quantities[item.id] = item.isByWeight ? ServicePricing.openingUnits(item) : 1
        }
        extras.addHandoff(image)
        result = "Looks like: \(found.map(\.label).joined(separator: ", ")). Check the counts. The photo is saved as your handoff photo for the shop."
    }

    private func readCareLabel(_ image: UIImage) async {
        working = true
        defer { working = false }
        let advice = CareAdvice.read(await OnDeviceVision.readText(image))
        result = advice.message
        if let service = advice.service, offered.contains(service), service != kind {
            kind = service
        }
        if advice == .dryClean, !extras.careNotes.contains("Care label: dry clean") {
            extras.careNotes.append("Care label: dry clean")
        }
    }
}

// MARK: - Checkout: photos and ticket

/// Photos for the shop, and for a Return only order the claim ticket, on the
/// checkout screen.
struct ShopExtrasCard: View {
    @ObservedObject var extras: OrderExtras
    let returnOnly: Bool
    let shops: [Cleaner]
    @Binding var cleaner: Cleaner?

    @State private var stainDraft: OrderPhoto?
    @State private var scanningTicket = false
    @State private var ticketMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if returnOnly { ticketRow }
            Text("Photos for the shop")
                .font(.subheadline.weight(.semibold))
            Text(returnOnly
                 ? "Optional. A photo of a stain with a note helps the counter."
                 : "Optional. A handoff photo records what went in the bag and when. Add stains with a note so the counter knows what to treat.")
                .font(.caption)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            if !extras.photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(extras.photos) { photo in thumbnail(photo) }
                    }
                }
            }

            HStack(spacing: 10) {
                if !returnOnly {
                    ImageSourceButton(onImage: { extras.addHandoff($0) }) {
                        Label("Handoff photo", systemImage: "camera")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!extras.canAddPhoto)
                }
                ImageSourceButton(onImage: { stainDraft = OrderPhoto(image: $0, kind: .stain) }) {
                    Label("Stain", systemImage: "drop")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!extras.canAddPhoto)
            }
            .font(.subheadline)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .sheet(item: $stainDraft) { draft in
            StainNoteView(photo: draft) { saved in
                if extras.canAddPhoto { extras.photos.append(saved) }
                stainDraft = nil
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var ticketRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shop ticket")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                TextField("Ticket number", text: $extras.ticket)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding(10)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                ImageSourceButton(onImage: { image in Task { await readTicket(image) } }) {
                    Label("Scan", systemImage: "doc.text.viewfinder")
                }
                .buttonStyle(.bordered)
            }
            if let ticketMessage {
                Text(ticketMessage).font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .padding(.bottom, 4)
    }

    private func readTicket(_ image: UIImage) async {
        ticketMessage = "Reading…"
        let reading = TicketReader.read(await OnDeviceVision.readText(image), shops: shops)
        if let number = reading.number { extras.ticket = number }
        var said: [String] = []
        said.append(reading.number.map { "Ticket \($0)." } ?? "Couldn't find a ticket number. Type it in.")
        if let id = reading.shopId, let shop = shops.first(where: { $0.id == id }) {
            if cleaner?.id != shop.id { cleaner = shop }
            said.append("From \(shop.name).")
        }
        ticketMessage = said.joined(separator: " ")
    }

    private func thumbnail(_ photo: OrderPhoto) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: photo.image)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Text(photo.kind == .stain ? "Stain" : "Handoff")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(4)
                }
            Button {
                extras.photos.removeAll { $0.id == photo.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .accessibilityLabel("Remove photo")
            .padding(2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(photo.kind == .stain ? "Stain photo: \(photo.note)" : "Handoff photo")
    }
}

/// Say or type what the stain is; Apple Intelligence, where present, turns it
/// into the short note a counter wants.
struct StainNoteView: View {
    @Environment(\.dismiss) private var dismiss
    let photo: OrderPhoto
    let onSave: (OrderPhoto) -> Void

    @State private var note = ""
    @State private var tidying = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Image(uiImage: photo.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Stain photo")
                HStack(spacing: 8) {
                    TextField("e.g. red wine on the left cuff, silk", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                        .padding(10)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityLabel("Stain note")
                    DictateButton(text: $note) { await OnDeviceLanguage.stainNote(from: $0) }
                }
                if OnDeviceLanguage.isAvailable {
                    Button {
                        Task {
                            tidying = true
                            if let better = await OnDeviceLanguage.stainNote(from: note) { note = better }
                            tidying = false
                        }
                    } label: {
                        Label(tidying ? "Tidying…" : "Tidy note for the shop", systemImage: "wand.and.stars")
                    }
                    .disabled(note.isEmpty || tidying)
                    .font(.subheadline)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("Stain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        var saved = photo
                        saved.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(saved)
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}


// MARK: - Weight from a photo

/// Pick the container, say how full, and get a rough weight — or, on a Pro
/// iPhone, measure the pile with LiDAR. The counter's scale still sets the bill.
struct WeightEstimateView: View {
    @Environment(\.dismiss) private var dismiss
    let line: ServiceItem
    let onUse: (WeightEstimate, String, UIImage?) -> Void

    @State private var photo: UIImage?
    @State private var container: LaundryContainer = .basket
    @State private var fullness = 0.75
    @State private var heavy = false
    @State private var detected: String?
    @State private var scanning = false
    @State private var measuredCubicFeet: Double?

    private var estimate: WeightEstimate {
        if let measuredCubicFeet { return .from(cubicFeet: measuredCubicFeet, heavy: heavy) }
        return .from(container: container, fullness: fullness, heavy: heavy)
    }

    private var method: String { measuredCubicFeet == nil ? "container" : "lidar" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        if let photo {
                            Image(uiImage: photo)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .accessibilityLabel("Your laundry photo")
                        }
                        ImageSourceButton(onImage: { image in Task { await recognise(image) } }) {
                            Label(photo == nil ? "Take a photo of it" : "Retake", systemImage: "camera")
                        }
                    }
                    if let detected {
                        Text(detected).font(.caption).foregroundStyle(Theme.muted)
                    }
                    if PileScanner.isSupported {
                        Button {
                            scanning = true
                        } label: {
                            Label(measuredCubicFeet == nil ? "Measure it with LiDAR" : "Measure again", systemImage: "cube.transparent")
                        }
                    }
                } footer: {
                    Text(PileScanner.isSupported
                         ? "LiDAR measures the pile's size. Without it, the estimate comes from the container and how full it is."
                         : "The estimate comes from the container and how full it is.")
                }

                if measuredCubicFeet == nil {
                    Section("What's it in?") {
                        Picker("Container", selection: $container) {
                            ForEach(LaundryContainer.allCases) { Text($0.label).tag($0) }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("How full? \(fullnessLabel)")
                            Slider(value: $fullness, in: 0.25...1.2, step: 0.05)
                                .accessibilityValue(fullnessLabel)
                        }
                    }
                } else if let measuredCubicFeet {
                    Section("Measured") {
                        Text(String(format: "About %.1f cubic feet of laundry", measuredCubicFeet))
                        Button("Use the container instead") { self.measuredCubicFeet = nil }
                    }
                }

                Section {
                    Toggle("Mostly towels, jeans or bedding", isOn: $heavy)
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("About \(Int(estimate.pounds)) lb")
                            .font(.title2.weight(.semibold))
                            .accessibilityIdentifier("weight-estimate")
                        Text("Likely \(Int(estimate.low))–\(Int(estimate.high)) lb. \(line.label) is weighed at the counter, and that weight is what you pay.")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                    Button("Use \(Int(estimate.pounds)) lb") { onUse(estimate, method, photo) }
                        .fontWeight(.semibold)
                }
            }
            .navigationTitle("Estimate weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $scanning) {
                PileScanView { cubicFeet in
                    scanning = false
                    if let cubicFeet { measuredCubicFeet = cubicFeet }
                }
            }
        }
    }

    private var fullnessLabel: String {
        switch fullness {
        case ..<0.375: return "About a quarter"
        case ..<0.625: return "About half"
        case ..<0.875: return "About three quarters"
        case ..<1.05: return "Full"
        default: return "Overflowing"
        }
    }

    private func recognise(_ image: UIImage) async {
        photo = image
        let labels = await OnDeviceVision.classify(image)
        if let found = LaundryContainer.from(labels: labels) {
            container = found
            detected = "Looks like a \(found.label.lowercased()). Change it if not."
        } else {
            detected = "Couldn't tell the container. Pick it below."
        }
    }
}

/// The camera view for a LiDAR measurement.
struct PileScanView: View {
    let onDone: (Double?) -> Void
    @StateObject private var scanner = PileScanner()

    var body: some View {
        ZStack(alignment: .bottom) {
            ARCameraView(scanner: scanner).ignoresSafeArea()
            VStack(spacing: 12) {
                Text(scanner.floorFound
                     ? "Frame the whole pile in the middle, from a step back."
                     : "Point at the floor next to the pile.")
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack(spacing: 12) {
                    Button("Cancel") {
                        scanner.stop()
                        onDone(nil)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        Task {
                            await scanner.measure()
                            scanner.stop()
                            onDone(scanner.cubicFeet)
                        }
                    } label: {
                        Text(scanner.measuring ? "Measuring…" : "Measure")
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accentFill)
                    .disabled(!scanner.floorFound || scanner.measuring)
                }
            }
            .padding(.bottom, 32)
            .padding(.horizontal, 16)
        }
    }
}

private struct ARCameraView: UIViewRepresentable {
    let scanner: PileScanner

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.automaticallyUpdatesLighting = false
        scanner.attach(view.session)
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {}
}
