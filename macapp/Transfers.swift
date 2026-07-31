import SwiftUI

/// The bottom pane: what is transferring now, and what recently finished.
struct TransfersPane: View {
    @ObservedObject var store: RelayStore
    @Binding var tab: Tab
    /// The row ⌘⌫ acts on. Nil means nothing is selected and the shortcut
    /// deliberately does nothing.
    @Binding var selected: Int?

    /// FileZilla's three queue tabs, verbatim labels.
    enum Tab: String, CaseIterable, Identifiable {
        case queued = "Queued files"
        case failed = "Failed transfers"
        case done = "Successful transfers"
        var id: String { rawValue }
    }

    @State private var logJob: Job?
    @State private var logText: String = ""
    @State private var verifyJob: Job?
    @State private var verifyResult: VerifyResult?
    @State private var verifyBusy = false

    private func count(_ t: Tab) -> Int {
        switch t {
        case .queued: return store.active.count
        case .failed: return store.recent.filter { $0.kind == .failed || $0.kind == .cancelled }.count
        case .done: return store.recent.filter { $0.kind == .done }.count
        }
    }

    /// Extracted from the ForEach body on purpose: with all seven closures inline
    /// the expression exceeded the type-checker's budget and the build failed with
    /// "unable to type-check this expression in reasonable time".
    @ViewBuilder
    private func row(_ job: Job) -> some View {
        JobRow(job: job,
               onCancel: { Task { await store.cancel(job.id) } },
               onDismiss: { Task { await store.dismiss(job.id) } },
               onRetry: { Task { _ = await store.retry(job.id) } },
               isSelected: tab == .queued && selected == job.id,
               onSelect: { selected = job.id },
               onLog: { openLog(job) },
               onVerify: { openVerify(job) })
    }

