import Foundation

public enum AppInfo {
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "MouthtypeDisplayVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
