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
                Section("Your subscriptions") {
                    if subscriptions.isEmpty { Text("Your stream starts here.").foregroundStyle(.secondary) }
                    ForEach(subscriptions) { subscription in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(subscription.name, systemImage: subscription.kind == "telegram" ? "paperplane" : "dot.radiowaves.left.and.right")
                                Spacer()
                                Button(subscription.paused ? "Resume" : "Pause") { toggle(subscription) }.buttonStyle(.bordered)
                                Button(role: .destructive) { context.delete(subscription); save() } label: { Image(systemName: "trash") }.accessibilityLabel("Remove \(subscription.name)")
                            }
                            Text(subscription.address).font(.caption).foregroundStyle(.secondary)
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
                    Text("Refresh collects new items even while paused. Resume releases queued stories into the feed in publication order. Public Telegram previews expose only a recent window of posts; continuous historical collection requires a Telegram client integration.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Subscriptions")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Library update failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        }.frame(minWidth: 320, minHeight: 500)
    }
    private func toggle(_ subscription: Subscription) {
        subscription.paused.toggle()
        if !subscription.paused { for article in articles where article.subscriptionID == subscription.id { article.queued = false } }
        save()
    }
    private func save() { do { try context.save() } catch { errorMessage = error.localizedDescription } }
}
