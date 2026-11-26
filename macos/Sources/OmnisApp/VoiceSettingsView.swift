import AppKit
import OmnisCore
import SwiftUI

/// The voice switch and how OMNIS should sound, shown from the dashboard's voice control.
struct VoiceSettingsView: View {
    @ObservedObject var voice: VoiceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $voice.isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Listen for \u{201C}Hey OMNIS\u{201D}").font(.system(size: 13, weight: .semibold))
                    Text("The microphone is used only while this is on. What is heard is turned into text on this Mac. Talk that does not begin with the phrase is thrown away at once, except in the few seconds after OMNIS has answered or asked you something, when whatever is said is taken as your reply.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            if let problem = voice.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: $voice.talkOver) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Let me talk over OMNIS").font(.system(size: 13, weight: .semibold))
                    Text("Start talking while OMNIS is answering and it stops and listens. During a conversation the Mac's echo cancelling is used so OMNIS hears less of itself, which turns other sound down a little. A yes-or-no question is always heard out.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Personality").font(.system(size: 13, weight: .semibold))
                Picker("Manner", selection: $voice.persona.preset) {
                    ForEach(VoicePersona.presets) { preset in Text(preset.title).tag(preset.id) }
                }
                .labelsHidden()
                Text("In your own words (added to the choice above)").font(.system(size: 11)).foregroundStyle(.secondary)
                TextEditor(text: $voice.persona.custom)
                    .font(.system(size: 12)).frame(height: 64)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    .accessibilityLabel("Describe how OMNIS should sound")
                    .onChange(of: voice.persona.custom) {
                        if voice.persona.custom.count > VoicePersona.maxCustomCharacters {
                            voice.persona.custom = String(voice.persona.custom.prefix(VoicePersona.maxCustomCharacters))
                        }
                    }
                Text("This changes how OMNIS talks, not what it may do.").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Speaking voice").font(.system(size: 13, weight: .semibold))
                Text(voice.voiceName).font(.system(size: 12))
                Picker("Pace", selection: $voice.speed) {
                    ForEach(VoiceModel.speeds, id: \.value) { pace in Text(pace.title).tag(pace.value) }
                }
                .pickerStyle(.segmented).labelsHidden().accessibilityLabel("How fast OMNIS talks")
                Text("OMNIS uses the best English female voice installed. Better ones are a free download: System Settings, Accessibility, Spoken Content, System Voice, Manage Voices. Look for one marked Premium, such as Ava or Zoe.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open Accessibility Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess") { NSWorkspace.shared.open(url) }
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
