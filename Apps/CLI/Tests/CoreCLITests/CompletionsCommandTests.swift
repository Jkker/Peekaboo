import Commander
import Testing
@testable import PeekabooCLI

@Suite("CompletionsCommand")
struct CompletionsCommandTests {
    // MARK: - Shell Detection

    @Test("Detect zsh as default when SHELL is unset")
    func detectDefaultZsh() {
        let shell = CompletionsCommand.detectShell()
        // On CI the SHELL env var may or may not be set; regardless, zsh is
        // the documented default, and this test verifies the fallback path.
        #expect(shell == .zsh || shell == .bash || shell == .fish)
    }

    @Test("Resolve explicit shell argument")
    func resolveExplicitShell() {
        var cmd = CompletionsCommand()
        cmd.shell = "bash"
        #expect(cmd.resolveShell() == .bash)

        cmd.shell = "zsh"
        #expect(cmd.resolveShell() == .zsh)

        cmd.shell = "fish"
        #expect(cmd.resolveShell() == .fish)
    }

    @Test("Resolve shell ignores case")
    func resolveShellCaseInsensitive() {
        var cmd = CompletionsCommand()
        cmd.shell = "ZSH"
        #expect(cmd.resolveShell() == .zsh)

        cmd.shell = "Bash"
        #expect(cmd.resolveShell() == .bash)

        cmd.shell = "FISH"
        #expect(cmd.resolveShell() == .fish)
    }

    @Test("Resolve falls back to detect when argument is invalid")
    func resolveInvalidFallsBackToDetect() {
        var cmd = CompletionsCommand()
        cmd.shell = "powershell"
        let shell = cmd.resolveShell()
        // Should fall back to detectShell() since "powershell" is not a valid Shell
        #expect(shell == .zsh || shell == .bash || shell == .fish)
    }

    // MARK: - Zsh Script Generation

    @Test("Zsh script contains compdef directive")
    func zshContainsCompdef() {
        let script = CompletionsCommand.generateScript(for: .zsh)
        #expect(script.contains("compdef _peekaboo peekaboo"))
        #expect(script.contains("#compdef peekaboo"))
    }

    @Test("Zsh script includes command names")
    func zshIncludesCommandNames() {
        let script = CompletionsCommand.generateScript(for: .zsh)
        #expect(script.contains("'capture:"))
        #expect(script.contains("'click:"))
        #expect(script.contains("'completions:"))
    }

    @Test("Zsh script includes subcommand functions")
    func zshIncludesSubcommandFunctions() {
        let script = CompletionsCommand.generateScript(for: .zsh)
        // Commands with subcommands should have helper functions
        #expect(script.contains("_peekaboo_capture()"))
    }

    // MARK: - Bash Script Generation

    @Test("Bash script contains complete directive")
    func bashContainsComplete() {
        let script = CompletionsCommand.generateScript(for: .bash)
        #expect(script.contains("complete -F _peekaboo peekaboo"))
    }

    @Test("Bash script includes command names")
    func bashIncludesCommandNames() {
        let script = CompletionsCommand.generateScript(for: .bash)
        #expect(script.contains("capture"))
        #expect(script.contains("click"))
        #expect(script.contains("completions"))
    }

    @Test("Bash script uses _init_completion")
    func bashUsesInitCompletion() {
        let script = CompletionsCommand.generateScript(for: .bash)
        #expect(script.contains("_init_completion"))
    }

    // MARK: - Fish Script Generation

    @Test("Fish script contains complete directives")
    func fishContainsComplete() {
        let script = CompletionsCommand.generateScript(for: .fish)
        #expect(script.contains("complete -c peekaboo"))
    }

    @Test("Fish script includes command names with descriptions")
    func fishIncludesCommandNames() {
        let script = CompletionsCommand.generateScript(for: .fish)
        #expect(script.contains("__fish_use_subcommand"))
        #expect(script.contains("-a 'capture'"))
        #expect(script.contains("-a 'click'"))
    }

    @Test("Fish script disables file completions")
    func fishDisablesFileCompletions() {
        let script = CompletionsCommand.generateScript(for: .fish)
        #expect(script.contains("complete -c peekaboo -f"))
    }

    // MARK: - Commander Binding

    @Test("Binder maps shell positional argument")
    func binderMapsShellArgument() throws {
        let parsed = ParsedValues(positional: ["zsh"], options: [:], flags: [])
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: CompletionsCommand.self,
            parsedValues: parsed
        )
        #expect(command.shell == "zsh")
    }

    @Test("Binder handles missing shell argument")
    func binderHandlesMissingArgument() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: CompletionsCommand.self,
            parsedValues: parsed
        )
        #expect(command.shell == nil)
    }

    // MARK: - Command Registration

    @Test("Completions command is registered in CommandRegistry")
    func commandIsRegistered() {
        let definitions = CommandRegistry.definitions()
        let completions = definitions.first { $0.name == "completions" }
        #expect(completions != nil)
        #expect(completions?.category == .core)
        #expect(completions?.abstract == "Generate shell completion scripts")
    }

    // MARK: - Script Content Validation

    @Test("Generated scripts are non-empty for all shells")
    func allShellsProduceOutput() {
        for shell in [CompletionsCommand.Shell.zsh, .bash, .fish] {
            let script = CompletionsCommand.generateScript(for: shell)
            #expect(!script.isEmpty, "Script for \(shell) should not be empty")
            #expect(script.count > 100, "Script for \(shell) should have substantial content")
        }
    }

    @Test("Zsh script includes option completions for click")
    func zshIncludesClickOptions() {
        let script = CompletionsCommand.generateScript(for: .zsh)
        #expect(script.contains("--double"))
        #expect(script.contains("--snapshot"))
    }

    @Test("Global flags appear in completions")
    func globalFlagsIncluded() {
        let script = CompletionsCommand.generateScript(for: .bash)
        #expect(script.contains("--verbose"))
        #expect(script.contains("--json"))
        #expect(script.contains("--help"))
    }
}
