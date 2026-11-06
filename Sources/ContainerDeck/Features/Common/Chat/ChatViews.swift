import SwiftUI
import AppKit

// Chat pieces shared by AI Models > Chat and the Sandbox Chat tab. Each screen keeps its own
// store and sending logic, and hands these views plain ChatItem values.

enum ChatLayout {
    /// Widest the conversation column gets. Narrow panes use their full width minus padding.
    static let columnWidth: CGFloat = 780
    static let bodyFont = Font.system(size: 14)
}

/// One message as the chat views draw it.
struct ChatItem: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant }

    var id: UUID
    var role: Role
    var text: String
    var reasoning: String = ""
    var failed = false
    /// Model name in the assistant header.
    var author: String = ""
    /// Tooltip on the author, like the full model path.
    var authorHelp: String?
    /// Raw error text under a Details disclosure on a failed answer.
    var details: String?
    /// Button on a failed answer, like "Pick another model". Handled by the transcript's `onAction`.
    var actionTitle: String?
    /// Small text after the author, like the server name.
    var authorDetail: String?
    var icon: DeckIconName = .aiModels
    /// Speed line under a finished answer.
    var caption: String?
}

/// Label plus a menu picker, for chat header rows.
struct ChatPickerGroup<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout)
                .foregroundStyle(DS.textSecondary)
                .fixedSize()
            content
                .labelsHidden()
                .popUpAppearanceRefresh()
        }
    }
}

// MARK: - Transcript

/// Scrolling list of messages in one centered column. Follows new text while the view is at
/// the bottom, and leaves the person alone when they scroll up (a button jumps back down).
struct ChatTranscript: View {
    let items: [ChatItem]
    /// The message that is still being written, if any.
    var streamingID: ChatItem.ID?
    var columnWidth: CGFloat = ChatLayout.columnWidth
    var horizontalPadding: CGFloat = Layout.pagePadding
    /// Runs when the button on a failed answer is pressed.
    var onAction: ((ChatItem) -> Void)?

