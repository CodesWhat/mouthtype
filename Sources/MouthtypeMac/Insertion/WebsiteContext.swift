import Foundation

// Only the document URL exposed by the focused browser window is used. No history,
// address-bar scraping, scripts, titles, URL persistence or extra permissions.
enum WebsiteContext {
    static func supports(bundleID: String?) -> Bool {
        ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser"].contains(bundleID ?? "")
    }

    static func host(document: String?, bundleID: String?) -> String? {
        guard supports(bundleID: bundleID), let document,
            let url = URLComponents(string: document),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.user == nil, url.password == nil, let host = url.host
        else { return nil }
        return AppCleanupStyles.normalizedDomain(host)
    }
}
