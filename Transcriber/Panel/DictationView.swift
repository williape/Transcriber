//
//  DictationView.swift
//  Transcriber
//

import SwiftUI

/// Panel content. Phase 2: placeholder; Phase 3 replaces the placeholder text
/// with committed (.primary) + volatile (.secondary) transcription.
struct DictationView: View {
    static let panelSize = NSSize(width: 420, height: 64)

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .font(.system(size: 20))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, isActive: true)
            Text("Listening…")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            Spacer()
            Text("esc to cancel")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .frame(width: Self.panelSize.width, height: Self.panelSize.height, alignment: .leading)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12))
        )
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

#Preview {
    DictationView()
}
