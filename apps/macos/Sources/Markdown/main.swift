import AppKit
import MarkdownKit

let app = MarkdownApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
