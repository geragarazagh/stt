// The widget extension: the recording's Live Activity (Dynamic Island, Lock Screen) and the Record control (Action
// Button, Control Centre, Lock Screen). It only draws; every action runs in the app, which holds the one state.
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main struct STTWidgets: WidgetBundle {
    var body: some Widget {
        RecordingActivity()
        RecordControl()
    }
}

// The recording outside the app, after Voice Memos' own island (his video 2026-11-11): compact = the live red wave alone;
// expanded = one row, the wave, the red time, Stop in a white ring; no words, so nothing wraps on any iPhone. Stop
// opens STT and stops there. The Lock Screen keeps the same row with the app's name over it.
struct RecordingActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingAttributes.self) { ctx in
            VStack(alignment: .leading, spacing: 8) {
                Text("STT").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    IslandWave(levels: ctx.state.levels, first: ctx.state.first, bars: 22).frame(height: 34)
                    Clock(started: ctx.state.started, size: 28)
                    StopButton(size: 46)
                }
            }
            .padding(14)
            .activitySystemActionForegroundColor(.red)
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        IslandWave(levels: ctx.state.levels, first: ctx.state.first, bars: 20).frame(height: 40)
                        Clock(started: ctx.state.started, size: 30)
                        StopButton(size: 52)
                    }
                    .padding(.horizontal, 8)
                }
            } compactLeading: {
                IslandWave(levels: ctx.state.levels, first: ctx.state.first, bars: 6).frame(width: 26, height: 16)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                IslandWave(levels: ctx.state.levels, first: ctx.state.first, bars: 4).frame(width: 18, height: 14)
            }
            .keylineTint(.red)
        }
    }
}

// The red running time, rounded figures as Voice Memos'.
struct Clock: View {
    var started: Date, size: CGFloat
    var body: some View {
        Text(started, style: .timer)
            .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(.red)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: size * 3.4, alignment: .trailing)
            .lineLimit(1)
    }
}

// Apple's stop control: a red square in a white ring (Voice Memos' island). Opens STT and stops.
struct StopButton: View {
    var size: CGFloat
    var body: some View {
        Button(intent: StopFromIsland()) {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: size * 0.07)
                RoundedRectangle(cornerRadius: size * 0.1, style: .continuous).fill(.red).frame(width: size * 0.42, height: size * 0.42)
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Stop Recording"))
    }
}

struct RecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Shared.controlKind, provider: RecordingState()) { recording in
            ControlWidgetToggle("Record", isOn: recording, action: ToggleRecording()) { on in
                // STT's own sign, the wave of its icon (his word 2026-11-11: not a copy of an Apple app's glyph); stop
                // while recording.
                Group {
                    if on { Label("Recording", systemImage: "stop.fill") } else { Label("Record", image: "stt.wave") }
                }
                .controlWidgetActionHint(on ? "Stop Recording" : "Record")
            }
            .tint(.red)   // the record red in Control Centre and in the Dynamic Island when the Action Button runs it
        }
        .displayName("Record")
        .description("Starts a recording, or stops it and gives its text.")
    }
}

struct RecordingState: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool { Shared.recording }
}

