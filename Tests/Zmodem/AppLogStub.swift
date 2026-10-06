import Foundation

enum AppLog {
    enum Category: String {
        case zmodem
    }

    static func verbose(_: Category, _: @autoclosure () -> String) {}
    static func info(_: Category, _: @autoclosure () -> String) {}
    static func warning(_: Category, _: @autoclosure () -> String) {}
    static func error(_: Category, _: @autoclosure () -> String) {}
}
