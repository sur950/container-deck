import SwiftUI
import DeckCore

/// First run guide: Welcome, Check, Extras, Bring your images, Done.
struct SetupGuideView: View {
    @Environment(AppState.self) private var state
    @State private var step: Step = .welcome

    enum Step: Int, CaseIterable {
        case welcome, check, extras, images, done

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .check: return "Check"
            case .extras: return "Extras"
            case .images: return "Your images"
            case .done: return "Done"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        content
                        if let error = state.lastError {
                            ErrorNote(message: error)
                        }
                        if let progress = state.progressText {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(progress).foregroundStyle(DS.textSecondary)
                            }
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                footer
            }
            .background(DS.surface)
        }
        .frame(width: 740, height: 560)
        .tint(DS.accent)
        .task { await NotificationAccessModel.shared.refresh() }
        .onDeckDebugCommand { name, value in
            // Automation: "setup-step:check", "setup-step:extras" and so on.
            if name == "setup-step", let target = Step.allCases.first(where: { "\($0)" == value }) { step = target }
        }
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandLockup(badgeSize: 30, titleSize: 13)
                .padding(.bottom, 26)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Step.allCases, id: \.self) { item in
                    railRow(item)
                }
            }
            Spacer(minLength: 12)
            Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                .font(.caption)
                .foregroundStyle(DS.textSecondary)
        }
        .padding(18)
        .frame(width: 200, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.cardFill)
    }

    private func railRow(_ item: Step) -> some View {
        let isCurrent = item == step
        let isDone = item.rawValue < step.rawValue
        return HStack(spacing: 10) {
            Group {
                if isDone {
                    DeckIcon(.success, size: 22, color: DS.accent)
                } else {
                    Text("\(item.rawValue + 1)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isCurrent ? Color.white : DS.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(isCurrent ? DS.accent : Color.clear))
                        .overlay(Circle().strokeBorder(isCurrent ? Color.clear : DS.borderStrong, lineWidth: 1))
                }
            }
            .frame(width: 22, height: 22)
            Text(item.title)
                .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent || isDone ? DS.textPrimary : DS.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isCurrent ? DS.accentSoft : Color.clear))
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            VStack(alignment: .leading, spacing: 20) {
                LogoTile(size: 64)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Let's get your Mac ready")
                        .font(.system(size: 24, weight: .semibold))
                    Text("\(AppConfig.appName) runs Linux containers with Apple's own container platform. There is no server and no extra daemon. We will check your Mac, install anything missing, and start the service.")
                        .foregroundStyle(DS.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    featureRow(.clock, "Takes about two minutes")
                    Divider()
                    featureRow(.lock, "Some steps ask for your Mac password")
                    Divider()
                    featureRow(.refresh, "Run these checks again any time from Settings")
                }
                .padding(.horizontal, 14)
                .deckCard()
            }
        case .check:
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("Required", subtitle: "These must pass before you can run containers.", icon: .checklist) {
                    recheck
                }
                checkList(state.report.requiredChecks)
            }
        case .extras:
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("Extras", subtitle: "Nice to have. Skip any of them.", icon: .wand) {
                    recheck
                }
                if state.report.optionalChecks.isEmpty {
                    LoadingView("Checking your Mac", style: .logo)
                        .frame(height: 160)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(state.report.optionalChecks) { check in
                            CheckRow(check: check)
                            if check.id == .dns, check.fix == .createDNSDomain {
                                HStack(spacing: 8) {
                                    Text("Domain").foregroundStyle(DS.textSecondary)
                                    TextField("test", text: domainBinding)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 140)
                                }
                                .padding(.leading, 34)
                                .padding(.bottom, 10)
                            }
                            Divider()
                        }
                        NotificationSetupRow(access: NotificationAccessModel.shared.access)
                    }
                    .padding(.horizontal, 14)
                    .deckCard()
                }
            }
        case .images:
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("Bring your images", subtitle: "Move images from other container apps on this Mac.", icon: .importEngines)
                EngineImportSummary()
            }
        case .done:
            VStack(alignment: .leading, spacing: 20) {
                ZStack {
                    Circle()
                        .fill((state.report.isReady ? DS.running : DS.warning).opacity(0.14))
                    DeckIcon(state.report.isReady ? .success : .warning, size: 34, color: state.report.isReady ? DS.running : DS.warning)
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 8) {
                    Text(state.report.isReady ? "You're all set" : "Almost there")
                        .font(.system(size: 24, weight: .semibold))
                    Text(state.report.isReady
                         ? "Your Mac is ready to run containers."
                         : "Some required steps are not done yet. You can finish them later from the banner or from Settings.")
                        .foregroundStyle(DS.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    featureRow(.play, "Run your first container from Containers")
                    Divider()
                    featureRow(.explore, "Find images on Docker Hub in Explore")
                    Divider()
                    featureRow(.command, "Press Command K to jump anywhere")
                }
                .padding(.horizontal, 14)
                .deckCard()
            }
        }
    }

    private func featureRow(_ icon: DeckIconName, _ text: String) -> some View {
        HStack(spacing: 12) {
            IconBadge(icon, size: 28)
            Text(text)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func checkList(_ checks: [SetupCheck]) -> some View {
        if checks.isEmpty {
            LoadingView("Checking your Mac", style: .logo)
                .frame(height: 160)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(checks) { check in
                    CheckRow(check: check)
                    if check.id != checks.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 14)
            .deckCard()
        }
    }

    @ViewBuilder
    private var recheck: some View {
        if state.isChecking {
            ProgressView().controlSize(.small)
        } else {
            Button {
                Task { await state.refresh() }
            } label: {
                DeckLabel("Check again", icon: .refresh)
            }
        }
    }

    private var domainBinding: Binding<String> {
        Binding(get: { state.dnsDomain }, set: { state.dnsDomain = $0 })
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step == .welcome {
                Button("Later") { state.showSetup = false }
            } else if step != .done {
                Button("Back") { go(-1) }
            }
            Spacer()
            switch step {
            case .check:
                if !state.report.isReady {
                    Button("Skip for now") { go(1) }
                }
                Button("Continue") { go(1) }
                    .deckPrimary()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.report.isReady)
            case .done:
                Button("Open Container Deck") { state.completeSetup() }
                    .deckPrimary()
                    .keyboardShortcut(.defaultAction)
            default:
                Button(step == .welcome ? "Start" : "Continue") { go(1) }
                    .deckPrimary()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(16)
        .disabled(state.busyFix != nil)
    }

    private func go(_ delta: Int) {
        state.lastError = nil
        if let next = Step(rawValue: step.rawValue + delta) {
            withAnimation(.easeInOut(duration: 0.2)) {
                step = next
            }
        }
    }
}