    private var rows: [Job] {
        switch tab {
        case .queued: return store.active
        case .failed: return store.recent.filter { $0.kind == .failed || $0.kind == .cancelled }
        case .done: return store.recent.filter { $0.kind == .done }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if rows.isEmpty {
                    empty
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { job in
                                row(job)
                                Divider().overlay(Theme.hairline.opacity(0.6))
                            }
                        }
                    }
                }
            }
            // The queue's row area is the SAME surface as the two file lists, so all
            // three read as one material. FileZilla does the same: its queue list is
            // #0D0D0D like the file lists, and only the panel around it is lighter.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.listFill)

            // FileZilla puts the queue's tabs at the BOTTOM (wxAUI_NB_BOTTOM).
            Divider().overlay(Theme.hairline)
            tabStrip
        }
        .background(Theme.cardFill)
        .sheet(item: $logJob) { job in
            LogSheet(job: job, text: logText) { logJob = nil }
        }
        .sheet(item: $verifyJob) { job in
            VerifySheet(job: job, result: verifyResult, busy: verifyBusy) { verifyJob = nil }
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { t in
                let n = count(t)
                Button { tab = t } label: {
                    HStack(spacing: 5) {
                        Text(t.rawValue).font(.system(size: 11.5, weight: tab == t ? .medium : .regular))
                        if n > 0 {
                            Text("\(n)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(tab == t ? Color.primary : Color.primary.opacity(0.62))
                    .padding(.horizontal, 10).frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(tab == t ? Theme.pillFillHover : .clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text(queueSummary).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    /// FileZilla's status area says "Queue: empty" when there is nothing to do.
    private var queueSummary: String {
        store.active.isEmpty ? "Queue: empty" : "Queue: \(store.active.count) transferring"
    }

    private var emptyText: String {
        switch tab {
        case .queued: return "Nothing transferring"
        case .failed: return "No failed transfers"
        case .done: return "No completed transfers yet"
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: tab == .queued ? "tray" : "clock.arrow.circlepath")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.tertiary)
            Text(emptyText)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openLog(_ job: Job) {
        logText = "Loading…"
        logJob = job
        Task {
            if case .text(let t) = await store.api.log(job.id) { logText = t }
            else { logText = "Could not read the log." }
        }
    }

    private func openVerify(_ job: Job) {
        verifyResult = nil
        verifyBusy = true
        verifyJob = job
        Task {
            switch await store.api.verify(job.id) {
            case .result(let v): verifyResult = v
            case .refused(let w), .unreachable(let w): store.show(w, isError: true)
            }
            verifyBusy = false
        }
    }
}

private func copyText(_ s: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(s, forType: .string)
}

private struct JobRow: View {
    let job: Job
    let onCancel: () -> Void
    let onDismiss: () -> Void
    var onRetry: () -> Void = { }
    var isSelected: Bool = false
    var onSelect: () -> Void = { }
    let onLog: () -> Void
    let onVerify: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: job.symbol)
                .font(.system(size: 13))
                .foregroundStyle(job.tint.color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(job.destName)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    Text("j\(job.id)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if job.kind == .running || job.kind == .queued {
                    ProgressView(value: max(0.004, job.percent), total: 100)
                        .progressViewStyle(.linear)
                        .frame(height: 3)
                        // Mirrors the icon's two-stop gradient: the blue stop for a
                        // transfer actually moving, the indigo one for a transfer
                        // still waiting its turn.
                        .tint(job.kind == .running ? Theme.accent : Theme.accentIndigo)
                }
                Text(job.progressText)
                    // The line you actually read while a transfer runs, so it is
                    // sized to be read at a glance from across the desk rather than
                    // to match the secondary metadata around it. Still under the
                    // 12.5 medium filename above, which stays the row's headline.
                    .font(.system(size: 12))
                    .foregroundStyle(job.kind == .failed ? Color(nsColor: .systemRed) : .secondary)
                    .lineLimit(1).truncationMode(.tail)
                Text(job.destPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
            }

            Spacer(minLength: 6)

            HStack(spacing: 2) {
                if job.isActive {
                    ChromeButton(symbol: "xmark.circle", help: "Stop this transfer", action: onCancel)
                }
                if job.kind == .done {
                    ChromeButton(symbol: "checkmark.seal", help: "Verify file counts", action: onVerify)
                }
                if job.kind == .failed {
                    ChromeButton(symbol: "arrow.clockwise",
                                 help: "Queue this transfer again", action: onRetry)
                }
                ChromeButton(symbol: "doc.text", help: "Open the rclone log", action: onLog)
                if !job.isActive {
                    ChromeButton(symbol: "eye.slash", help: "Clear from this list", action: onDismiss)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Theme.accentSoft : .clear)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .contextMenu {
            if job.isActive {
                Button("Stop Transfer", action: onCancel)
                Divider()
            }
            if job.kind == .done {
                Button("Verify File Counts", action: onVerify)
            }
            Button("Open rclone Log", action: onLog)
            Divider()
            Button("Copy Source Path") { copyText(job.src) }
            Button("Copy Destination Path") { copyText(job.destPath) }
            if !job.isActive {
                Divider()
                if job.kind == .failed { Button("Try Again", action: onRetry) }
                Button("Remove from List", action: onDismiss)
            }
        }
    }
}

private struct LogSheet: View {
    let job: Job
    let text: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Log — j\(job.id) \(job.destName)")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
                .padding(.bottom, 10)
            ScrollView {
                Text(text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 340)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.cardFill))
            HStack {
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 620)
    }
}

private struct VerifySheet: View {
    let job: Job
    let result: VerifyResult?
    let busy: Bool
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Verify — j\(job.id)")
                .font(.system(size: 13, weight: .semibold))
            Text("Walks both trees and counts files. rclone's own totals are what lied "
                 + "once before, so this is the check that actually catches a silent drop.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Walking both sides…").font(.system(size: 11.5))
                }
                .padding(.vertical, 6)
            } else if let result {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(result.ok ? StatusTint.good.color : StatusTint.bad.color)
                        Text(result.summary)
                            .font(.system(size: 12, weight: .medium))
                    }
                    Text(result.src.path).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    Text(result.dest.path).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.cardFill))
            }

            HStack {
                Spacer()
                Button("Close", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 470)
    }
}
