import AppKit

final class UtilitiesService: Service {
    static let shared = UtilitiesService()

    private static let sound = ToolArgument<Sound>.choice("sound", default: .default)

    var tools: [Tool] {
        Tool(
            name: "utilities_beep",
            description: "Play one of the built-in macOS alert sounds through the speakers",
            arguments: [Self.sound],
            annotations: .init(
                title: "Play System Sound",
                readOnlyHint: false,
                destructiveHint: false,
                openWorldHint: false
            )
        ) { arguments in
            NSSound.play(try Self.sound(arguments))
        }
    }
}
