enum Talk360DeviceShim {

    static let handlerName = "talk360Bridge"

    static func script(for methods: [String]) -> String {
        let properties = methods.map { method in
            """
            \(method): function() {
              window.webkit.messageHandlers['\(handlerName)'].postMessage({function: '\(method)', arguments: Array.from(arguments)})
            }
            """
        }
        return "window.device = {\(properties.joined(separator: ","))};"
    }
}
