import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case chinese
    case english

    static let userDefaultsKey = "controlmymac.language"

    var id: String { rawValue }

    var isChinese: Bool {
        resolvedLanguage == .chinese
    }

    var locale: Locale {
        Locale(identifier: isChinese ? "zh-Hans" : "en")
    }

    var resolvedLanguage: ResolvedAppLanguage {
        switch self {
        case .system:
            return Self.systemLanguage()
        case .chinese:
            return .chinese
        case .english:
            return .english
        }
    }

    func displayName(in language: AppLanguage) -> String {
        switch self {
        case .system:
            return language.isChinese ? "随系统" : "System"
        case .chinese:
            return language.isChinese ? "中文" : "Chinese"
        case .english:
            return language.isChinese ? "英文" : "English"
        }
    }

    static func load(defaults: UserDefaults = .standard) -> AppLanguage {
        guard let rawValue = defaults.string(forKey: userDefaultsKey),
              let language = AppLanguage(rawValue: rawValue) else {
            return .system
        }
        return language
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.userDefaultsKey)
    }

    private static func systemLanguage() -> ResolvedAppLanguage {
        let identifier = (Locale.preferredLanguages.first ?? Locale.current.identifier).lowercased()
        return identifier.hasPrefix("zh") || identifier.contains("-zh") ? .chinese : .english
    }
}

enum ResolvedAppLanguage {
    case chinese
    case english
}

enum AppTextKey {
    case settings
    case quit
    case start
    case restart
    case stop
    case open
    case logs
    case refresh
    case serviceReady
    case serviceStarting
    case serviceFailed
    case serviceStopped
    case phaseStopped
    case phaseStarting
    case phaseReady
    case phaseFailed
    case guidanceReady
    case guidanceStarting
    case guidanceFailed
    case guidanceStopped
    case airflowLocalService
    case language
    case logRetention
    case day
    case saveAndClean
    case dagsDirectory
    case airflowLogs
    case recentCleanup
    case pythonUnavailable
    case pythonDependency
    case airflowCredentials
    case username
    case password
    case hidden
    case show
    case copyPassword
    case passwordCopied
    case passwordUnavailable
}

enum AppLocalizer {
    static func string(_ key: AppTextKey, language: AppLanguage) -> String {
        let chinese: String
        let english: String
        switch key {
        case .settings: chinese = "设置…"; english = "Settings…"
        case .quit: chinese = "退出"; english = "Quit"
        case .start: chinese = "启动"; english = "Start"
        case .restart: chinese = "重启"; english = "Restart"
        case .stop: chinese = "停止"; english = "Stop"
        case .open: chinese = "打开"; english = "Open"
        case .logs: chinese = "日志"; english = "Logs"
        case .refresh: chinese = "刷新"; english = "Refresh"
        case .serviceReady: chinese = "Airflow 正在运行"; english = "Airflow is running"
        case .serviceStarting: chinese = "Airflow 正在启动…"; english = "Airflow is starting…"
        case .serviceFailed: chinese = "Airflow 启动失败"; english = "Airflow failed to start"
        case .serviceStopped: chinese = "Airflow 已停止"; english = "Airflow is stopped"
        case .phaseStopped: chinese = "已停止"; english = "Stopped"
        case .phaseStarting: chinese = "正在启动"; english = "Starting"
        case .phaseReady: chinese = "已就绪"; english = "Ready"
        case .phaseFailed: chinese = "启动失败"; english = "Failed to start"
        case .guidanceReady: chinese = "本地服务仅监听 127.0.0.1:50100。"; english = "The local service listens only on 127.0.0.1:50100."
        case .guidanceStarting: chinese = "正在迁移元数据并启动组件；请稍候刷新。"; english = "Metadata is being migrated and components are starting. Refresh in a moment."
        case .guidanceFailed: chinese = "检查 Airflow 服务日志，确认 Python 3.14、apache-airflow==3.3.2 和端口 50100 可用。"; english = "Check the Airflow service log and confirm that Python 3.14, apache-airflow==3.3.2, and port 50100 are available."
        case .guidanceStopped: chinese = "点击启动以运行本地 Airflow 服务。"; english = "Click Start to run the local Airflow service."
        case .airflowLocalService: chinese = "Airflow 本地服务"; english = "Local Airflow Service"
        case .language: chinese = "语言"; english = "Language"
        case .logRetention: chinese = "日志保留"; english = "Log retention"
        case .day: chinese = "天"; english = "days"
        case .saveAndClean: chinese = "保存并清理"; english = "Save and clean"
        case .dagsDirectory: chinese = "DAG 目录"; english = "DAG directory"
        case .airflowLogs: chinese = "Airflow 日志"; english = "Airflow logs"
        case .recentCleanup: chinese = "最近清理"; english = "Recent cleanup"
        case .pythonUnavailable: chinese = "Python 3.14 不可用"; english = "Python 3.14 unavailable"
        case .pythonDependency: chinese = "Python 依赖"; english = "Python dependencies"
        case .airflowCredentials: chinese = "Airflow 登录凭据"; english = "Airflow credentials"
        case .username: chinese = "用户名"; english = "Username"
        case .password: chinese = "密码"; english = "Password"
        case .hidden: chinese = "隐藏"; english = "Hide"
        case .show: chinese = "显示"; english = "Show"
        case .copyPassword: chinese = "复制密码"; english = "Copy password"
        case .passwordCopied: chinese = "Airflow 密码已复制到剪贴板"; english = "Airflow password copied to clipboard"
        case .passwordUnavailable: chinese = "Airflow 登录凭据尚不可用"; english = "Airflow credentials are not available yet"
        }
        return language.isChinese ? chinese : english
    }
}
