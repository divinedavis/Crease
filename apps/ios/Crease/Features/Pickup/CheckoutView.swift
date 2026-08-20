import MapKit
import PassKit
import SwiftUI

/// The receipt before the charge, and the last place every choice can still be
/// changed.
///
/// Crease is merchant of record on the whole order — one card charge covers the
/// cleaning and the couriers, and the shop is paid out of it afterwards by
/// whichever rail they signed up for. That is one payment for the customer,
/// which is the right experience, but it also means the app must show what the
/// money is buying before it takes any.
///
/// It is a screen of its own rather than a card on the map for a mechanical
/// reason: Stripe's sheet grows from the bottom by an amount only Stripe
/// decides — every wallet row it offers makes it taller — so anything low on
/// the screen gets covered exactly when it needs to be read. Here the money
/// sits above the fold of that sheet, where nothing can reach it.
///
/// Everything on it is live. The screen used to be a read-only bill: getting
/// the address, the shop, the bag or the tier wrong meant backing out to the
/// booking screen and losing the draft you had built. A checkout people have to
/// leave to correct something is a checkout people leave.
struct CheckoutView: View {
    @EnvironmentObject private var store: OrderStore
    @Environment(\.dismiss) private var dismiss

    /// The door, and the note that tells a courier which one. Bound rather than
    /// copied: the pin is editable from here and the map above has to move when
    /// it changes.
    @Binding var pickup: ResolvedAddress
    @Binding var dropoffNotes: String
    @Binding var cleaner: Cleaner?
    /// Which tier this is. The Delivery/Pickup control writes it, so the fee
    /// and the total below recompute as it is tapped.
    @Binding var selected: ServiceOption
    @Binding var serviceKind: ServiceKind
    @Binding var quantities: [UUID: Double]
    /// When the courier should come. `nil` is Standard — as soon as one can get
    /// there — which is what every booking used to be with no way to say
    /// otherwise.
    @Binding var scheduledPickup: Date?

    /// What the saved address is called, when it is one. Purely a label: the
    /// address itself travels in `pickup`.
    let addressLabel: String
    let menu: [ServiceItem]
    let lines: [(item: ServiceItem, entered: Double)]
    let cleaningCents: Int
    let serviceFeeCents: Int
    let taxCents: Int
    /// What the card is authorized for, which is more than the total: the shop
    /// has not opened the bag yet, and a hold with no headroom means any extra
    /// sock stops the order to ask. Shown because Stripe's own sheet will
    /// display this number, and a customer meeting it for the first time on the
    /// Pay button reads it as being overcharged.
    let holdCents: Int
    /// Anything that went wrong while paying. Rendered here rather than on the
    /// booking screen underneath: a full-screen cover hides its parent, so an
    /// error written there is an error nobody reads — a tap that looks like it
    /// did nothing at all.
    let errorMessage: String?
    let working: Bool
    let onPay: () -> Void

    @State private var camera: MapCameraPosition = .automatic
    @State private var editingPin = false
    @State private var editingNotes = false
    @State private var editingPhone = false
    @State private var choosingShop = false
    @State private var choosingItems = false
    @State private var scheduling = false
    @State private var explainingPayment = false
    /// The moment the arrival window was quoted from.
    ///
    /// Fixed at appear rather than read off `Date()` inside the window's
    /// computed property: that property is evaluated on every redraw, so the
    /// quoted window would creep forward a few seconds each time anything else
    /// on the screen changed — a time that moves while you look at it.
    @State private var quotedAt = Date()

    // MARK: - Derived money

