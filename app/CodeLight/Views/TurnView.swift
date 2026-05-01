//
//  TurnView.swift
//  CodeLight
//
//  Renders one conversation turn — a user question header (collapsible) and
//  the stack of Claude replies underneath on a shared timeline rail with
//  rhythmic spacing. Also hosts QuestionNavSheet, the pull-up list that
//  jumps between turns.
//

import SwiftUI
import UIKit

struct TurnView: View {
    @EnvironmentObject var appState: AppState
    let turn: ConversationTurn
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // User question header — minimal: a 2pt brand accent bar on the left,
            // monospaced YOU label, and the question text. No avatar circle.
            if turn.userMessage != nil {
                Button(action: onToggle) {
                    HStack(alignment: .top, spacing: 10) {
                        Rectangle()
                            .fill(Theme.brand)
                            .frame(width: 2)
                            .clipShape(RoundedRectangle(cornerRadius: 1))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("YOU")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .tracking(1.0)
                                .foregroundStyle(Theme.brand)
                            if !turn.questionText.isEmpty {
                                Text(turn.questionText)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(isExpanded ? nil : 2)
                                    .multilineTextAlignment(.leading)
                            }
                            if !turn.questionImageBlobIds.isEmpty {
                                userImageStrip(turn.questionImageBlobIds)
                            }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, 2)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                // Initial replies (no user message)
                HStack(spacing: 6) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 10, weight: .medium))
                    Text(turn.questionText)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.5)
                        .textCase(.uppercase)
                }
                .foregroundStyle(Theme.textTertiary)
                .padding(.vertical, 4)
            }

            // Replies (collapsible) with a timeline rail + rhythmic spacing.
            if isExpanded {
                repliesTimeline
                    .padding(.leading, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if !turn.replies.isEmpty {
                // Collapsed summary
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down.circle")
                        .font(.system(size: 10, weight: .medium))
                    Text("\(turn.replies.count) \(String(localized: "replies"))")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
            }
        }
    }

    /// Replies stacked with a continuous timeline rail behind the icon column and
    /// rhythmic spacing — tight between same-type consecutive events, wider at
    /// type transitions — so the eye can parse grouped activity at a glance.
    @ViewBuilder
    private var repliesTimeline: some View {
        ZStack(alignment: .topLeading) {
            // The rail sits behind the 18pt icon column in MessageRow. Icons start
            // at x=0 of MessageRow, are 18pt wide, so center is x=9.
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 1)
                .padding(.leading, 9)
                .padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(turn.replies.enumerated()), id: \.element.id) { idx, reply in
                    MessageRow(message: reply)
                        .padding(.top, spacingBefore(idx))
                }
            }
        }
    }

    /// Vertical gap to put above message at index `idx`.
    ///   - 0 for the first message
    ///   - 2pt for consecutive same-type events (tight group — tool bursts)
    ///   - 10pt for a type transition (breathing room)
    private func spacingBefore(_ idx: Int) -> CGFloat {
        guard idx > 0 else { return 0 }
        let prev = messageType(turn.replies[idx - 1])
        let cur = messageType(turn.replies[idx])
        return prev == cur ? 2 : 10
    }

    private func messageType(_ msg: ChatMessage) -> String {
        ChatContentParser.parse(msg.content).type
    }

    /// Horizontal strip of image thumbnails for the user's attached photos.
    /// Pulls bytes from `appState.sentImageCache` (populated when the message
    /// was sent), falls back to a placeholder photo icon for cache misses
    /// (e.g. session re-opened after process restart — server has already
    /// purged the blob).
    @ViewBuilder
    private func userImageStrip(_ blobIds: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(blobIds, id: \.self) { id in
                    if let data = appState.sentImageCache[id],
                       let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.systemGray5))
                            .frame(width: 96, height: 96)
                            .overlay(
                                VStack(spacing: 4) {
                                    Image(systemName: "photo")
                                        .font(.system(size: 20))
                                        .foregroundStyle(.secondary)
                                    Text("Sent")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                            )
                    }
                }
            }
        }
        .frame(height: 96)
    }
}

// MARK: - Question Navigation Sheet

struct QuestionNavSheet: View {
    let turns: [ConversationTurn]
    let isLoadingAll: Bool
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if isLoadingAll {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "loading_earlier"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if turns.isEmpty && !isLoadingAll {
                    ContentUnavailableView(
                        String(localized: "no_questions_yet"),
                        systemImage: "questionmark.bubble"
                    )
                } else {
                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                        Button {
                            onSelect(turn.anchorId)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.white)
                                    .frame(width: 22, height: 22)
                                    .background(.blue, in: Circle())

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(turn.questionText)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(3)
                                        .multilineTextAlignment(.leading)

                                    if turn.replies.count > 0 {
                                        Text("\(turn.replies.count) \(String(localized: "replies"))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                Image(systemName: "arrow.up.forward")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(String(localized: "jump_to_question"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) { dismiss() }
                }
            }
        }
    }
}
