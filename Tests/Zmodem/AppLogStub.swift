import Foundation

enum AppLog {
    enum Category: String {
        case zmodem
    }

    static func verbose(_ category: Category, _ message: @autoclosure () -> String) {}
    static func info(_ category: Category, _ message: @autoclosure () -> String) {}
    static func warning(_ category: Category, _ message: @autoclosure () -> String) {}
    static func error(_ category: Category, _ message: @autoclosure () -> String) {}
}