    private var deliveryFeeCents: Int { selected.priceCents }
    private var totalCents: Int { cleaningCents + deliveryFeeCents + serviceFeeCents + taxCents }
    private var carriesCleaning: Bool { selected.carriesCleaning }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 18) {
                    if let errorMessage { errorBanner(errorMessage) }
                    if offersModeChoice { modeToggle }
                    mapCard
                    detailsCard
                    timeSection
                    summarySection
                    totals
                    paymentRow
                    holdNote
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom) { placeOrderBar }
        .interactiveDismissDisabled(working)
        .task { await store.loadProfile() }
        .onAppear(perform: frameRoute)
        .onChange(of: cleaner?.id) { _, _ in frameRoute() }
        .onChange(of: pickup) { _, _ in frameRoute() }
        // A scheduled time belongs to the tier it was chosen under: switching
        // to a tier that collects nothing leaves a pickup time for a pickup
        // that never happens.
        .onChange(of: selected.id) { _, _ in
            if selected.pickupEtaMinutes == nil { scheduledPickup = nil }
        }
        .sheet(isPresented: $editingPin) {
            PinConfirmView(address: pickup) { confirmed, notes in
                pickup = confirmed
                // Only when they wrote one. The field in that sheet starts
                // empty every time, so treating a blank as an answer would
                // erase the instruction they set two taps ago.
                if !notes.isEmpty { dropoffNotes = notes }
                // That sheet has never dismissed itself — its callers do, and
                // this one has to as well or confirming leaves the map up over
                // the bill it was meant to correct.
                editingPin = false
            }
        }
        .sheet(isPresented: $editingNotes) {
            DropoffNotesView(notes: $dropoffNotes)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $editingPhone) {
            ContactPhoneView(phone: store.profile?.phone ?? "") { entered in
                await store.saveContactPhone(entered)
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $choosingShop) {
            CleanerPickerView(
                cleaners: store.cleaners,
                pickup: pickup.coordinate,
                selected: cleaner
            ) { picked in
                withAnimation(.easeInOut(duration: 0.3)) { cleaner = picked }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $choosingItems) {
            ServiceMenuView(
                shopName: cleaner?.name ?? "This shop",
                menu: menu,
                kind: $serviceKind,
                quantities: $quantities
            )
            .presentationDetents([.large])
        }
        .sheet(isPresented: $scheduling) {
            SchedulePickupView(
                title: timeTitle,
                earliest: earliestSchedulable,
                chosen: $scheduledPickup
            )
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $explainingPayment) {
            PaymentMethodsView(walletAvailable: walletAvailable)
                .presentationDetents([.medium])
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: {
                Image(systemName: "arrow.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .background(Color(.secondarySystemBackground), in: Circle())
            }
            .disabled(working)
            .accessibilityLabel("Back")

            Text("Checkout")
                .font(.largeTitle.weight(.bold))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.footnote)
            .foregroundStyle(Theme.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.danger.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Delivery / Pickup

    /// The two tiers this control switches between: we bring the finished order
    /// home, or you collect it from the shop's counter.
    private var deliveryOption: ServiceOption? { ServiceOption.all.first { $0.id == "round_trip" } }
    private var pickupOption: ServiceOption? { ServiceOption.all.first { $0.id == "pickup_only" } }

    /// Hidden on return-only. That tier exists because the clothes are already
    /// at the shop and already paid for, so there is no second way to run it —
    /// offering a choice there would be offering to un-drop-off a bag.
    private var offersModeChoice: Bool {
        selected.id != "return_only" && deliveryOption != nil && pickupOption != nil
    }

    private var modeToggle: some View {
        HStack(spacing: 0) {
            if let deliveryOption {
                modeHalf(deliveryOption, title: "Delivery")
            }
            if let pickupOption {
                modeHalf(pickupOption, title: "Pickup")
            }
        }
        .padding(4)
        .background(Color(.secondarySystemBackground), in: Capsule())
        // The badge names the reason someone would pick the other half, and it
        // is a fact rather than a nudge: one courier leg genuinely costs less
        // than two. Anchored to the cheaper tier by arithmetic, so it cannot
        // end up sitting over the dearer one if the price sheet moves.
        .overlay(alignment: cheaperIsPickup ? .topTrailing : .topLeading) {
            Text("Lower Fees")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(.systemBackground), in: Capsule())
                .overlay(Capsule().stroke(Theme.accent.opacity(0.45), lineWidth: 1))
                .padding(.horizontal, 26)
                .offset(y: -13)
                .accessibilityHidden(true)
        }
        .padding(.top, 8)
    }

    private var cheaperIsPickup: Bool {
        (pickupOption?.priceCents ?? .max) <= (deliveryOption?.priceCents ?? .max)
    }

    private func modeHalf(_ option: ServiceOption, title: String) -> some View {
        let isOn = selected.id == option.id
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) { selected = option }
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isOn ? .white : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(isOn ? Theme.accent : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(working)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
        .accessibilityLabel("\(title). \(option.blurb). \(option.priceCents.asMoney)")
    }

    // MARK: - Map

    /// The route, small. The full-screen map on the booking screen answers
    /// "where is this going"; here the only question left is "is that my door",
    /// which is what Edit Pin is for.
    private var mapCard: some View {
        Map(position: $camera, interactionModes: []) {
            Marker(addressLabel, systemImage: "house.fill", coordinate: pickup.coordinate)
                .tint(Theme.accent)
            if let coordinate = cleaner?.coordinate {
                Marker(cleaner?.name ?? "Cleaner", systemImage: "building.2.fill", coordinate: coordinate)
                    .tint(Theme.warn)
                MapPolyline(coordinates: [pickup.coordinate, coordinate])
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 8]))
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(height: 132)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button { editingPin = true } label: {
                Label("Edit Pin", systemImage: "mappin.and.ellipse")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.78), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(10)
            .disabled(working)
            .accessibilityLabel("Edit the pickup pin")
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Where and who

    private var detailsCard: some View {
        VStack(spacing: 0) {
            detailRow(
                symbol: "house",
                title: addressLabel,
                detail: pickup.oneLine,
                detailTint: .secondary
            ) { editingPin = true }

            Divider().padding(.leading, 56)

            detailRow(
                symbol: "person.crop.circle.badge.questionmark",
                title: dropoffNotes.isEmpty ? "Meet at my door" : dropoffNotes,
                detail: dropoffNotes.isEmpty ? "Add pickup instructions" : "Change pickup instructions",
                detailTint: Theme.accent
            ) { editingNotes = true }

            Divider().padding(.leading, 56)

            detailRow(
                symbol: "phone",
                title: store.profile?.formattedPhone ?? "Add a phone number",
                detail: store.profile?.phone == nil ? "So the courier can reach you at the door" : nil,
                detailTint: .secondary
            ) { editingPhone = true }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private func detailRow(
        symbol: String,
        title: String,
        detail: String?,
        detailTint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(detailTint)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(working)
        .accessibilityElement(children: .combine)
    }

    // MARK: - When

    /// Pickup on every tier that collects a bag, delivery on the one that does
    /// not. Naming it "Delivery time" everywhere would promise a finished order
    /// back inside a twenty-minute window, which is not true of any dry
    /// cleaning anywhere — the return slot is chosen later, once the shop says
    /// the order is ready.
    private var timeTitle: String { selected.pickupEtaMinutes == nil ? "Delivery time" : "Pickup time" }

    /// The window a driver would arrive in if the order were placed now. Only
    /// quotable on the tiers that actually send one to the customer.
    private var standardWindow: (start: Date, end: Date)? {
        guard let minutes = selected.pickupEtaMinutes else { return nil }
        let start = quotedAt.addingTimeInterval(Double(minutes) * 60)
        return (start, start.addingTimeInterval(20 * 60))
    }

    /// The first slot worth offering: an hour out, rounded up to the next half
    /// hour. Sooner than that is what Standard already is.
    private var earliestSchedulable: Date {
        let hourOut = quotedAt.addingTimeInterval(3600)
        let interval: TimeInterval = 1800
        return Date(timeIntervalSinceReferenceDate:
            (hourOut.timeIntervalSinceReferenceDate / interval).rounded(.up) * interval)
    }

    @ViewBuilder private var timeSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(timeTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(chosenTimeText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let standardWindow {
                HStack(spacing: 12) {
                    timeCard(
                        title: "Standard",
                        detail: windowText(standardWindow.start, standardWindow.end),
                        isOn: scheduledPickup == nil
                    ) { scheduledPickup = nil }

                    timeCard(
                        title: "Schedule",
                        detail: scheduledPickup.map { atText($0) }
                            ?? "Earliest \(timeText(earliestSchedulable))",
                        isOn: scheduledPickup != nil
                    ) { scheduling = true }
                }
            } else {
                // Return-only. The clothes are at the shop; when they come home
                // is the shop's answer to give, and the customer picks a slot
                // from the order once they do.
                Text("You'll choose a delivery window once \(cleaner?.name ?? "the shop") says your order is ready.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            }
        }
    }

    private var chosenTimeText: String {
        if let scheduledPickup { return atText(scheduledPickup) }
        if let standardWindow { return windowText(standardWindow.start, standardWindow.end) }
        return "When it's ready"
    }

    private func timeCard(
        title: String,
        detail: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isOn ? Theme.accent : .clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(working)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    // MARK: - What

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Order Summary")
                .font(.title3.weight(.bold))
                .foregroundStyle(.secondary)

            Button {
                // The shop is changed from its own row below; this opens the
                // bag, which is the thing people actually revise at checkout.
                if carriesCleaning { choosingItems = true } else { choosingShop = true }
            } label: {
                HStack(spacing: 12) {
                    shopTile
                    VStack(alignment: .leading, spacing: 3) {
                        Text(cleaner?.name ?? "Choose a cleaner")
                            .font(.body.weight(.bold))
                            .lineLimit(1)
                        if carriesCleaning, !lines.isEmpty {
                            ForEach(lines, id: \.item.id) { line in
                                Text(lineLabel(line))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        } else {
                            Text(emptyBagLine)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(working)
            .accessibilityElement(children: .combine)
            .accessibilityHint(carriesCleaning ? "Change what you're sending" : "Change the shop")

            Button { choosingShop = true } label: {
                Text("Change shop")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(working)
        }
    }

    /// The shop's initials in a tile, where a marketplace with logos would put
    /// one. Deterministic from the name so a shop looks the same on every
    /// screen it appears on.
    private var shopTile: some View {
        Text(initials)
            .font(.caption.weight(.heavy))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }

    private var initials: String {
        let words = (cleaner?.name ?? "Crease")
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
        return words.joined().uppercased()
    }

    private var emptyBagLine: String {
        guard carriesCleaning else { return "Bringing your finished order home" }
        return menu.isEmpty ? "Loading this shop's prices…" : "Tap to choose what you're sending"
    }

    private func lineLabel(_ line: (item: ServiceItem, entered: Double)) -> String {
        line.item.isByWeight
            ? "\(line.item.label) - \(number(line.entered)) lb"
            : "\(line.item.label) - Qty \(Int(line.entered))"
    }

    // MARK: - Money

    private var totals: some View {
        VStack(spacing: 9) {
            if carriesCleaning {
                totalRow("Subtotal", cleaningCents.asMoney)
            }
            totalRow(
                "Delivery Fee",
                deliveryFeeCents == 0 ? "Free" : deliveryFeeCents.asMoney,
                valueTint: deliveryFeeCents == 0 ? Theme.accent : .primary
            )
            if serviceFeeCents + taxCents > 0 {
                totalRow("Taxes & Other Fees", (serviceFeeCents + taxCents).asMoney)
            }
            HStack {
                Text("TOTAL").font(.body.weight(.semibold))
                Spacer()
                Text(totalCents.asMoney).font(.title3.weight(.bold).monospacedDigit())
            }
            .padding(.top, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Total \(totalCents.asMoney)")
        }
    }

    private func totalRow(_ label: String, _ value: String, valueTint: Color = .primary) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(valueTint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
    }

    // MARK: - Payment

    /// Whether this device can actually pay with a wallet. Asked of PassKit
    /// rather than assumed: a row promising Apple Pay to a phone with no card
    /// set up is a row that lies about what the next tap does.
    private var walletAvailable: Bool {
        PKPaymentAuthorizationController.canMakePayments(
            usingNetworks: [.visa, .masterCard, .amex, .discover]
        )
    }

    private var paymentRow: some View {
        Button { explainingPayment = true } label: {
            HStack(spacing: 12) {
                Group {
                    if walletAvailable {
                        HStack(spacing: 1) {
                            Image(systemName: "applelogo").font(.system(size: 11, weight: .medium))
                            Text("Pay").font(.system(size: 12, weight: .semibold))
                        }
                    } else {
                        Image(systemName: "creditcard.fill").font(.system(size: 13))
                    }
                }
                .foregroundStyle(.primary)
                .frame(width: 46, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                )

                Text(walletAvailable ? "Apple Pay" : "Card")
                    .font(.body.weight(.medium))

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(working)
        .accessibilityElement(children: .combine)
        .accessibilityHint("What you can pay with")
    }

    /// Said before the card is taken, not discovered at cancellation. A fee
    /// somebody meets for the first time on their statement is a chargeback,
    /// however fair it was.
    private var holdNote: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("\(holdCents.asMoney) is held, not charged", systemImage: "lock.shield")
                .font(.caption.weight(.semibold))
            Text(holdExplainer)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Cancel before a driver is assigned and you pay nothing. After that, the trip we've already paid for is kept.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.accentSoft)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var holdExplainer: String {
        carriesCleaning
            ? "We hold exactly what this comes to — never more. \(cleaner?.name ?? "The shop") counts the bag, and if it matches what you picked you pay \(totalCents.asMoney) and nothing else. If they count more, we ask you before taking another penny."
            : "You've already settled the cleaning with \(cleaner?.name ?? "the shop"), so this is the trip home and nothing else."
    }

    // MARK: - The charge

    private var placeOrderBar: some View {
        Button {
            // Nothing picked is not a checkout. A bag with no prices on it
            // reaches the counter as a question — the shop cannot quote it, the
            // hold cannot cover it, and the customer meets the real number
            // after their clothes have gone. So the button does the only useful
            // thing instead of refusing: it opens the list.
            if carriesCleaning && lines.isEmpty {
                choosingItems = true
            } else {
                onPay()
            }
        } label: {
            Group {
                if working {
                    ProgressView().tint(.white)
                } else {
                    Text(buttonLabel).font(.body.weight(.bold))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(Theme.accent, in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(working || cleaner == nil)
        .opacity(cleaner == nil ? 0.5 : 1)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.regularMaterial)
    }

    /// The total rides on the button as well as sitting above it. It is the
    /// last thing read before a card is charged, and a bare "Place Order" is
    /// the one place a checkout can hide its own price.
    private var buttonLabel: String {
        if carriesCleaning && lines.isEmpty { return "Choose what you're sending" }
        return "Place Order · \(totalCents.asMoney)"
    }

    // MARK: - Map framing

    private func frameRoute() {
        guard let shop = cleaner?.coordinate else {
            camera = .region(MKCoordinateRegion(
                center: pickup.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
            ))
            return
        }
        let midLat = (pickup.coordinate.latitude + shop.latitude) / 2
        let midLon = (pickup.coordinate.longitude + shop.longitude) / 2
        let spanLat = abs(pickup.coordinate.latitude - shop.latitude) * 2.4 + 0.006
        let spanLon = abs(pickup.coordinate.longitude - shop.longitude) * 2.4 + 0.006
        withAnimation(.easeInOut(duration: 0.5)) {
            camera = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: midLat, longitude: midLon),
                span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
            ))
        }
    }

    // MARK: - Formatting

    private func timeText(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    private func windowText(_ start: Date, _ end: Date) -> String {
        "\(start.formatted(.dateTime.hour().minute())) - \(end.formatted(.dateTime.hour().minute()))"
    }

    /// A scheduled slot can be tomorrow, and a bare "9:30 PM" for tomorrow is
    /// how someone waits by the door on the wrong evening.
    private func atText(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? timeText(date)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

// MARK: - Pickup instructions

/// Where the courier should stand, in the customer's own words.
///
/// A separate sheet rather than a field on the checkout because it is typing,
/// and typing under a keyboard that covers the total is how people lose track
/// of what they are paying.
struct DropoffNotesView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var notes: String

    @State private var draft = ""
    @FocusState private var focused: Bool

    private static let suggestions = [
        "Meet at my door",
        "Meet outside",
        "Buzz apartment",
        "Leave with the doorman",
    ]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tell the courier where to find you. Anything here is shown to the driver on both legs.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextField("Meet at my door", text: $draft, axis: .vertical)
                    .lineLimit(3, reservesSpace: true)
                    .focused($focused)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                FlowingChips(options: Self.suggestions) { draft = $0 }

                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("Pickup instructions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        notes = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                draft = notes
                focused = true
            }
        }
    }
}

/// The common answers, one tap each. Most people's instruction is one of four
/// sentences, and typing it on a phone is the reason the field was left blank.
private struct FlowingChips: View {
    let options: [String]
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(stride(from: 0, to: options.count, by: 2)), id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(options[row..<min(row + 2, options.count)], id: \.self) { option in
                        Button { onPick(option) } label: {
                            Text(option)
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color(.tertiarySystemFill), in: Capsule())
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - Contact number

/// The number a courier dials from the doorstep.
///
/// Saved to the profile rather than to the order: it is the same number on
/// every booking, and asking for it once is the difference between a courier
/// who can call and one who leaves.
struct ContactPhoneView: View {
    @Environment(\.dismiss) private var dismiss

    let phone: String
    let onSave: (String) async -> Bool

    @State private var draft = ""
    @State private var saving = false
    @State private var failed = false
    @FocusState private var focused: Bool

    /// Ten digits, or eleven starting with a country code. Checked here so a
    /// half-typed number is caught before it becomes the only way to reach
    /// someone whose clothes have already left the house.
    private var isValid: Bool {
        let digits = draft.filter(\.isNumber)
        return digits.count == 10 || (digits.count == 11 && digits.hasPrefix("1"))
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Couriers call this number if they can't find you at the door. It is shared with the driver on an active order and with nobody else.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextField("(555) 555-0123", text: $draft)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .font(.title3)
                    .focused($focused)
                    .padding(14)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if failed {
                    Text("Couldn't save that number. Please try again.")
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("Phone number")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            saving = true
                            failed = !(await onSave(draft))
                            saving = false
                            if !failed { dismiss() }
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!isValid || saving)
                }
            }
            .onAppear {
                draft = phone
                focused = true
            }
        }
    }
}

// MARK: - Scheduling

/// Pick a slot instead of taking the next driver.
///
/// Bounded at both ends: sooner than an hour is what Standard already does, and
/// a week out is further than any courier quote survives.
struct SchedulePickupView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let earliest: Date
    @Binding var chosen: Date?

    @State private var draft = Date()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                DatePicker(
                    "When",
                    selection: $draft,
                    in: earliest...earliest.addingTimeInterval(7 * 86400),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)
                .padding(.horizontal, 4)

                Text("We'll send a courier to arrive within twenty minutes of this time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") {
                        chosen = draft
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { draft = chosen ?? earliest }
        }
    }
}

// MARK: - What you can pay with

/// What the Place Order button is about to open.
///
/// The payment method is chosen inside Stripe's own sheet, which is where the
/// card details live and the only place they are ever typed. This sheet exists
/// so the row above it is an explanation rather than a promise the screen
/// cannot keep.
struct PaymentMethodsView: View {
    @Environment(\.dismiss) private var dismiss
    let walletAvailable: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(walletAvailable
                     ? "Tap Place Order and Apple Pay opens first — one authentication, no card to type. A card or bank account can be chosen from the same sheet."
                     : "Tap Place Order and a secure sheet opens where you can enter a card. Apple Pay isn't set up on this device.")
                    .font(.subheadline)

                Label("Crease never sees or stores your card. It goes straight to Stripe.", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationTitle("Payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }
}