    @State private var pinnedToBottom = true
    @State private var scrollPhase: ScrollPhase = .idle
    private let bottomID = "chat-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(items) { item in
                        ChatMessageView(item: item, streaming: item.id == streamingID, columnWidth: columnWidth, onAction: onAction)
                            .id(item.id)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .frame(maxWidth: columnWidth)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 24)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onScrollPhaseChange { _, phase in scrollPhase = phase }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 48
            } action: { _, atBottom in
                // Only the person scrolling changes this. Growing text must not unpin the view.
                if scrollPhase == .interacting || scrollPhase == .decelerating || scrollPhase == .tracking {
                    pinnedToBottom = atBottom
                }
            }
            .onChange(of: items.last?.text) { _, _ in
                if pinnedToBottom { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onChange(of: items.last?.reasoning) { _, _ in
                if pinnedToBottom { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onChange(of: items.count) { _, _ in
                pinnedToBottom = true
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if !pinnedToBottom {
                    Button {
                        pinnedToBottom = true
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                    } label: {
                        DeckIcon(.chevronDown, size: 12, color: DS.textSecondary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(DS.surfaceRaised))
                            .overlay(Circle().strokeBorder(DS.borderStrong, lineWidth: 1))
                            .shadow(color: DS.shadow, radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .help("Jump to the latest message")
                    .padding(.bottom, 10)
                    .transition(.opacity)
                }
            }
        }
    }
}

/// Centered intro for an empty chat, with suggestions that fill the composer.
struct ChatIntro: View {
    var icon: DeckIconName
    var title: String
    var message: String
    var suggestions: [String] = []
    var columnWidth: CGFloat = ChatLayout.columnWidth
    var onPick: (String) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                EmptyState(icon: icon, title: title, message: message)
                    .fixedSize(horizontal: false, vertical: true)
                if !suggestions.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            ChatSuggestion(text: suggestion) { onPick(suggestion) }
                        }
                    }
                    .padding(.top, -16)
                    .padding(.bottom, 24)
                }
            }
            .frame(maxWidth: columnWidth)
            .padding(.horizontal, Layout.pagePadding)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical, alignment: .center) { length, _ in length }
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// Suggestion under the chat intro.
struct ChatSuggestion: View {
    let text: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                DeckIcon(.sparkle, size: 13, color: DS.accent)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                DeckIcon(.chevronRight, size: 10, color: DS.textTertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .frame(maxWidth: 440)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? DS.hover : DS.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Composer

/// Rounded message field that grows to six lines, with a round send button inside.
/// Return sends, Shift Return adds a line. Stop replaces Send while an answer is coming.
struct ChatComposer<Footer: View>: View {
    @Binding var text: String
    var placeholder: String
    var canSend: Bool
    var isBusy: Bool
    var focused: FocusState<Bool>.Binding
    var columnWidth: CGFloat = ChatLayout.columnWidth
    var horizontalPadding: CGFloat = Layout.pagePadding
    var onSend: () -> Void
    /// Without it, a spinner shows while busy.
    var onStop: (() -> Void)?
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(ChatLayout.bodyFont)
                    .lineLimit(1...6)
                    .focused(focused)
                    .focusEffectDisabled()
                    .onKeyPress(.return, phases: .down) { press in handleReturn(press) }
                    .onSubmit(send)
                    .padding(.vertical, 5)
                actionButton
            }
            .padding(.leading, 16)
            .padding(.trailing, 7)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 20, style: .circular).fill(DS.surfaceRaised))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .circular)
                    .strokeBorder(focused.wrappedValue ? DS.accent.opacity(0.5) : DS.borderStrong, lineWidth: 1)
            )
            .shadow(color: DS.shadow, radius: 10, y: 3)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .circular))
            .onTapGesture { focused.wrappedValue = true }
            footer
                .font(.caption)
                .foregroundStyle(DS.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: columnWidth)
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .onAppear {
            // Focus after the first layout pass, or the field does not take it.
            Task { @MainActor in focused.wrappedValue = true }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if isBusy, let onStop {
            Button(action: onStop) {
                DeckIcon(.stop, size: 11, color: .white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(DS.accent))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: .command)
            .help("Stop")
        } else if isBusy {
            ProgressView()
                .controlSize(.small)
                .frame(width: 30, height: 30)
        } else {
            Button(action: send) {
                DeckIcon(.send, size: 15, color: .white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(canSend ? DS.accent : DS.textTertiary.opacity(0.35)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send")
        }
    }

    private func send() {
        guard canSend, !isBusy else { return }
        onSend()
        focused.wrappedValue = true
    }

    private func handleReturn(_ press: KeyPress) -> KeyPress.Result {
        // The text view behind the focused field. Key window first, any visible window after
        // (automation runs while the app is in the background).
        let editor = ((NSApp.keyWindow?.firstResponder as? NSTextView)
            ?? NSApp.windows.lazy.filter(\.isVisible).compactMap { $0.firstResponder as? NSTextView }.first)
        let composing = editor?.hasMarkedText() ?? false
        switch ChatComposerKey.action(shift: press.modifiers.contains(.shift), option: press.modifiers.contains(.option), composing: composing) {
        case .send:
            send()
            return .handled
        case .newline:
            if let editor { editor.insertNewlineIgnoringFieldEditor(nil) } else { text += "\n" }
            return .handled
        case .passThrough:
            return .ignored
        }
    }
}

/// "return to send, shift return for a new line" under the composer.
struct ChatKeyHint: View {
    var body: some View {
        HStack(spacing: 5) {
            KeyCap("return")
            Text("to send")
            KeyCap("shift return")
            Text("for a new line")
        }
    }
}

// MARK: - Messages

/// One message: a right aligned bubble for the person, a plain block with a header for the model.
struct ChatMessageView: View {
    let item: ChatItem
    let streaming: Bool
    var columnWidth: CGFloat = ChatLayout.columnWidth
    var onAction: ((ChatItem) -> Void)?

    var body: some View {
        if item.role == .user { user } else { assistant }
    }

    private var user: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 56)
            Text(item.text)
                .font(ChatLayout.bodyFont)
                .lineSpacing(2)
                .foregroundStyle(DS.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.accentSoft))
                .frame(maxWidth: columnWidth * 0.75, alignment: .trailing)
        }
    }

    private var assistant: some View {
        // Some servers send thinking apart, others inline in <think> tags.
        let split = item.reasoning.isEmpty ? ChatMarkdown.splitThinking(item.text) : (item.reasoning, item.text, false)
        let thinking = item.reasoning.isEmpty ? split.0 : item.reasoning
        let answer = split.1
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                IconBadge(item.icon, size: 22)
                Text(item.author.isEmpty ? "Assistant" : item.author)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.authorHelp ?? item.author)
                if let detail = item.authorDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(DS.textTertiary)
                        .lineLimit(1)
                }
            }
            if !thinking.isEmpty {
                ChatThinkingView(text: thinking, live: streaming && answer.isEmpty)
            }
            if item.failed {
                ChatErrorView(text: item.text, details: item.details, actionTitle: item.actionTitle,
                              action: onAction.map { handler in { handler(item) } })
            } else if streaming && answer.isEmpty && thinking.isEmpty {
                ChatTypingIndicator()
                    .padding(.vertical, 6)
            } else if !answer.isEmpty {
                ChatMarkdownView(text: answer)
            }
            if !streaming && !item.failed && !answer.isEmpty {
                HStack(spacing: 12) {
                    ChatCopyButton(text: answer)
                    if let caption = item.caption {
                        Text(caption)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(DS.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Collapsed thinking above an answer. Shows "Thinking" while it streams.
struct ChatThinkingView: View {
    let text: String
    let live: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    DeckIcon(.chevronRight, size: 9, color: DS.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(live ? "Thinking" : "Thoughts")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(DS.textSecondary)
                    if live { ChatTypingIndicator(dot: 4) }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide the model's thinking" : "Show the model's thinking")
            if expanded {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.callout)
                    .lineSpacing(2)
                    .foregroundStyle(DS.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(DS.borderStrong).frame(width: 2)
                    }
                    .padding(.leading, 3)
            }
        }
    }
}

/// Three pulsing dots.
struct ChatTypingIndicator: View {
    var dot: CGFloat = 6

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: dot * 0.7) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = sin((time * 2 * .pi / 1.1) - Double(index) * 0.7)
                    Circle()
                        .fill(DS.textSecondary)
                        .frame(width: dot, height: dot)
                        .opacity(0.3 + 0.7 * max(0, wave))
                }
            }
        }
        .accessibilityLabel("Waiting for the answer")
    }
}

