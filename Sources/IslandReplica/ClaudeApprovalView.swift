import AppKit
import SwiftUI

/// Settings section: broker status only. Cards live on the island itself.
struct ClaudeApprovalView: View {
    @ObservedObject var bridge: ClaudeApprovalBridge
    var body: some View {
        HStack {
            Text("Claude 审批").font(.headline)
            Spacer()
            switch bridge.state {
            case .stopped: Button("启动审批服务") { bridge.start() }
            case .starting: Text("启动中…").foregroundStyle(.secondary)
            case .ready: Text("已就绪").foregroundStyle(.secondary); Button("停止") { bridge.stop() }
            case .failed(let message):
                Text(message).foregroundStyle(.secondary).font(.caption)
                Button("重试") { bridge.start() }
            }
        }
    }
}

/// A read-only, selectable text view. AppKit copes with large inputs where SwiftUI Text does not,
/// and it always shows every character, so a long command cannot hide anything past a line limit.
struct FullTextView: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textColor = NSColor.white.withAlphaComponent(0.86)
        view.isAutomaticLinkDetectionEnabled = false; view.isAutomaticDataDetectionEnabled = false
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        view.string = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }
}

private let approvalAmber = Color(red: 1.0, green: 0.72, blue: 0.27)
private let approvalGreen = Color(red: 0.30, green: 0.85, blue: 0.47)
private let approvalRed = Color(red: 1.0, green: 0.42, blue: 0.40)

/// The approval card shown on the island. Only its buttons can produce a decision.
struct ApprovalCard: View {
    @ObservedObject var bridge: ClaudeApprovalBridge
    let request: ClaudeApprovalRequest
    @State private var showRaw = false
    @State private var picked: [String: Set<String>] = [:]

    private var title: String {
        if let command = request.command { return command }
        if let path = request.filePath { return path }
        return request.toolName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if request.isQuestion { questions } else { detail }
            actions
        }
        .padding(12)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(approvalAmber.opacity(0.35)))
    }

    private var header: some View {
        HStack(spacing: 7) {
            Text(request.agentName).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            Text(request.toolName).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(approvalAmber)
                .padding(.horizontal, 7).padding(.vertical, 2).background(approvalAmber.opacity(0.14), in: Capsule())
            if !request.projectName.isEmpty { Text(request.projectName).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.62)).lineLimit(1) }
            if request.isSubagent { Text(request.agentType ?? "子 Agent").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.45)) }
            Spacer(minLength: 6)
            Text(String(request.sessionID.prefix(8))).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.3))
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let summary = request.summary, !summary.isEmpty {
                Text(summary).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
            }
            if let hint = request.hint { hintView(hint) }
            // The input is always shown complete, however long. The primary field is unpacked so
            // real line breaks read naturally; the raw JSON is one click away for everything else.
            FullTextView(text: showRaw || request.command == nil && request.filePath == nil ? request.toolInputText : primaryText)
                .frame(minHeight: 70, maxHeight: 220)
                .background(Color.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 9))
            Button(showRaw ? "只看主要内容" : "查看完整输入（JSON）") { showRaw.toggle() }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.white.opacity(0.42))
                .opacity(request.command == nil && request.filePath == nil ? 0 : 1)
        }
    }

    private var primaryText: String { request.command ?? request.filePath ?? request.toolInputText }

    /// Every row is one line, which is what lets the panel know how much room this takes.
    private func hintView(_ hint: ClaudeApprovalHint) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(hint.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(approvalAmber).lineLimit(1).frame(height: 16, alignment: .leading)
            Text(ClaudeApprovalHint.subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).frame(height: 14, alignment: .leading)
            ForEach(Array(hint.removals.enumerated()), id: \.offset) { _, removal in
                Text(removal.statement).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1).truncationMode(.middle).frame(height: 15, alignment: .leading)
                ForEach(Array(removal.values.enumerated()), id: \.offset) { _, value in
                    Text(value).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1).truncationMode(.middle).padding(.leading, 12).frame(height: 13, alignment: .leading)
                }
            }
            if let more = hint.hiddenText {
                Text(more).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).frame(height: 14, alignment: .leading)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(approvalAmber.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private var questions: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(request.questions, id: \.question) { item in
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.question).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    ForEach(item.options, id: \.label) { option in
                        let chosen = picked[item.question]?.contains(option.label) == true
                        Button { toggle(item, option.label) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Image(systemName: chosen ? "largecircle.fill.circle" : "circle").font(.system(size: 11))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.label).font(.system(size: 11.5, weight: .medium))
                                    if !option.detail.isEmpty { Text(option.detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)) }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(chosen ? approvalAmber.opacity(0.2) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(option.label)
                    }
                }
            }
        }
    }

    private func toggle(_ item: ClaudeApprovalQuestion, _ label: String) {
        var current = picked[item.question] ?? []
        if item.multiSelect {
            if current.contains(label) { current.remove(label) } else { current.insert(label) }
        } else {
            current = [label]
        }
        picked[item.question] = current
    }

    private var everyQuestionAnswered: Bool {
        request.questions.allSatisfy { picked[$0.question]?.isEmpty == false }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if request.isSubmitting {
                Text("正在交给 \(request.source == "claude" ? "Claude" : request.agentName)…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            } else if request.allowIsIgnoredByClaude {
                Text("在终端中审批").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
            // While the hook runs Codex shows no prompt of its own, so this is the way back to it.
            if request.source == "codex" {
                Button("回到 Codex 处理") { bridge.handBack(nonce: request.id) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.62)).disabled(request.isSubmitting)
            }
            Spacer(minLength: 0)
            actionButton("拒绝", tint: approvalRed, enabled: !request.isSubmitting) { bridge.decide(nonce: request.id, allow: false) }
            if request.isQuestion {
                actionButton("提交回答", tint: approvalGreen, enabled: !request.isSubmitting && everyQuestionAnswered) {
                    var answers: [String: String] = [:]
                    for item in request.questions {
                        let chosen = item.options.map(\.label).filter { picked[item.question]?.contains($0) == true }
                        answers[item.question] = chosen.joined(separator: ", ")
                    }
                    bridge.answer(nonce: request.id, answers: answers)
                }
            } else if !request.allowIsIgnoredByClaude {
                if !request.suggestions.isEmpty {
                    Menu("始终允许") {
                        ForEach(request.suggestions, id: \.index) { suggestion in
                            Button(suggestion.label) { bridge.decideAlways(nonce: request.id, suggestion: suggestion.index) }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize().font(.system(size: 12, weight: .semibold))
                    .disabled(request.isSubmitting)
                }
                actionButton("允许一次", tint: approvalGreen, enabled: !request.isSubmitting) { bridge.decide(nonce: request.id, allow: true) }
            }
        }
    }

    private func actionButton(_ label: String, tint: Color, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(enabled ? tint : tint.opacity(0.35))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(tint.opacity(enabled ? 0.16 : 0.06), in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(.plain).disabled(!enabled).accessibilityLabel(label)
    }
}

/// A short, truthful line about what just happened to a request.
struct ApprovalOutcomeLine: View {
    let outcome: ClaudeApprovalOutcome
    private var tint: Color {
        switch outcome.kind {
        case .success: return approvalGreen
        case .warning: return approvalAmber
        case .info: return .white.opacity(0.6)
        }
    }
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(outcome.text).font(.system(size: 11, weight: .medium)).foregroundStyle(tint).lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}
