import Foundation

/// The two UI languages the app ships. Raw values are stable identifiers shared by
/// UserDefaults, the /config endpoint, and the viewer's ?lang= override.
enum AppLanguage: String, CaseIterable {
    case zh
    case en

    /// Pure so the fallback rule is testable without touching system preferences.
    static func resolvingSystemLanguage(_ preferredLanguages: [String]) -> AppLanguage {
        (preferredLanguages.first ?? "en").hasPrefix("zh") ? .zh : .en
    }

    static var systemDefault: AppLanguage { resolvingSystemLanguage(Locale.preferredLanguages) }

    /// Native names stay constant in both modes so the picker is always readable.
    var displayName: String { self == .zh ? "中文" : "English" }
}

/// The app process's current language. The MCP subprocess never reads this: it runs
/// as its own process and learns the language from GET /config instead.
final class AppLanguageStore {
    static let shared = AppLanguageStore()
    static let didChangeNotification = Notification.Name("AppLanguageStore.didChange")
    static let defaultsKey = "IPHONE_USE_LANGUAGE"

    private let lock = NSLock()
    private var current: AppLanguage
    private let defaults: UserDefaults

    /// Read from AppKit, the HTTP handler queue, and shortcut background work.
    var language: AppLanguage { lock.withLock { current } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        current =
            defaults.string(forKey: Self.defaultsKey).flatMap(AppLanguage.init(rawValue:))
            ?? AppLanguage.systemDefault
    }

    /// Always persists an explicit choice; only notifies observers when the language changes.
    func set(_ language: AppLanguage) {
        defaults.set(language.rawValue, forKey: Self.defaultsKey)
        guard language != self.language else { return }
        lock.withLock { current = language }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}

/// Hand-written per-language tables. Stored properties keep both languages complete
/// at compile time; parameterized strings are closures.
protocol LocalizedTable {
    static var zh: Self { get }
    static var en: Self { get }
}

extension LocalizedTable {
    init(language: AppLanguage) { self = language == .zh ? .zh : .en }
}
