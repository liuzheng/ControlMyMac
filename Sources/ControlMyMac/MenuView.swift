import SwiftUI
import AppKit

struct MenuView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            serviceRow
            Divider()
            controls
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 360)
    }

    private var serviceRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle().fill(model.serviceColor).frame(width: 9, height: 9)
                Text(model.serviceText).font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.serviceOn },
                    set: { model.setServiceEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(model.airflowStatus.phase == .starting)
            }
            if !model.airflowStatus.detail.isEmpty {
                Text(model.airflowStatus.detail)
                    .font(.caption)
                    .foregroundStyle(model.airflowStatus.phase == .failed ? .orange : .secondary)
                    .lineLimit(2)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button(model.airflowStatus.phase == .stopped ? model.localized(.start) : model.localized(.restart)) {
                model.airflowStatus.phase == .stopped ? model.startAirflow() : model.restartAirflow()
            }
            .disabled(model.airflowStatus.phase == .starting)
            Button(model.localized(.stop)) { model.stopAirflow() }.disabled(model.airflowStatus.phase == .stopped)
            Button(model.localized(.open)) { model.openAirflow() }.disabled(!model.serviceOn)
            Button(model.localized(.logs)) { model.revealAirflowLogs() }
            Spacer()
        }
        .controlSize(.small)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.message.isEmpty {
                Text(model.message).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                SettingsLink { Text(model.localized(.settings)) }
                Spacer()
                Button(model.localized(.quit)) { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
    }
}
