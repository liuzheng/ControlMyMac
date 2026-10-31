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
                Button("刷新") { model.refresh() }
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

    private var operationBox: some View {
        GroupBox("本地操作请求（阶段一）") {
            VStack(alignment: .leading, spacing: 8) {
                Text("仅在 ControlMyMac 运行时接收请求。批准后仍需在 Terminal 使用 sudo 手动执行已审核命令。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.operationRequests.isEmpty {
                    Text("当前没有请求").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.operationRequests, id: \.id) { request in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(request.payload.operationID.rawValue).font(.caption).monospaced()
                                Spacer()
                                Text(request.state.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("请求 \(request.id.description) · 来自 \(request.origin.label)")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            if request.state == .pendingAuthorization {
                                Text("正在等待或显示系统认证提示")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("取消") { model.cancelOperationRequest(request.id) }
                                    .controlSize(.small)
                            } else if request.state == .authorized {
                                Button("查看命令") { model.previewOperationRequest(request.id) }
                                    .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 4)
                        if request.id != model.operationRequests.last?.id { Divider() }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var manualHandoffBox: some View {
        GroupBox("已审核的终端命令") {
            VStack(alignment: .leading, spacing: 8) {
                if let handoff = model.manualHandoff, let request = model.selectedOperationRequest {
                    Text(handoff.summary.title).font(.headline)
                    Text(handoff.summary.description).font(.caption).foregroundStyle(.secondary)
                    Text("请求 \(request.id.description)").font(.caption2).monospaced().foregroundStyle(.secondary)
                    Text(handoff.command).font(.caption).monospaced().textSelection(.enabled)
                        .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    Text(handoff.warning).font(.caption).foregroundStyle(.orange)
                    Button("确认并复制到剪贴板") { model.copyManualHandoff() }
                        .controlSize(.small)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var airflowBox: some View {
        GroupBox("Airflow 本地服务") {
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
                    Button("启动") { model.startAirflow() }
                        .disabled(model.airflowStatus.phase == .ready || model.airflowStatus.phase == .starting)
                    Button("停止") { model.stopAirflow() }.disabled(model.airflowStatus.phase == .stopped)
                    Button("重启") { model.restartAirflow() }.disabled(model.airflowStatus.phase == .stopped)
                    Button("打开 Airflow") { model.openAirflow() }.disabled(!model.serviceOn)
                }
                .controlSize(.small)
                Divider()
                runtimeStatus
                if let credentials = model.airflowCredentials {
                    credentialsBox(credentials)
                }
                HStack(spacing: 8) {
                    Text("日志保留")
                    TextField("30", value: $model.airflowRetentionDays, format: .number).frame(width: 52)
                    Text("天").foregroundStyle(.secondary)
                    Button("保存并清理") { model.saveAirflowRetention() }
                    Spacer()
                    Button("DAG 目录") { model.revealAirflowDAGs() }
                    Button("Airflow 日志") { model.revealAirflowLogs() }
                }
                .controlSize(.small)
                if let cleanup = model.airflowCleanupResult {
                    Text("最近清理：\(cleanup.diagnostic)（\(cleanup.deletedItems) 项）")
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
                     : "Python 3.14 不可用：\(model.pythonRuntimeStatus.lastError)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Text("Python 依赖：\(model.pythonDependencyStatus.state)")
                .font(.caption).foregroundStyle(.secondary)
            if !model.pythonDependencyStatus.error.isEmpty {
                Text(model.pythonDependencyStatus.error).font(.caption).foregroundStyle(.orange).lineLimit(1)
            }
        }
    }

    private func credentialsBox(_ credentials: AirflowSimpleAuthCredentials) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Airflow 登录凭据").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("用户名")
                Text(credentials.userName).font(.caption).monospaced()
                Spacer()
            }
            HStack(spacing: 8) {
                Text("密码")
                if model.airflowPasswordRevealed {
                    Text(credentials.password).font(.caption).monospaced().textSelection(.enabled)
                } else {
                    Text("••••••••••••").font(.caption).monospaced().foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.airflowPasswordRevealed ? "隐藏" : "显示") {
                    model.airflowPasswordRevealed.toggle()
                }
                Button("复制密码") {
                    airflowPasswordCopyFeedback = model.copyAirflowPassword()
                }
            }
            .controlSize(.small)
            if !airflowPasswordCopyFeedback.isEmpty {
                Text(airflowPasswordCopyFeedback)
                    .font(.caption)
                    .foregroundStyle(airflowPasswordCopyFeedback == "Airflow 密码已复制到剪贴板" ? .green : .orange)
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
