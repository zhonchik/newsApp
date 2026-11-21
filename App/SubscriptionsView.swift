import SwiftUI
import SwiftData

struct SubscriptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Subscription.created) private var subscriptions: [Subscription]

    private var alphabeticalSubscriptions: [Subscription] {
        subscriptions.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Your subscriptions") {
                    if subscriptions.isEmpty { Text("Your stream starts here.").foregroundStyle(.secondary) }
                    ForEach(alphabeticalSubscriptions) { subscription in
                        NavigationLink {
                            SubscriptionSettingsView(subscription: subscription, closeSettings: dismiss)
                        } label: {
                            Label(subscription.name, systemImage: subscription.paused ? "pause.circle" : "play.circle")
                                .accessibilityValue(subscription.paused ? "Paused" : "Running")
                        }
                    }
                }
                Section {
                    NavigationLink("Add subscription") { SubscriptionSettingsView(subscription: nil, closeSettings: dismiss) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Subscriptions")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.frame(minWidth: 320, minHeight: 500)
    }
}

private struct SubscriptionSettingsView: View {
    let subscription: Subscription?
    let closeSettings: DismissAction
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Subscription.created) private var subscriptions: [Subscription]
    @Query(filter: #Predicate<Article> { $0.queued }) private var queuedArticles: [Article]
    @State private var name = ""
    @State private var address = ""
    @State private var kind = "rss"
    @State private var hiddenText = ""
    @State private var confirmingDeletion = false
    @State private var errorMessage: String?

    init(subscription: Subscription?, closeSettings: DismissAction) {
        self.closeSettings = closeSettings
        self.subscription = subscription
        _name = State(initialValue: subscription?.name ?? "")
    }

    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool {
        guard !cleanName.isEmpty else { return false }
        if kind == "telegram" { return cleanAddress.range(of: "^@?[A-Za-z0-9_]{5,32}$", options: .regularExpression) != nil }
        guard let url = URL(string: cleanAddress) else { return false }
        return url.scheme == "https" && url.host != nil
    }

    var body: some View {
        Form {
            Section("Source") {
                if let subscription {
                    TextField("Name", text: $name)
                    Button("Save name") {
                        let previousName = subscription.name
                        subscription.name = cleanName
                        if save() {
                            name = subscription.name
                        } else {
                            subscription.name = previousName
                        }
                    }.disabled(cleanName.isEmpty || cleanName == subscription.name)
                    LabeledContent("Type", value: subscription.kind == "telegram" ? "Telegram" : "RSS / Atom")
                    LabeledContent("Address", value: subscription.address)
                } else {
                    Picker("Type", selection: $kind) {
                        Text("RSS / Atom").tag("rss")
                        Text("Telegram").tag("telegram")
                    }.pickerStyle(.segmented)
                    TextField("Name", text: $name)
                    TextField(kind == "rss" ? "https://example.com/feed.xml" : "@publicchannel", text: $address).autocorrectionDisabled()
                }
            }
            Section("Hide repeated text") {
                TextField("One phrase per line", text: hiddenTextBinding, axis: .vertical)
                    .lineLimit(3...8)
                Text("Matching phrases are hidden in the reader. Original articles remain available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let subscription {
                Section {
                    Button(subscription.paused ? "Resume" : "Pause") { toggle(subscription) }
                    if subscription.paused {
                        let count = queuedArticles.filter { $0.subscriptionID == subscription.id }.count
                        Text("Paused · \(count) queued").foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Refresh collects new items even while paused. Resume appends queued stories to the end of your reading queue.")
                }
                Section {
                    Button("Delete subscription", role: .destructive) { confirmingDeletion = true }
                        .confirmationDialog("Delete subscription?", isPresented: $confirmingDeletion, titleVisibility: .visible) {
                            Button("Delete subscription", role: .destructive) {
                                context.delete(subscription)
                                if save() { dismiss() }
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Stop updates from \(subscription.name)? Saved articles and reading history will be kept.")
                        }
                }
            } else {
                Button("Add subscription", systemImage: "plus", action: add).disabled(!valid)
            }
            if (subscription?.kind ?? kind) == "telegram" {
                Text("Public Telegram previews expose only a recent window of posts; continuous historical collection requires a Telegram client integration.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(subscription?.name ?? "Add subscription")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { closeSettings() } }
        }
        .alert("Library update failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var hiddenTextBinding: Binding<String> {
        guard let subscription else { return $hiddenText }
        return Binding(get: { subscription.hiddenText }, set: {
            MediaCache.forgetLaunchLink()
            subscription.hiddenText = $0
            save()
        })
    }

    private func add() {
        guard !subscriptions.contains(where: { $0.kind == kind && $0.address == cleanAddress }) else {
            errorMessage = "This subscription already exists."
            return
        }
        let newSubscription = Subscription(name: cleanName, address: cleanAddress, kind: kind)
        newSubscription.hiddenText = hiddenText
        context.insert(newSubscription)
        if save() { dismiss() } else { context.delete(newSubscription) }
    }

    private func toggle(_ subscription: Subscription) {
        if subscription.paused {
            var latest = FetchDescriptor<Article>(sortBy: [SortDescriptor(\.queuePosition, order: .reverse)])
            latest.fetchLimit = 1
            do {
                var position = try context.fetch(latest).first?.queuePosition ?? 0
                for article in queuedArticles.filter({ $0.subscriptionID == subscription.id }).sorted(by: { $0.published < $1.published }) {
                    position += 1; article.queuePosition = position; article.queued = false
                }
            } catch { errorMessage = error.localizedDescription; return }
        }
        subscription.paused.toggle()
        save()
    }
    @discardableResult
    private func save() -> Bool {
        do {
            try context.save()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
