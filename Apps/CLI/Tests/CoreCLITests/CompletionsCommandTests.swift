import Commander
import Foundation
import Testing
@testable import PeekabooCLI

@Suite("CompletionsCommand")
struct CompletionsCommandTests {
    // MARK: - Shell Resolution

    @Test("Auto-detect defaults to zsh when SHELL is unsupported")
    func detectDefaultZsh() {
        #expect(CompletionsCommand.Shell.parse(nil) == nil)
        #expect(CompletionsCommand.Shell.parse("/bin/unknown-shell") == nil)
        #expect(CompletionsCommand.detectShell() == (CompletionsCommand.Shell.parse(
            ProcessInfo.processInfo.environment["SHELL"]
        ) ?? .zsh))
    }

    @Test("Explicit shell names and paths resolve")
    func resolveExplicitShell() throws {
        var command = CompletionsCommand()
        command.shell = "bash"
        #expect(try command.resolveShell() == .bash)

        command.shell = "/bin/zsh"
        #expect(try command.resolveShell() == .zsh)

        command.shell = "/opt/homebrew/bin/fish"
        #expect(try command.resolveShell() == .fish)

        command.shell = "/usr/local/bin/bash5"
        #expect(try command.resolveShell() == .bash)

        command.shell = "/bin/bash-old"
        #expect(try command.resolveShell() == .bash)

        command.shell = "/bin/zsh-5.8"
        #expect(try command.resolveShell() == .zsh)

        command.shell = "/bin/-bash"
        #expect(try command.resolveShell() == .bash)

        command.shell = "/bin/bash-"
        #expect(try command.resolveShell() == .bash)
    }

    @Test("Unsupported explicit shell throws validation error")
    func invalidShellThrows() {
        var command = CompletionsCommand()
        command.shell = "nushell"

        #expect(throws: ValidationError.self) {
            _ = try command.resolveShell()
        }
    }

    // MARK: - Metadata Extraction

    @Test("Document is generated from Commander descriptors")
    func documentContainsRegisteredCommands() {
        let document = CompletionScriptDocument.make(descriptors: CommanderRegistryBuilder.buildDescriptors())
        #expect(document.commandName == "peekaboo")
        #expect(document.commands.contains(where: { $0.name == "click" }))
        #expect(document.commands.contains(where: { $0.name == "completions" }))
        #expect(document.commands.contains(where: { $0.name == "help" }))
    }

    @Test("Help mirror follows the command tree")
    func helpMirrorContainsNestedCommands() {
        let document = CompletionScriptDocument.make(descriptors: CommanderRegistryBuilder.buildDescriptors())
        let help = try #require(document.commands.first(where: { $0.name == "help" }))
        let capture = try #require(help.subcommands.first(where: { $0.name == "capture" }))
        #expect(capture.subcommands.contains(where: { $0.name == "live" }))
    }

    @Test("Aliases from Commander metadata are preserved")
    func aliasesArePreserved() {
        let document = CompletionScriptDocument.make(descriptors: CommanderRegistryBuilder.buildDescriptors())
        let clickPath = try #require(document.flattenedPaths.first(where: { $0.path == ["click"] }))
        let names = Set(clickPath.options.flatMap(\.names))

        #expect(names.contains("--json"))
        #expect(names.contains("--json-output"))
        #expect(names.contains("--jsonOutput"))
        #expect(names.contains("-j"))
    }

    @Test("Argument choice metadata is generated from source types")
    func argumentChoiceMetadata() throws {
        let document = CompletionScriptDocument.make(descriptors: CommanderRegistryBuilder.buildDescriptors())
        let completionsPath = try #require(document.flattenedPaths.first(where: { $0.path == ["completions"] }))
        let shellArgument = try #require(completionsPath.arguments.first)
        let values = shellArgument.choices.map(\.value)

        #expect(values == ["zsh", "bash", "fish"])
    }

    @Test("Root options include help and version")
    func rootOptions() {
        let document = CompletionScriptDocument.make(descriptors: CommanderRegistryBuilder.buildDescriptors())
        let names = Set(document.rootOptions.flatMap(\.names))

        #expect(names.contains("--help"))
        #expect(names.contains("-h"))
        #expect(names.contains("--version"))
        #expect(names.contains("-V"))
    }

    // MARK: - Script Rendering

    @Test("Bash script uses self-contained helper functions")
    func bashScriptShape() {
        let script = CompletionScriptRenderer.render(
            document: CompletionScriptDocument.make(descriptors: CommanderRegistryBuilder.buildDescriptors()),
            for: .bash
        )

        #expect(script.contains("__peekaboo_bash_subcommands"))
        #expect(script.contains("__peekaboo_bash_options"))
        #expect(script.contains("__peekaboo_bash_argument_values"))
        #expect(script.contains("complete -F __peekaboo_bash_complete peekaboo"))
        #expect(!script.contains("_init_completion"))
    }

    @Test("Zsh script uses compdef and dynamic helpers")
    func zshScriptShape() {
        let script = CompletionScriptRenderer.render(
            document: CompletionScriptDocument.make(descriptors: CommanderRegistryBuilder.buildDescriptors()),
            for: .zsh
        )

        #expect(script.contains("#compdef peekaboo"))
        #expect(script.contains("__peekaboo_zsh_subcommands"))
        #expect(script.contains("__peekaboo_zsh_compadd_with_help"))
        #expect(script.contains("compdef _peekaboo peekaboo"))
    }

    @Test("Fish script uses dynamic completion function")
    func fishScriptShape() {
        let script = CompletionScriptRenderer.render(
            document: CompletionScriptDocument.make(descriptors: CommanderRegistryBuilder.buildDescriptors()),
            for: .fish
        )

        #expect(script.contains("function __peekaboo_fish_complete"))
        #expect(script.contains("commandline -opc"))
        #expect(script.contains("complete -c peekaboo -f -a '(__peekaboo_fish_complete)'"))
    }

    @Test("Scripts include shell argument completions")
    func scriptContainsShellChoices() {
        let bash = CompletionScriptRenderer.render(
            document: CompletionScriptDocument.make(descriptors: CommanderRegistryBuilder.buildDescriptors()),
            for: .bash
        )
        #expect(bash.contains("zsh"))
        #expect(bash.contains("bash"))
        #expect(bash.contains("fish"))
    }

    @Test("Scripts include global runtime flag aliases")
    func scriptContainsRuntimeAliases() {
        let zsh = CompletionScriptRenderer.render(
            document: CompletionScriptDocument.make(descriptors: CommanderRegistryBuilder.buildDescriptors()),
            for: .zsh
        )

        #expect(zsh.contains("--json-output"))
        #expect(zsh.contains("--log-level"))
        #expect(zsh.contains("--verbose"))
    }

    @Test("Scripts include curated option value choices")
    func scriptContainsOptionValueChoices() {
        let bash = CompletionScriptRenderer.render(
            document: CompletionScriptDocument.make(descriptors: CommanderRegistryBuilder.buildDescriptors()),
            for: .bash
        )

        #expect(bash.contains("trace"))
        #expect(bash.contains("warning"))
        #expect(bash.contains("critical"))
    }

    // MARK: - Binding and Registration

    @Test("Binder maps optional shell argument")
    func binderMapsShellArgument() throws {
        let parsed = ParsedValues(positional: ["/bin/zsh"], options: [:], flags: [])
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: CompletionsCommand.self,
            parsedValues: parsed
        )
        #expect(command.shell == "/bin/zsh")
    }

    @Test("Completions command is registered")
    func commandIsRegistered() {
        let definitions = CommandRegistry.definitions()
        let completions = definitions.first { $0.name == "completions" }
        #expect(completions != nil)
        #expect(completions?.category == .core)
    }
}
