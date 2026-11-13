import SwiftUI
import SwiftData

struct SubscriptionsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Subscription.created) private var subscriptions: [Subscription]
    @Query private var articles: [Article]
    @State private var name = ""
    @State private var address = ""
    @State private var kind = "rss"
    @State private var pendingDeletion: Subscription?
    @State private var errorMessage: String?
    private var valid: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if kind == "telegram" { return address.range(of: "^@?[A-Za-z0-9_]{5,32}$", options: .regularExpression) != nil }
        guard let url = URL(string: address) else { return false }
        return url.scheme == "https" && url.host != nil
    }
    var body: some View {
        NavigationStack {
            Form {
                ThemeSettings()
                Section("Your subscriptions") {
                    if subscriptions.isEmpty { Text("Your stream starts here.").foregroundStyle(.secondary) }
                    ForEach(subscriptions) { subscription in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(subscription.name, systemImage: subscription.kind == "telegram" ? "paperplane" : "dot.radiowaves.left.and.right")
                                Spacer()
                                Button(subscription.paused ? "Resume" : "Pause") { toggle(subscription) }.buttonStyle(.bordered)
                                Button(role: .destructive) { pendingDeletion = subscription } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Remove \(subscription.name)")
                            }
                            Text(subscription.address).font(.caption).foregroundStyle(.secondary)
                            DisclosureGroup("Hide repeated text") {
                                TextField("One phrase per line", text: Binding(get: { subscription.hiddenText }, set: { subscription.hiddenText = $0; subscription.contentDefaultsApplied = true; save() }), axis: .vertical)
                                    .lineLimit(3...8)
                                Text("Matching phrases are hidden in the reader. Original articles remain available.").font(.caption).foregroundStyle(.secondary)
                            }
                            let count = articles.filter { $0.subscriptionID == subscription.id && $0.queued }.count
                            if subscription.paused { Text("Paused · \(count) queued").font(.caption).foregroundStyle(.orange) }
                        }.padding(.vertical, 4)
                    }
                }
                Section("Add a subscription") {
                    Picker("Type", selection: $kind) { Text("RSS / Atom").tag("rss"); Text("Telegram").tag("telegram") }.pickerStyle(.segmented)
                    TextField("Name", text: $name)
                    TextField(kind == "rss" ? "https://example.com/feed.xml" : "@publicchannel", text: $address).autocorrectionDisabled()
                    Button("Add subscription", systemImage: "plus") {
                        let clean = address.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !subscriptions.contains(where: { $0.kind == kind && $0.address == clean }) else { errorMessage = "This subscription already exists."; return }
                        context.insert(Subscription(name: name.trimmingCharacters(in: .whitespacesAndNewlines), address: clean, kind: kind)); save(); name = ""; address = ""
                    }.disabled(!valid)
                }
                Section {
                    Text("Refresh collects new items even while paused. Resume appends queued stories to the end of your reading queue. Public Telegram previews expose only a recent window of posts; continuous historical collection requires a Telegram client integration.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Delete subscription?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
                Button("Delete subscription", role: .destructive) {
                    if let subscription = pendingDeletion { context.delete(subscription); save() }
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: { Text("Stop updates from \(pendingDeletion?.name ?? "this subscription")? Saved articles and reading history will be kept.") }
            .alert("Library update failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        }.frame(minWidth: 320, minHeight: 500)
    }
    private func toggle(_ subscription: Subscription) {
        subscription.paused.toggle()
        if !subscription.paused {
            var position = articles.map(\.queuePosition).max() ?? 0
            for article in articles.filter({ $0.subscriptionID == subscription.id && $0.queued }).sorted(by: { $0.published < $1.published }) {
                position += 1; article.queuePosition = position; article.queued = false
            }
        }
        save()
    }
    private func save() { do { try context.save() } catch { errorMessage = error.localizedDescription } }
}
