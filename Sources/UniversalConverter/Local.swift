import SwiftUI

/// Drop-in replacement for `@State`. On the macOS 27 SDK `@State` is a macro whose plugin
/// ships only with Xcode, so this keeps the app buildable with the Command Line Tools alone.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    final class Box: ObservableObject {
        @Published var value: Value
        init(_ value: Value) { self.value = value }
    }

    @StateObject private var box: Box

    init(wrappedValue: Value) { _box = StateObject(wrappedValue: Box(wrappedValue)) }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> { $box.value }
}
