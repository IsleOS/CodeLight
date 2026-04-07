//
//  MessageRow.swift
//  CodeLight
//
//  Renders a single chat event (assistant reply, tool call, thinking bubble,
//  terminal output, etc.). Lives in its own file so ChatView stays focused on
//  the high-level layout and so edits here don't blow up the turnaround time
//  on a 1600-line file.
//

import SwiftUI
import UIKit

struct MessageRow: View {
    @EnvironmentObject var appState: AppState
    let message: ChatMessage
    @State private var hasAppeared = false

    var body: some View {
        let parsed = parseContent(message.content)

        HStack(alignment: .top, spacing: 10) {
            // Unified 18x18 icon rail on the left so every event type lines up
            // vertically. One width/weight across the board.
            Image(systemName: roleIcon(parsed.type))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(roleColor(parsed.type))
                .frame(width: 18, height: 18)
                .padding(.top, 4)

            // Body. The old uppercase role label is gone — the icon rail already
            // carries identity, and the per-event visual styling (bubble, dot,
            // border) makes the type obvious without repeating it in text.
            VStack(alignment: .leading, spacing: 0) {
                switch parsed.type {
                case "tool":
                    toolView(parsed)
                case "thinking":
                    thinkingView(parsed)
                case "interrupted":
                    interruptedView
                case "terminal_output":
                    terminalOutputView(parsed)
                case "assistant":
                    assistantView(parsed)
                default:
                    if !parsed.text.isEmpty {
                        markdownContent(parsed.text)
                    }
                    if !parsed.imageBlobIds.isEmpty {
                        attachmentsView(blobIds: parsed.imageBlobIds)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 4)
        .onAppear {
            withAnimation(.easeOut(duration: 0.22)) { hasAppeared = true }
        }
    }

    // MARK: - Assistant Bubble

    @ViewBuilder
    private func assistantView(_ parsed: ParsedMessage) -> some View {
        // Solid brand card with near-black text — high contrast, single block.
        VStack(alignment: .leading, spacing: 4) {
            if !parsed.text.isEmpty {
                markdownContent(parsed.text)
            }
            if !parsed.imageBlobIds.isEmpty {
                attachmentsView(blobIds: parsed.imageBlobIds)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.brand, in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(Theme.onBrand)
        .tint(Theme.onBrand)
    }

    // MARK: - Interrupted

    @ViewBuilder
    private var interruptedView: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 10, weight: .medium))
            Text(String(localized: "interrupted_by_user"))
                .font(.caption)
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func attachmentsView(blobIds: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(blobIds, id: \.self) { id in
                    if let data = appState.sentImageCache[id],
                       let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 120, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.systemGray5))
                            .frame(width: 120, height: 120)
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                            )
                    }
                }
            }
        }
    }

    // MARK: - Markdown Rendering

    @ViewBuilder
    private func markdownContent(_ text: String) -> some View {
        let parts = splitCodeBlocks(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                if part.isCode {
                    codeBlockView(part)
                } else if !part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocksView(part.text)
                }
            }
        }
    }

    /// Render a non-code chunk by splitting it into block-level markdown
    /// elements (headings, lists, blockquotes, rules, paragraphs) and styling
    /// each block. Inline markdown inside each block is still handled by
    /// AttributedString — only block-level structure is parsed manually.
    @ViewBuilder
    private func blocksView(_ text: String) -> some View {
        let blocks = parseMarkdownBlocks(text)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(level))
                .fontWeight(.semibold)
                .padding(.top, level <= 2 ? 4 : 2)
        case .bullet(let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                inlineText(text)
                    .font(.subheadline)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(indent) * 12)
        case .ordered(let indent, let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                inlineText(text)
                    .font(.subheadline)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(indent) * 12)
        case .quote(let text):
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))
                inlineText(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .italic()
                Spacer(minLength: 0)
            }
        case .rule:
            Divider()
                .padding(.vertical, 2)
        case .paragraph(let text):
            inlineText(text)
                .font(.subheadline)
        case .table(let rows, let hasHeader):
            tableView(rows: rows, hasHeader: hasHeader)
        }
    }

    @ViewBuilder
    private func tableView(rows: [[String]], hasHeader: Bool) -> some View {
        // Subtle border-only treatment; inherits parent foreground color so the
        // table text stays readable both inside the green assistant bubble and
        // in the default message context. The old filled gray background
        // clashed with the green bubble.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        inlineText(cell)
                            .font(.system(size: 12, weight: hasHeader && idx == 0 ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    hasHeader && idx == 0
                        ? Color.primary.opacity(0.06)
                        : (idx.isMultiple(of: 2) ? Color.primary.opacity(0.03) : Color.clear)
                )
                if idx < rows.count - 1 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(height: 0.5)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
        )
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        default: return .subheadline
        }
    }

    /// Render inline-only markdown (bold, italic, code, links) as a Text view.
    @ViewBuilder
    private func inlineText(_ text: String) -> some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed).textSelection(.enabled)
        } else {
            Text(text).textSelection(.enabled)
        }
    }

    // MARK: - Block-Level Markdown Parsing

    fileprivate enum MarkdownBlock {
        case heading(level: Int, text: String)
        case bullet(indent: Int, text: String)
        case ordered(indent: Int, number: String, text: String)
        case quote(text: String)
        case rule
        case paragraph(text: String)
        case table(rows: [[String]], hasHeader: Bool)
    }

    /// Walk lines and classify each as a block-level element. Consecutive
    /// paragraph lines collapse into a single paragraph block (joined with
    /// newlines so AttributedString can preserve soft wraps).
    private func parseMarkdownBlocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            if !paragraphBuffer.isEmpty {
                let joined = paragraphBuffer.joined(separator: "\n")
                if !joined.trimmingCharacters(in: .whitespaces).isEmpty {
                    blocks.append(.paragraph(text: joined))
                }
                paragraphBuffer.removeAll()
            }
        }

        // Split on \n; we want to preserve order and handle empty lines as
        // paragraph breaks (already implicit since empty lines don't match any
        // pattern and just get filtered out of paragraphBuffer).
        let lines = text.components(separatedBy: "\n")

        var i = 0
        while i < lines.count {
            let rawLine = lines[i]

            // Empty/whitespace-only line → paragraph break
            if rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Horizontal rule: --- *** ___ on a line by themselves
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 3,
               trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            // GFM table: a row of pipe-delimited cells immediately followed by
            // a separator row like `| --- | --- |`. Both lines are required —
            // a single `|...|` line by itself stays a paragraph.
            if isPipeRow(rawLine),
               i + 1 < lines.count,
               isTableSeparator(lines[i + 1]) {
                flushParagraph()
                var rows: [[String]] = [parseTableRow(rawLine)]
                i += 2 // skip header and separator
                while i < lines.count, isPipeRow(lines[i]) {
                    rows.append(parseTableRow(lines[i]))
                    i += 1
                }
                // Normalize column count so missing trailing cells render as empty.
                let columnCount = rows.map(\.count).max() ?? 0
                let normalized = rows.map { row -> [String] in
                    if row.count < columnCount {
                        return row + Array(repeating: "", count: columnCount - row.count)
                    }
                    return row
                }
                blocks.append(.table(rows: normalized, hasHeader: true))
                continue
            }

            // ATX heading: 1-6 # then space then text
            if let heading = matchHeading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                i += 1
                continue
            }

            // Blockquote: leading > then optional space then text
            if trimmed.hasPrefix(">") {
                flushParagraph()
                let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                blocks.append(.quote(text: text))
                i += 1
                continue
            }

            // Unordered list: leading whitespace + (-|*|+) + space
            if let bullet = matchBullet(rawLine) {
                flushParagraph()
                blocks.append(.bullet(indent: bullet.indent, text: bullet.text))
                i += 1
                continue
            }

            // Ordered list: leading whitespace + digits + . + space
            if let ordered = matchOrdered(rawLine) {
                flushParagraph()
                blocks.append(.ordered(indent: ordered.indent, number: ordered.number, text: ordered.text))
                i += 1
                continue
            }

            // Default: paragraph line
            paragraphBuffer.append(rawLine)
            i += 1
        }

        flushParagraph()
        return blocks
    }

    /// True if the line looks like a row of pipe-delimited cells (`|a|b|`).
    /// Lenient: accepts missing leading/trailing pipes too as long as there is
    /// at least one interior pipe.
    private func isPipeRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && !trimmed.isEmpty
    }

    /// True if the line is a GFM table separator: `| --- | :---: | ---: |`.
    private func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return false }
        // Each cell must be all dashes with optional leading/trailing colons.
        let cells = parseTableRow(trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let stripped = cell.replacingOccurrences(of: ":", with: "")
                               .trimmingCharacters(in: .whitespaces)
            return !stripped.isEmpty && stripped.allSatisfy { $0 == "-" }
        }
    }

    /// Parse a `|a|b|c|` row into cell strings. Strips leading/trailing pipes
    /// and trims each cell.
    private func parseTableRow(_ line: String) -> [String] {
        var content = line.trimmingCharacters(in: .whitespaces)
        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|") { content.removeLast() }
        return content
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func matchHeading(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
            if level > 6 { return nil }
        }
        guard level >= 1, level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        // Must have at least one space separating # from text
        guard let first = rest.first, first == " " || first == "\t" else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (level, text)
    }

    private func matchBullet(_ line: String) -> (indent: Int, text: String)? {
        // Count leading spaces (tab = 4 spaces) for indent level
        var spaces = 0
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == " " { spaces += 1 }
            else if ch == "\t" { spaces += 4 }
            else { break }
            i = line.index(after: i)
        }
        guard i < line.endIndex else { return nil }
        let marker = line[i]
        guard marker == "-" || marker == "*" || marker == "+" else { return nil }
        let after = line.index(after: i)
        guard after < line.endIndex, line[after] == " " else { return nil }
        let text = String(line[line.index(after: after)...])
        let indent = spaces / 2 // 2 spaces per nesting level
        return (indent, text)
    }

    private func matchOrdered(_ line: String) -> (indent: Int, number: String, text: String)? {
        var spaces = 0
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == " " { spaces += 1 }
            else if ch == "\t" { spaces += 4 }
            else { break }
            i = line.index(after: i)
        }
        var digits = ""
        while i < line.endIndex, line[i].isNumber {
            digits.append(line[i])
            i = line.index(after: i)
        }
        guard !digits.isEmpty, i < line.endIndex, line[i] == "." else { return nil }
        let afterDot = line.index(after: i)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        let text = String(line[line.index(after: afterDot)...])
        let indent = spaces / 2
        return (indent, digits, text)
    }

    private func codeBlockView(_ part: TextPart) -> some View {
        // Fixed dark editor-like palette. Explicit foreground colors override
        // any inherited `.foregroundStyle` from a parent bubble (e.g. the green
        // assistant card sets `.onBrand` which is near-black — unreadable on a
        // dark code background).
        let codeBg = Color(red: 0x0E / 255, green: 0x10 / 255, blue: 0x14 / 255)
        let codeText = Color.white.opacity(0.92)
        let codeDim = Color.white.opacity(0.55)

        return VStack(alignment: .leading, spacing: 0) {
            if !part.language.isEmpty {
                HStack {
                    Text(part.language)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(codeDim)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = part.text
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                            .foregroundStyle(codeDim)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 2)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(part.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(codeText)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .background(codeBg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - Tool / Thinking Views

    private func toolView(_ parsed: ParsedMessage) -> some View {
        let status = parsed.toolStatus?.lowercased() ?? ""
        let isRunning = status == "running" || status == "pending"
        let color = statusColor(status)

        // Single-line chip, no card, no accent bar, no shimmer. The timeline
        // rail + left icon already carry the "tool event" signal; this view
        // only needs to name the tool and show status. Keeps multi-tool bursts
        // dense instead of eating half the screen.
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if isRunning {
                    PulseDot(color: color, size: 6)
                } else {
                    Image(systemName: status == "error" || status == "failed"
                          ? "xmark.circle.fill"
                          : "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(color)
                }
                Image(systemName: toolIcon(parsed.toolName ?? ""))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(parsed.toolName ?? "tool")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            if !parsed.text.isEmpty {
                Text(parsed.text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    private func thinkingView(_ parsed: ParsedMessage) -> some View {
        // The left-side rail icon already shows a brain — don't repeat it here.
        HStack(spacing: 6) {
            if parsed.text.isEmpty {
                ThinkingDots(color: .purple)
            } else {
                Text(parsed.text)
                    .font(.system(size: 12))
                    .italic()
                    .lineLimit(3)
            }
        }
        .foregroundStyle(.purple.opacity(0.9))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Code Block Parsing

    private struct TextPart {
        let text: String
        let isCode: Bool
        let language: String
    }

    private func splitCodeBlocks(_ text: String) -> [TextPart] {
        var parts: [TextPart] = []
        let pattern = "```(\\w*)\\n([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [TextPart(text: text, isCode: false, language: "")]
        }

        let nsText = text as NSString
        var lastEnd = 0
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            let beforeRange = NSRange(location: lastEnd, length: match.range.location - lastEnd)
            if beforeRange.length > 0 {
                parts.append(TextPart(text: nsText.substring(with: beforeRange), isCode: false, language: ""))
            }
            let lang = match.numberOfRanges > 1 ? nsText.substring(with: match.range(at: 1)) : ""
            let code = match.numberOfRanges > 2 ? nsText.substring(with: match.range(at: 2)) : ""
            parts.append(TextPart(text: code, isCode: true, language: lang))
            lastEnd = match.range.location + match.range.length
        }

        if lastEnd < nsText.length {
            parts.append(TextPart(text: nsText.substring(from: lastEnd), isCode: false, language: ""))
        }

        return parts.isEmpty ? [TextPart(text: text, isCode: false, language: "")] : parts
    }

    // MARK: - Parse

    private struct ParsedMessage {
        let type: String
        let text: String
        let toolName: String?
        let toolStatus: String?
        let imageBlobIds: [String]
        let command: String?     // For terminal_output messages
    }

    private func parseContent(_ content: String) -> ParsedMessage {
        if let data = content.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = dict["type"] as? String {
            var blobIds: [String] = []
            if let images = dict["images"] as? [[String: Any]] {
                blobIds = images.compactMap { $0["blobId"] as? String }
            }
            return ParsedMessage(
                type: type,
                text: dict["text"] as? String ?? "",
                toolName: dict["toolName"] as? String,
                toolStatus: dict["toolStatus"] as? String,
                imageBlobIds: blobIds,
                command: dict["command"] as? String
            )
        }
        return ParsedMessage(type: "user", text: content, toolName: nil, toolStatus: nil, imageBlobIds: [], command: nil)
    }

    // MARK: - Terminal Output View

    @ViewBuilder
    private func terminalOutputView(_ parsed: ParsedMessage) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(roleColor("terminal_output"))
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
            VStack(alignment: .leading, spacing: 4) {
                if let cmd = parsed.command {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                        Text(cmd)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(parsed.text)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(minWidth: 0, alignment: .leading)
                }
            }
            .padding(.leading, 10)
            .padding(.vertical, 6)
            .padding(.trailing, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Style Helpers

    private func roleColor(_ type: String) -> Color {
        switch type {
        case "user": return Theme.info
        case "assistant": return Theme.brand
        case "thinking": return .purple
        case "tool": return .cyan
        case "interrupted": return Theme.danger
        case "terminal_output": return Theme.warning
        default: return Theme.textTertiary
        }
    }

    private func roleIcon(_ type: String) -> String {
        switch type {
        case "user": return "person.crop.circle.fill"
        case "assistant": return "sparkle"
        case "thinking": return "brain.head.profile"
        case "tool": return "hammer.fill"
        case "interrupted": return "exclamationmark.octagon.fill"
        case "terminal_output": return "apple.terminal.fill"
        default: return "circle.fill"
        }
    }

    private func roleLabel(_ type: String) -> String {
        switch type {
        case "user": return String(localized: "role_you")
        case "assistant": return String(localized: "role_claude")
        case "thinking": return String(localized: "role_thinking")
        case "tool": return String(localized: "role_tool")
        case "interrupted": return String(localized: "role_interrupted")
        case "terminal_output": return "TERMINAL"
        default: return type
        }
    }

    private func toolIcon(_ name: String) -> String {
        switch name.lowercased() {
        case "bash": return "terminal"
        case "read": return "doc.text"
        case "write": return "doc.badge.plus"
        case "edit": return "pencil"
        case "glob": return "folder.badge.magnifyingglass"
        case "grep": return "magnifyingglass"
        case "agent": return "person.2"
        case "task": return "checklist"
        default: return "gearshape"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "success", "completed": return Theme.brand
        case "error", "failed": return Theme.danger
        case "running", "pending": return Theme.warning
        default: return Theme.textSecondary
        }
    }
}
