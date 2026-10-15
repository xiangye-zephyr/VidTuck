import Cocoa

let controller = AppController()
if let flag = CommandLine.arguments.firstIndex(of: "--test-support"), CommandLine.arguments.count > flag + 1 {
    controller.supportOverride = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    controller.uiTestMode = true
}
NSApplication.shared.delegate = controller
NSApplication.shared.run()
