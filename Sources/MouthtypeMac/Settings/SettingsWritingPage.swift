import SwiftUI

extension SettingsView {
    /// The redesigned Style page. The old Writing page's groups live on in `StylePage`: the default tone is the Other tab, app and website
    /// rules are the contexts, and the switches are in the marked section at the bottom until Advanced takes them.
    var styleContent: some View {
        StylePage(model: model, actions: actions)
    }
}
