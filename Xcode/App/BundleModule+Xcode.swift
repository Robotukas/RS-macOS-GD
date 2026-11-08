import Foundation

// Xcode-only shim. SwiftPM synthesises `Bundle.module` for the executable target; the Xcode app
// target compiles Sources/GDHub directly and copies Sources/GDHub/Resources flat into
// Contents/Resources, which is `Bundle.main`.
extension Bundle {
    static var module: Bundle { .main }
}