/// A failed answer, with the raw error under Details and an optional button.
struct ChatErrorView: View {
    let text: String
    var details: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                DeckIcon(.error, size: 14, color: DS.danger)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(DS.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .controlSize(.small)
                }
            }
            if let details, !details.isEmpty {
                DetailsDisclosure(text: details)
                    .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).fill(DS.danger.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).strokeBorder(DS.danger.opacity(0.22), lineWidth: 1))
    }
}

/// "Details" that opens to show raw error text, closed by default.
struct DetailsDisclosure: View {
    let text: String
    var maxHeight: CGFloat = 220
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    DeckIcon(.chevronRight, size: 9, color: DS.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("Details")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(DS.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide the raw error" : "Show the raw error")
            if expanded {
                ScrollView {
                    Text(text)
                        .font(.caption.monospaced())
                        .foregroundStyle(DS.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: maxHeight)
                .background(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).fill(DS.surfaceSunken))
            }
        }
    }
}

/// Small Copy button that says Copied for a moment.
struct ChatCopyButton: View {
    let text: String
    var title = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            ResourceUsage.copyToPasteboard(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            HStack(spacing: 4) {
                DeckIcon(copied ? .success : .copy, size: 11, color: copied ? DS.running : DS.textSecondary)
                Text(copied ? "Copied" : title)
            }
            .font(.caption)
            .foregroundStyle(DS.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy to the clipboard")
    }
}

// MARK: - Markdown

/// An answer drawn from Markdown blocks.
struct ChatMarkdownView: View {
    let text: String

    var body: some View {
        let blocks = ChatMarkdown.blocks(text)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
        .tint(DS.accent)
    }

    private func inline(_ text: String) -> AttributedString {
        ChatMarkdown.inline(text, codeBackground: DS.hover)
    }

    @ViewBuilder
    private func blockView(_ block: ChatMarkdown.Block) -> some View {
        switch block {
        case .paragraph(let text):
            paragraph(text)
        case .heading(let level, let text):
            Text(inline(text))
                .font(level == 1 ? .title3.weight(.semibold) : level == 2 ? .system(size: 15, weight: .semibold) : .system(size: 14, weight: .semibold))
                .foregroundStyle(DS.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        case .list(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker)
                            .font(ChatLayout.bodyFont.monospacedDigit())
                            .foregroundStyle(DS.textSecondary)
                            .frame(minWidth: 14, alignment: .trailing)
                        paragraph(item.text)
                    }
                    .padding(.leading, CGFloat(item.indent) * 20)
                }
            }
        case .code(let language, let code):
            ChatCodeBlock(language: language, code: code)
        case .quote(let text):
            Text(inline(text))
                .font(ChatLayout.bodyFont)
                .lineSpacing(3)
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(DS.borderStrong).frame(width: 3) }
        case .table(let rows):
            ChatMarkdownTable(rows: rows, inline: inline)
        case .rule:
            Divider()
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(inline(text))
            .font(ChatLayout.bodyFont)
            .lineSpacing(3)
            .foregroundStyle(DS.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Fenced code with its language and a Copy button.
struct ChatCodeBlock: View {
    let language: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language.isEmpty ? "Code" : language)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(DS.textSecondary)
                Spacer(minLength: 0)
                ChatCopyButton(text: code)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            Rectangle().fill(DS.border).frame(height: 1)
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineSpacing(2)
                    .foregroundStyle(DS.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(12)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.smallRadius + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.smallRadius + 2, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
    }
}

/// Markdown table. First row is the header. Hugs its content, and scrolls when wider than the column.
struct ChatMarkdownTable: View {
    let rows: [[String]]
    let inline: (String) -> AttributedString

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid
                .fixedSize()
                .chatTableBox()
            ScrollView(.horizontal) { grid }
                .scrollIndicators(.automatic)
                .chatTableBox()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var grid: some View {
        let columns = rows.map(\.count).max() ?? 0
        return Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(inline(column < row.count ? row[column] : ""))
                            .font(index == 0 ? .callout.weight(.semibold) : .callout)
                            .foregroundStyle(DS.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if index == 0 {
                    Rectangle().fill(DS.border).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private extension View {
    func chatTableBox() -> some View {
        background(RoundedRectangle(cornerRadius: DS.smallRadius + 2, style: .continuous).fill(DS.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: DS.smallRadius + 2, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
    }
}
