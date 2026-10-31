import SwiftUI
import AppKit
import ControlMyMacCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.appearsActive) private var appearsActive
    @State private var airflowPasswordCopyFeedback = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    languageBox
                    airflowBox
                }
                .padding(16)
            }
            Divider()
            HStack(spacing: 8) {
                if !model.message.isEmpty {
                    Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(model.localized(.refresh)) { model.refresh() }
            }
            .padding(12)
        }
        .frame(minWidth: 580, minHeight: 440)
        .onChange(of: appearsActive, initial: true) { _, isActive in
            if isActive {
                airflowPasswordCopyFeedback = ""
            }
        }
    }

    private var languageBox: some View {
        GroupBox {
            HStack {
                Text(model.localized(.language))
                Spacer()
                Picker(model.localized(.language), selection: Binding(
                    get: { model.languagePreference },
                    set: { model.setLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName(in: model.languagePreference)).tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    private var airflowBox: some View {
        GroupBox(model.localized(.airflowLocalService)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(airflowColor).frame(width: 9, height: 9)
                    Text(model.airflowPhaseText)
                    Spacer()
                    Text(AirflowPaths.endpoint.absoluteString).font(.caption).monospaced().foregroundStyle(.secondary)
                }
                Text(model.airflowStatus.detail).font(.caption)
                    .foregroundStyle(model.airflowStatus.phase == .failed ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.airflowRecoveryGuidance).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(model.localized(.start)) { model.startAirflow() }
                        .disabled(model.airflowStatus.phase == .ready || model.airflowStatus.phase == .starting)
                    Button(model.localized(.stop)) { model.stopAirflow() }.disabled(model.airflowStatus.phase == .stopped)
                    Button(model.localized(.restart)) { model.restartAirflow() }.disabled(model.airflowStatus.phase == .stopped)
                    Button(model.localized(.open)) { model.openAirflow() }.disabled(!model.serviceOn)
                }
                .controlSize(.small)
                Divider()
                runtimeStatus
                if let credentials = model.airflowCredentials {
                    credentialsBox(credentials)
                }
                HStack(spacing: 8) {
                    Text(model.localized(.logRetention))
                    TextField("30", value: $model.airflowRetentionDays, format: .number).frame(width: 52)
                    Text(model.localized(.day)).foregroundStyle(.secondary)
                    Button(model.localized(.saveAndClean)) { model.saveAirflowRetention() }
                    Spacer()
                    Button(model.localized(.dagsDirectory)) { model.revealAirflowDAGs() }
                    Button(model.localized(.airflowLogs)) { model.revealAirflowLogs() }
                }
                .controlSize(.small)
                if let cleanup = model.airflowCleanupResult {
                    Text("\(model.localized(.recentCleanup))：\(cleanup.diagnostic)（\(cleanup.deletedItems) \(model.localized(.day))）")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(model.airflowStatus.paths.logRoot.path).font(.caption2).monospaced().foregroundStyle(.secondary)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var runtimeStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: model.pythonRuntimeStatus.available ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(model.pythonRuntimeStatus.available ? .green : .orange)
                Text(model.pythonRuntimeStatus.available
                     ? "Python \(model.pythonRuntimeStatus.version)（\(model.pythonRuntimeStatus.architecture)）"
                     : "\(model.localized(.pythonUnavailable))：\(model.pythonRuntimeStatus.lastError)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Text("\(model.localized(.pythonDependency))：\(model.pythonDependencyStatus.state)")
                .font(.caption).foregroundStyle(.secondary)
            if !model.pythonDependencyStatus.error.isEmpty {
                Text(model.pythonDependencyStatus.error).font(.caption).foregroundStyle(.orange).lineLimit(1)
            }
        }
    }

    private func credentialsBox(_ credentials: AirflowSimpleAuthCredentials) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.localized(.airflowCredentials)).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(model.localized(.username))
                Text(credentials.userName).font(.caption).monospaced()
                Spacer()
            }
            HStack(spacing: 8) {
                Text(model.localized(.password))
                if model.airflowPasswordRevealed {
                    Text(credentials.password).font(.caption).monospaced().textSelection(.enabled)
                } else {
                    Text("••••••••••••").font(.caption).monospaced().foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.airflowPasswordRevealed ? model.localized(.hidden) : model.localized(.show)) {
                    model.airflowPasswordRevealed.toggle()
                }
                Button(model.localized(.copyPassword)) {
                    airflowPasswordCopyFeedback = model.copyAirflowPassword()
                }
            }
            .controlSize(.small)
            if !airflowPasswordCopyFeedback.isEmpty {
                Text(airflowPasswordCopyFeedback)
                    .font(.caption)
                    .foregroundStyle(airflowPasswordCopyFeedback == model.localized(.passwordCopied) ? .green : .orange)
            }
        }
    }

    private var airflowColor: Color {
        switch model.airflowStatus.phase {
        case .ready: return .green
        case .starting: return .yellow
        case .failed: return .red
        case .stopped: return .secondary
        }
    }
}
