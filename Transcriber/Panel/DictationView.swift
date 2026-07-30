//
//  DictationView.swift
//  Transcriber
//

import SwiftUI

/// Panel content: live transcript (committed .primary + volatile .secondary),
/// model download progress, or a listening placeholder.
struct DictationView: View {
    let appState: AppState

    static let panelSize = NSSize(width: 460, height: 132)

    var body: some View {
        content
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(width: Self.panelSize.width, height: Self.panelSize.height)
            .background(VisualEffectBackground())
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.12))
            )
    }

    @ViewBuilder
    private var content: some View {
        switch appState.session {
        case .downloadingModel(let progress):
            progressView(label: "Downloading speech model…", progress: progress)
        case .transcribingFile(let progress):
            progressView(label: "Transcribing file…", progress: progress)
        default:
            if let notice = appState.notice {
                noticeView(notice)
            } else {
                transcriptView
            }
        }
    }

    private func noticeView(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.slash")
                .font(.system(size: 16))
            Text(text)
                .font(.system(size: 14))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func progressView(label: String, progress: Double?) -> some View {
        VStack(spacing: 8) {
            Text(progress.map { "\(label) \(Int($0 * 100))%" } ?? label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            // A nil value makes this indeterminate, which is the honest thing to
            // show before the first fraction arrives.
            ProgressView(value: progress)
        }
    }

    private var transcriptView: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(isRecording ? Color.red : Color.secondary)
                    .symbolEffect(.pulse, isActive: isRecording)
                if isRecording {
                    LevelMeterView(level: appState.audioLevel)
                }
            }
            .padding(.top, 2)

            ScrollView(.vertical) {
                Group {
                    if appState.committedText.isEmpty && appState.volatileText.isEmpty {
                        Text(isRecording ? "Listening…" : "…")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(Text(appState.committedText))\(Text(appState.volatileText).foregroundStyle(.secondary))")
                    }
                }
                .font(.system(size: 15))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)

            VStack(alignment: .trailing) {
                if appState.session == .finishing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("esc to cancel")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
    }

    private var isRecording: Bool {
        appState.session == .recording
    }
}

/// Compact 5-segment mic input meter.
struct LevelMeterView: View {
    let level: Double

    private static let segments = 5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.segments, id: \.self) { index in
                Capsule()
                    .fill(Double(index) / Double(Self.segments) < level
                          ? AnyShapeStyle(.tint)
                          : AnyShapeStyle(.quaternary))
                    .frame(width: 3, height: 8)
            }
        }
        .animation(.linear(duration: 0.1), value: level)
    }
}

/// System blur/translucency behind the panel content.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
