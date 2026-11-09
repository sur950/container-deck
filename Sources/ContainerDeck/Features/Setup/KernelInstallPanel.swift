import SwiftUI
import DeckCore

/// Kernel install state the app shows under the Linux kernel check.
enum KernelInstallState: Equatable {
    case running(KernelInstallStage)
    case failed(KernelInstallError)
}

/// Download progress (MB of total, speed, Cancel), or a plain error with Try Again and
/// the raw output under Details. Used by every CheckRow for the kernel check.
struct KernelInstallPanel: View {
    @Environment(AppState.self) private var state
    let status: KernelInstallState
    @State private var showDetails = false

    var body: some View {
        switch status {
        case .running(let stage):
            running(stage)
        case .failed(let error):
            failed(error)
                .onDeckDebugCommand { name, value in
                    // Automation: "kernel-details:open" or "kernel-details:close".
                    if name == "kernel-details" { showDetails = value == "open" }
                }
        }
    }

    // MARK: - Running

    private func running(_ stage: KernelInstallStage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text(stage.title)
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                if stage.canCancel {
                    Button("Cancel") { state.cancelKernelInstall() }
                        .controlSize(.small)
                        .help("Stops the download and deletes the partial file.")
                }
            }
            if case .downloading(let progress) = stage, let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(DS.accent)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(DS.accent)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(caption(stage))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if case .downloading(let progress) = stage, let speed = progress.speedText {
                    Text(speed)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(DS.textSecondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.accentSoft.opacity(0.5), in: RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
    }

    private func caption(_ stage: KernelInstallStage) -> String {
        switch stage {
        case .preparing:
            return "Finding the recommended kernel."
        case .downloading(let progress):
            if progress.isFreshRetry { return "\(progress.sizeText). Fresh copy, the first was damaged." }
            if progress.attempt > 1 { return "\(progress.sizeText). Resumed after a dropped connection." }
            return progress.sizeText
        case .verifying:
            return "Making sure the file arrived complete and unchanged."
        case .startingService:
            return "The kernel is installed by the container service."
        case .installing:
            return "Apple's container tool is unpacking it. This can take a minute."
        }
    }

    // MARK: - Failed

    private func failed(_ error: KernelInstallError) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                DeckIcon(.error, size: 16, color: DS.danger)
                    .padding(.top, 1)
                Text(error.message)
                    .font(.callout)
                    .foregroundStyle(DS.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    Task { await state.fix(.installKernel) }
                } label: {
                    DeckLabel("Try Again", icon: .refresh)
                }
                .deckPrimary()
                .disabled(state.busyFix != nil)
            }
            if !error.details.isEmpty {
                DisclosureGroup(isExpanded: $showDetails) {
                    ScrollView {
                        Text(error.details)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(DS.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 110)
                    .background(DS.surfaceSunken, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.top, 4)
                } label: {
                    Text("Details")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(DS.textSecondary)
                }
                .padding(.leading, 26)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.danger.opacity(0.09), in: RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).strokeBorder(DS.danger.opacity(0.25), lineWidth: 1))
    }
}
