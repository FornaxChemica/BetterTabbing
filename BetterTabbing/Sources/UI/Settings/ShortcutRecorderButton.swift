import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutRecorderButton: View {
    let action: ShortcutAction
    @Binding var preferences: ShortcutPreferences
    var isEnabled: Bool = true

    @State private var isRecording = false
    @State private var errorMessage: String?
    @State private var eventMonitor: Any?

    private var binding: KeyboardShortcutBinding {
        preferences.binding(for: action)
    }

    private var displayText: String {
        if isRecording {
            return "Press shortcut…"
        }
        if action == .windowSlotModifier {
            return preferences.windowSlotDisplayString
        }
        return binding.displayString
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(displayText) {
                beginRecording()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(isRecording ? .primary : .secondary)
            .disabled(!isEnabled)
            .help(isEnabled ? "Click to record a new shortcut" : "Enable this feature to change its shortcut")

            if isRecording {
                Button("Cancel") {
                    stopRecording()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .onDisappear {
            stopRecording()
        }
        .alert("Shortcut Unavailable", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func beginRecording() {
        guard isEnabled else { return }
        stopRecording()
        isRecording = true

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleRecordedEvent(event)
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func handleRecordedEvent(_ event: NSEvent) {
        let keyCode = UInt16(event.keyCode)

        if keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }

        if keyCode == UInt16(kVK_Delete) || keyCode == UInt16(kVK_ForwardDelete) {
            applyBinding(action.defaultBinding)
            stopRecording()
            return
        }

        let modifiers = KeyboardShortcutBinding.activeModifiers(from: event.modifierFlags.cgEventFlags)
        let candidate = KeyboardShortcutBinding(keyCode: keyCode, modifiers: modifiers)

        if let error = ShortcutBindingValidator.validate(candidate, for: action, in: preferences) {
            errorMessage = error
            stopRecording()
            return
        }

        applyBinding(candidate)
        stopRecording()
    }

    private func applyBinding(_ binding: KeyboardShortcutBinding) {
        var updated = preferences
        updated.setBinding(binding, for: action)
        preferences = updated
    }
}

private extension NSEvent.ModifierFlags {
    var cgEventFlags: CGEventFlags {
        var flags = CGEventFlags()
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.control) { flags.insert(.maskControl) }
        return flags
    }
}
