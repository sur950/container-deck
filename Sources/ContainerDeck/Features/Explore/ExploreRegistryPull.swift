import SwiftUI
import DeckCore

/// "Pull from any registry": a full reference like ghcr.io/owner/app:tag, pulled
/// with Apple's container tool. Registries that need a sign in use the logins
/// from Settings, Registries.
struct ExploreRegistryPullCard: View {
    @Environment(AppState.self) private var state
    @AppStorage(PrefKey.showCommandHints) private var showHints = true

    @Binding var reference: String
    let onPull: (String) -> Void

    private var parsed: PullReference? { PullReference.parse(reference) }
    private var trimmed: String { reference.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                IconBadge(.registry, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pull from any registry").font(.headline)
                    Text("GitHub, Quay, Amazon ECR, GitLab, your own registry. Paste the full image name.")
                        .font(.callout)
                        .foregroundStyle(DS.textSecondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                TextField("Image", text: $reference, prompt: Text("ghcr.io/owner/image:tag"))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .labelsHidden()
                    .onSubmit(pull)
                Button(action: pull) {
                    DeckLabel("Pull", icon: .pull)
                }
                .deckPrimary()
                .disabled(parsed == nil || state.client == nil)
            }
            feedback
            HStack(spacing: 6) {
                Text("Try")
                    .font(.caption)
                    .foregroundStyle(DS.textTertiary)
                ForEach(Self.examples, id: \.self) { example in
                    Button(example) { reference = example }
                        .buttonStyle(.plain)
                        .font(.caption.monospaced())
                        .foregroundStyle(DS.accent)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deckCard()
    }

    static let examples = ["ghcr.io/astral-sh/uv:latest", "quay.io/prometheus/node-exporter", "public.ecr.aws/docker/library/redis:alpine"]

    @ViewBuilder
    private var feedback: some View {
        if trimmed.isEmpty {
            EmptyView()
        } else if let parsed {
            HStack(spacing: 8) {
                DeckIcon(.success, size: 12, color: DS.running)
                Text("\(parsed.registryDisplayName), \(parsed.repository)" + (parsed.digest != nil ? " at a fixed digest" : ", tag \(parsed.tag ?? "latest")"))
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                Spacer(minLength: 8)
                if showHints, let client = state.client {
                    CommandHint(client.commandLine(client.pullArguments(trimmed, platform: ImagePlatform.host)))
                        .frame(maxWidth: 380)
                }
            }
        } else {
            HStack(spacing: 8) {
                DeckIcon(.warning, size: 12, color: DS.warning)
                Text("That is not an image name. Use lower case, like registry.example.com/team/app:1.0.")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
            }
        }
    }

    private func pull() {
        guard parsed != nil, state.client != nil else { return }
        onPull(trimmed)
    }
}

/// Shown above search results when the search text is a full reference from
/// another registry, which Docker Hub search cannot find.
struct ExploreDirectPullRow: View {
    let reference: String
    let onPull: () -> Void

    var body: some View {
        let parsed = PullReference.parse(reference)
        HStack(spacing: 14) {
            IconBadge(.registry, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(reference)
                    .font(.body.monospaced().weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("From \(parsed?.registryDisplayName ?? "another registry"). Docker Hub search does not list it, so pull it by name.")
                    .font(.callout)
                    .foregroundStyle(DS.textSecondary)
            }
            Spacer(minLength: 12)
            Button(action: onPull) {
                DeckLabel("Pull", icon: .pull)
            }
            .deckPrimary()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deckCard()
    }
}

/// Pull request for the sheet.
struct ExplorePullRequest: Identifiable {
    let reference: String
    var id: String { reference }
}
