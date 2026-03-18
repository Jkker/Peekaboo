import Commander
import Foundation

/// Shell-completion document rendered from Commander metadata.
///
/// `CompletionScriptDocument` is the single source of truth for completion
/// generation. It is derived from `CommanderCommandDescriptor` values, which are
/// already the canonical source for help output and command discovery.
struct CompletionScriptDocument: Sendable {
    let commandName: String
    let commands: [CompletionCommand]
    let rootOptions: [CompletionOption]

    var topLevelChoices: [CompletionChoice] {
        self.commands.map { command in
            CompletionChoice(value: command.name, help: command.abstract)
        }
    }

    var flattenedPaths: [CompletionPath] {
        self.commands.flatMap { command in
            command.flattenedPaths(prefix: [])
        }
    }

    var pathsIncludingRoot: [CompletionPath] {
        [
            CompletionPath(
                path: [],
                subcommands: self.topLevelChoices,
                options: self.rootOptions,
                arguments: []
            ),
        ] + self.flattenedPaths
    }

    static func make(
        commandName: String = "peekaboo",
        descriptors: [CommanderCommandDescriptor]
    ) -> CompletionScriptDocument {
        let commands = descriptors
            .sorted { $0.metadata.name < $1.metadata.name }
            .map { CompletionCommand(descriptor: $0, path: [$0.metadata.name]) }

        let helpMirror = CompletionCommand.helpMirror(commands: commands)
        return CompletionScriptDocument(
            commandName: commandName,
            commands: [helpMirror] + commands,
            rootOptions: [
                .flag(names: ["-h", "--help"], help: "Show help information"),
                .flag(names: ["-V", "--version"], help: "Show version information"),
            ]
        )
    }
}

struct CompletionCommand: Sendable {
    let name: String
    let abstract: String
    let arguments: [CompletionArgument]
    let options: [CompletionOption]
    let subcommands: [CompletionCommand]

    var subcommandChoices: [CompletionChoice] {
        self.subcommands.map { command in
            CompletionChoice(value: command.name, help: command.abstract)
        }
    }

    init(descriptor: CommanderCommandDescriptor, path: [String]) {
        self.name = descriptor.metadata.name
        self.abstract = descriptor.metadata.abstract
        self.arguments = descriptor.metadata.signature.arguments.enumerated().map { index, argument in
            CompletionArgument(
                label: argument.label,
                isOptional: argument.isOptional,
                choices: CompletionValueCatalog.argumentChoices(for: path, index: index, label: argument.label)
            )
        }
        self.options = Self.makeOptions(from: descriptor.metadata.signature, path: path)
        self.subcommands = descriptor.subcommands
            .sorted { $0.metadata.name < $1.metadata.name }
            .map { subcommand in
                CompletionCommand(descriptor: subcommand, path: path + [subcommand.metadata.name])
            }
    }

    private init(
        name: String,
        abstract: String,
        arguments: [CompletionArgument],
        options: [CompletionOption],
        subcommands: [CompletionCommand]
    ) {
        self.name = name
        self.abstract = abstract
        self.arguments = arguments
        self.options = options
        self.subcommands = subcommands
    }

    func flattenedPaths(prefix: [String]) -> [CompletionPath] {
        let path = prefix + [self.name]
        let current = CompletionPath(
            path: path,
            subcommands: self.subcommandChoices,
            options: self.options,
            arguments: self.arguments
        )
        return [current] + self.subcommands.flatMap { subcommand in
            subcommand.flattenedPaths(prefix: path)
        }
    }

    static func helpMirror(commands: [CompletionCommand]) -> CompletionCommand {
        CompletionCommand(
            name: "help",
            abstract: "Show help for commands",
            arguments: [],
            options: [],
            subcommands: commands.map { command in
                CompletionCommand(
                    name: command.name,
                    abstract: command.abstract,
                    arguments: [],
                    options: [],
                    subcommands: helpSubcommands(from: command.subcommands)
                )
            }
        )
    }

    private static func helpSubcommands(from commands: [CompletionCommand]) -> [CompletionCommand] {
        commands.map { command in
            CompletionCommand(
                name: command.name,
                abstract: command.abstract,
                arguments: [],
                options: [],
                subcommands: helpSubcommands(from: command.subcommands)
            )
        }
    }

    private static func makeOptions(from signature: CommandSignature, path: [String]) -> [CompletionOption] {
        let flags = signature.flags.map { flag in
            CompletionOption.flag(
                names: uniqueNames(flag.names.map(\.completionSpelling)),
                help: flag.help ?? "No description provided"
            )
        }

        let options = signature.options.map { option in
            let names = uniqueNames(option.names.map(\.completionSpelling))
            return CompletionOption.option(
                names: names,
                valueName: option.label,
                help: option.help ?? "No description provided",
                valueChoices: CompletionValueCatalog.optionChoices(
                    for: path,
                    label: option.label,
                    names: names
                )
            )
        }

        return flags + options + [
            .flag(names: ["-h", "--help"], help: "Show help information"),
        ]
    }

    private static func uniqueNames(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for name in names where !seen.contains(name) {
            seen.insert(name)
            ordered.append(name)
        }
        return ordered
    }
}

struct CompletionPath: Sendable {
    let path: [String]
    let subcommands: [CompletionChoice]
    let options: [CompletionOption]
    let arguments: [CompletionArgument]

    var key: String {
        self.path.joined(separator: " ")
    }
}

struct CompletionArgument: Sendable {
    let label: String
    let isOptional: Bool
    let choices: [CompletionChoice]
}

struct CompletionOption: Sendable {
    let names: [String]
    let help: String
    let valueName: String?
    let valueChoices: [CompletionChoice]

    var takesValue: Bool { self.valueName != nil }

    static func flag(names: [String], help: String) -> CompletionOption {
        CompletionOption(names: names, help: help, valueName: nil, valueChoices: [])
    }

    static func option(names: [String], valueName: String, help: String, valueChoices: [CompletionChoice]) -> CompletionOption {
        CompletionOption(names: names, help: help, valueName: valueName, valueChoices: valueChoices)
    }
}

/// A single suggested completion value with optional help text.
///
/// `CompletionChoice` is used for subcommands and curated value suggestions for
/// positional arguments or option values.
struct CompletionChoice: Sendable {
    let value: String
    let help: String?
}

/// Central registry for curated completion values that cannot be inferred from
/// Commander metadata alone.
///
/// Most command structure comes directly from descriptors. This catalog is only
/// for constrained value sets such as `completions [shell]` or `--log-level`.
enum CompletionValueCatalog {
    static func argumentChoices(for path: [String], index: Int, label: String) -> [CompletionChoice] {
        if path == ["completions"], index == 0, label == "shell" {
            return CompletionsCommand.Shell.allCases.map { shell in
                CompletionChoice(value: shell.rawValue, help: shell.helpText)
            }
        }
        return []
    }

    static func optionChoices(for path: [String], label: String, names: [String]) -> [CompletionChoice] {
        if names.contains("--log-level"), label == "logLevel" {
            return LogLevel.allCases.map { level in
                CompletionChoice(value: level.cliValue, help: nil)
            }
        }
        return []
    }
}

/// Dispatches shell-completion rendering to the appropriate shell-specific
/// renderer.
enum CompletionScriptRenderer {
    static func render(document: CompletionScriptDocument, for targetShell: CompletionsCommand.Shell) -> String {
        switch targetShell {
        case .bash:
            BashCompletionRenderer().render(document: document)
        case .zsh:
            ZshCompletionRenderer().render(document: document)
        case .fish:
            FishCompletionRenderer().render(document: document)
        }
    }
}

private protocol ShellCompletionRendering {
    func render(document: CompletionScriptDocument) -> String
}

/// Renders a self-contained bash completion script that queries shared
/// completion tables emitted from Swift metadata.
private struct BashCompletionRenderer: ShellCompletionRendering {
    func render(document: CompletionScriptDocument) -> String {
        let lines = self.commonHeader(
            shell: "bash",
            install: CompletionsCommand.Shell.bash.installationSnippet
        ) + [
            "__peekaboo_bash_subcommands() {",
            self.renderBashChoiceSwitch(document.pathsIncludingRoot, accessor: \.subcommands),
            "}",
            "",
            "__peekaboo_bash_options() {",
            self.renderBashOptionSwitch(document: document),
            "}",
            "",
            "__peekaboo_bash_argument_values() {",
            self.renderBashArgumentSwitch(document.pathsIncludingRoot),
            "}",
            "",
            "__peekaboo_bash_option_values() {",
            self.renderBashOptionValueSwitch(document.pathsIncludingRoot),
            "}",
            "",
            "__peekaboo_bash_has_subcommand() {",
            "    local path=\"$1\"",
            "    local candidate=\"$2\"",
            "    while IFS=$'\\t' read -r value _; do",
            "        [[ \"$value\" == \"$candidate\" ]] && return 0",
            "    done < <(__peekaboo_bash_subcommands \"$path\")",
            "    return 1",
            "}",
            "",
            "__peekaboo_bash_complete() {",
            "    local cur=\"${COMP_WORDS[COMP_CWORD]}\"",
            "    local path=\"\"",
            "    local index=1",
            "    local previous=\"\"",
            "    local token",
            "    COMPREPLY=()",
            "",
            "    while (( index < COMP_CWORD )); do",
            "        token=\"${COMP_WORDS[index]}\"",
            "        [[ \"$token\" == -* ]] && break",
            "        if __peekaboo_bash_has_subcommand \"$path\" \"$token\"; then",
            "            path=\"${path:+$path }$token\"",
            "            (( index++ ))",
            "        else",
            "            break",
            "        fi",
            "    done",
            "",
            "    if (( COMP_CWORD > 0 )); then",
            "        previous=\"${COMP_WORDS[COMP_CWORD - 1]}\"",
            "    fi",
            "",
            "    local option_values",
            "    option_values=\"$(__peekaboo_bash_option_values \"$path\" \"$previous\" | cut -f1 | tr '\\n' ' ')\"",
            "    if [[ -n \"$option_values\" ]]; then",
            "        COMPREPLY=($(compgen -W \"$option_values\" -- \"$cur\"))",
            "        return",
            "    fi",
            "",
            "    if [[ \"$cur\" == -* ]]; then",
            "        COMPREPLY=($(compgen -W \"$(__peekaboo_bash_options \"$path\" | cut -f1 | tr '\\n' ' ')\" -- \"$cur\"))",
            "        return",
            "    fi",
            "",
            "    local subcommands",
            "    subcommands=\"$(__peekaboo_bash_subcommands \"$path\" | cut -f1 | tr '\\n' ' ')\"",
            "    if [[ -n \"$subcommands\" ]]; then",
            "        COMPREPLY=($(compgen -W \"$subcommands\" -- \"$cur\"))",
            "        return",
            "    fi",
            "",
            "    local argument_index=$(( COMP_CWORD - index ))",
            "    local values",
            "    values=\"$(__peekaboo_bash_argument_values \"$path\" \"$argument_index\" | cut -f1 | tr '\\n' ' ')\"",
            "    if [[ -n \"$values\" ]]; then",
            "        COMPREPLY=($(compgen -W \"$values\" -- \"$cur\"))",
            "    fi",
            "}",
            "",
            "complete -F __peekaboo_bash_complete \(document.commandName)",
        ]

        return lines.joined(separator: "\n")
    }

    private func renderBashChoiceSwitch(
        _ paths: [CompletionPath],
        accessor: KeyPath<CompletionPath, [CompletionChoice]>
    ) -> String {
        var lines = ["    case \"$1\" in"]
        lines.append(contentsOf: self.renderCases(paths: paths) { path in
            path[keyPath: accessor].map { choice in
                self.tabSeparated(choice.value, choice.help)
            }
        })
        lines.append(contentsOf: [
            "        *)",
            "            ;;",
            "    esac",
        ])
        return lines.joined(separator: "\n")
    }

    private func renderBashOptionSwitch(document: CompletionScriptDocument) -> String {
        var lines = ["    case \"$1\" in", "        '')"]
        lines.append(contentsOf: self.heredocLines(items: document.rootOptions.map { option in
            option.names.map { name in
                self.tabSeparated(name, option.help)
            }
        }.flatMap { $0 }, indent: "            "))
        lines.append("            ;;")
        lines.append(contentsOf: self.renderCases(paths: document.flattenedPaths) { path in
            path.options.flatMap { option in
                option.names.map { name in
                    self.tabSeparated(name, option.help)
                }
            }
        })
        lines.append(contentsOf: [
            "        *)",
            "            ;;",
            "    esac",
        ])
        return lines.joined(separator: "\n")
    }

    private func renderBashArgumentSwitch(_ paths: [CompletionPath]) -> String {
        var lines = ["    case \"$1:$2\" in"]
        for path in paths {
            for (index, argument) in path.arguments.enumerated() where !argument.choices.isEmpty {
                lines.append("        '\(self.caseLabel(path.key)):\(index)')")
                lines.append(contentsOf: self.heredocLines(items: argument.choices.map {
                    self.tabSeparated($0.value, $0.help)
                }, indent: "            "))
                lines.append("            ;;")
            }
        }
        lines.append(contentsOf: [
            "        *)",
            "            ;;",
            "    esac",
        ])
        return lines.joined(separator: "\n")
    }

    private func renderBashOptionValueSwitch(_ paths: [CompletionPath]) -> String {
        var lines = ["    case \"$1:$2\" in"]
        for path in paths {
            for option in path.options where !option.valueChoices.isEmpty {
                for name in option.names {
                    lines.append("        '\(self.caseLabel(path.key)):\(self.caseLabel(name))')")
                    lines.append(contentsOf: self.heredocLines(items: option.valueChoices.map {
                        self.tabSeparated($0.value, $0.help)
                    }, indent: "            "))
                    lines.append("            ;;")
                }
            }
        }
        lines.append(contentsOf: [
            "        *)",
            "            ;;",
            "    esac",
        ])
        return lines.joined(separator: "\n")
    }

    private func renderCases(
        paths: [CompletionPath],
        content: (CompletionPath) -> [String]
    ) -> [String] {
        paths.map { path in
            let items = content(path)
            if items.isEmpty {
                return [
                    "        '\(self.caseLabel(path.key))')",
                    "            ;;",
                ]
            }
            return [
                "        '\(self.caseLabel(path.key))')",
            ] + self.heredocLines(items: items, indent: "            ") + [
                "            ;;",
            ]
        }.flatMap { $0 }
    }

    private func heredocLines(items: [String], indent: String) -> [String] {
        guard !items.isEmpty else { return [] }
        return [
            "\(indent)cat <<'EOF'",
        ] + items + [
            "EOF",
        ]
    }

    private func tabSeparated(_ value: String, _ help: String?) -> String {
        let tab = "\t"
        let description = (help ?? "").replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        return "\(value)\(tab)\(description)"
    }

    private func caseLabel(_ label: String) -> String {
        label.replacingOccurrences(of: "'", with: "'\\''")
    }

    private func commonHeader(shell: String, install: String) -> [String] {
        [
            "# \(shell.capitalized) completion for peekaboo",
            "# Generated from Commander descriptors via `peekaboo completions \(shell)`.",
            "# Install with:",
            "#   \(install)",
            "",
        ]
    }
}

/// Renders a zsh completion script using `compdef` plus dynamic helper
/// functions backed by the shared completion document.
private struct ZshCompletionRenderer: ShellCompletionRendering {
    func render(document: CompletionScriptDocument) -> String {
        let lines = [
            "#compdef \(document.commandName)",
            "# Zsh completion for peekaboo",
            "# Generated from Commander descriptors via `peekaboo completions zsh`.",
            "# Install with:",
            "#   \(CompletionsCommand.Shell.zsh.installationSnippet)",
            "",
            "__peekaboo_zsh_subcommands() {",
            self.renderZshChoiceSwitch(document.pathsIncludingRoot, accessor: \.subcommands),
            "}",
            "",
            "__peekaboo_zsh_options() {",
            self.renderZshOptionSwitch(document: document),
            "}",
            "",
            "__peekaboo_zsh_argument_values() {",
            self.renderZshArgumentSwitch(document.pathsIncludingRoot),
            "}",
            "",
            "__peekaboo_zsh_option_values() {",
            self.renderZshOptionValueSwitch(document.pathsIncludingRoot),
            "}",
            "",
            "__peekaboo_zsh_has_subcommand() {",
            "    local path=\"$1\"",
            "    local candidate=\"$2\"",
            "    local line value description",
            "    while IFS=$'\\t' read -r value description; do",
            "        [[ \"$value\" == \"$candidate\" ]] && return 0",
            "    done < <(__peekaboo_zsh_subcommands \"$path\")",
            "    return 1",
            "}",
            "",
            "__peekaboo_zsh_compadd_with_help() {",
            "    local line value description",
            "    local -a values descriptions",
            "    while IFS=$'\\t' read -r value description; do",
            "        values+=(\"$value\")",
            "        descriptions+=(\"$description\")",
            "    done",
            "    if (( ${#values[@]} == 0 )); then",
            "        return 1",
            "    fi",
            "    compadd -Q -d descriptions -- \"${values[@]}\"",
            "}",
            "",
            "_peekaboo() {",
            "    local path=\"\"",
            "    local index=2",
            "    local token current_word previous_word",
            "    current_word=\"${words[CURRENT]}\"",
            "",
            "    while (( index < CURRENT )); do",
            "        token=\"${words[index]}\"",
            "        [[ \"$token\" == -* ]] && break",
            "        if __peekaboo_zsh_has_subcommand \"$path\" \"$token\"; then",
            "            path=\"${path:+$path }$token\"",
            "            (( index++ ))",
            "        else",
            "            break",
            "        fi",
            "    done",
            "",
            "    if (( CURRENT > 2 )); then",
            "        previous_word=\"${words[CURRENT - 1]}\"",
            "    fi",
            "",
            "    if __peekaboo_zsh_option_values \"$path\" \"$previous_word\" | __peekaboo_zsh_compadd_with_help; then",
            "        return",
            "    fi",
            "",
            "    if [[ \"$current_word\" == -* ]]; then",
            "        __peekaboo_zsh_options \"$path\" | __peekaboo_zsh_compadd_with_help",
            "        return",
            "    fi",
            "",
            "    if __peekaboo_zsh_subcommands \"$path\" | __peekaboo_zsh_compadd_with_help; then",
            "        return",
            "    fi",
            "",
            "    local argument_index=$(( CURRENT - index ))",
            "    __peekaboo_zsh_argument_values \"$path\" \"$argument_index\" | __peekaboo_zsh_compadd_with_help",
            "}",
            "",
            "compdef _peekaboo \(document.commandName)",
        ]

        return lines.joined(separator: "\n")
    }

    private func renderZshChoiceSwitch(
        _ paths: [CompletionPath],
        accessor: KeyPath<CompletionPath, [CompletionChoice]>
    ) -> String {
        var lines = ["    case \"$1\" in"]
        for path in paths {
            lines.append("        '\(self.caseLabel(path.key))')")
            for choice in path[keyPath: accessor] {
                lines.append("            print -r -- $'\(self.zshEscaped(choice.value))\\t\(self.zshEscaped(choice.help ?? ""))'")
            }
            lines.append("            ;;")
        }
        lines.append(contentsOf: [
            "        *)",
            "            ;;",
            "    esac",
        ])
        return lines.joined(separator: "\n")
    }

    private func renderZshOptionSwitch(document: CompletionScriptDocument) -> String {
        var lines = ["    case \"$1\" in", "        '')"]
        for option in document.rootOptions {
            for name in option.names {
                lines.append("            print -r -- $'\(self.zshEscaped(name))\\t\(self.zshEscaped(option.help))'")
            }
        }
        lines.append("            ;;")
        for path in document.flattenedPaths {
            lines.append("        '\(self.caseLabel(path.key))')")
            for option in path.options {
                for name in option.names {
                    lines.append("            print -r -- $'\(self.zshEscaped(name))\\t\(self.zshEscaped(option.help))'")
                }
            }
            lines.append("            ;;")
        }
        lines.append(contentsOf: [
            "        *)",
            "            ;;",
            "    esac",
        ])
        return lines.joined(separator: "\n")
    }

    private func renderZshArgumentSwitch(_ paths: [CompletionPath]) -> String {
        var lines = ["    case \"$1:$2\" in"]
        for path in paths {
            for (index, argument) in path.arguments.enumerated() where !argument.choices.isEmpty {
                lines.append("        '\(self.caseLabel(path.key)):\(index)')")
                for choice in argument.choices {
                    lines.append("            print -r -- $'\(self.zshEscaped(choice.value))\\t\(self.zshEscaped(choice.help ?? ""))'")
                }
                lines.append("            ;;")
            }
        }
        lines.append(contentsOf: [
            "        *)",
            "            ;;",
            "    esac",
        ])
        return lines.joined(separator: "\n")
    }

    private func renderZshOptionValueSwitch(_ paths: [CompletionPath]) -> String {
        var lines = ["    case \"$1:$2\" in"]
        for path in paths {
            for option in path.options where !option.valueChoices.isEmpty {
                for name in option.names {
                    lines.append("        '\(self.caseLabel(path.key)):\(self.caseLabel(name))')")
                    for choice in option.valueChoices {
                        lines.append("            print -r -- $'\(self.zshEscaped(choice.value))\\t\(self.zshEscaped(choice.help ?? ""))'")
                    }
                    lines.append("            ;;")
                }
            }
        }
        lines.append(contentsOf: [
            "        *)",
            "            ;;",
            "    esac",
        ])
        return lines.joined(separator: "\n")
    }

    private func caseLabel(_ label: String) -> String {
        label.replacingOccurrences(of: "'", with: "'\\''")
    }

    private func zshEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

/// Renders a fish completion script using fish-native helper functions and a
/// single dynamic `complete -a` callback.
private struct FishCompletionRenderer: ShellCompletionRendering {
    func render(document: CompletionScriptDocument) -> String {
        let lines = [
            "# Fish completion for peekaboo",
            "# Generated from Commander descriptors via `peekaboo completions fish`.",
            "# Install with:",
            "#   \(CompletionsCommand.Shell.fish.installationSnippet)",
            "",
            "function __peekaboo_fish_subcommands",
            self.renderFishChoiceSwitch(document.pathsIncludingRoot, accessor: \.subcommands),
            "end",
            "",
            "function __peekaboo_fish_options",
            self.renderFishOptionSwitch(document: document),
            "end",
            "",
            "function __peekaboo_fish_argument_values",
            self.renderFishArgumentSwitch(document.pathsIncludingRoot),
            "end",
            "",
            "function __peekaboo_fish_option_values",
            self.renderFishOptionValueSwitch(document.pathsIncludingRoot),
            "end",
            "",
            "function __peekaboo_fish_has_subcommand",
            "    set -l path $argv[1]",
            "    set -l candidate $argv[2]",
            "    for line in (__peekaboo_fish_subcommands \"$path\")",
            "        set -l parts (string split \\t -- $line)",
            "        if test (count $parts) -gt 0; and test \"$parts[1]\" = \"$candidate\"",
            "            return 0",
            "        end",
            "    end",
            "    return 1",
            "end",
            "",
            "function __peekaboo_fish_append_path",
            "    if test -n \"$argv[1]\"",
            "        printf '%s %s\\n' \"$argv[1]\" \"$argv[2]\"",
            "    else",
            "        printf '%s\\n' \"$argv[2]\"",
            "    end",
            "end",
            "",
            "function __peekaboo_fish_complete",
            "    set -l tokens (commandline -opc)",
            "    if test (count $tokens) -gt 0",
            "        set -e tokens[1]",
            "    end",
            "    set -l current (commandline -ct)",
            "    set -l path ''",
            "    set -l index 1",
            "    set -l previous ''",
            "    set -l token_count (count $tokens)",
            "",
            "    while test $index -le $token_count",
            "        set -l token $tokens[$index]",
            "        if string match -qr '^-' -- $token",
            "            break",
            "        end",
            "        if __peekaboo_fish_has_subcommand \"$path\" \"$token\"",
            "            set path (__peekaboo_fish_append_path \"$path\" \"$token\")",
            "            set index (math \"$index + 1\")",
            "        else",
            "            break",
            "        end",
            "    end",
            "",
            "    if test $token_count -gt 0",
            "        set previous $tokens[$token_count]",
            "    end",
            "",
            "    set -l option_values (__peekaboo_fish_option_values \"$path\" \"$previous\")",
            "    if test (count $option_values) -gt 0",
            "        printf '%s\\n' $option_values",
            "        return",
            "    end",
            "",
            "    if string match -qr '^-' -- $current",
            "        __peekaboo_fish_options \"$path\"",
            "        return",
            "    end",
            "",
            "    set -l subcommands (__peekaboo_fish_subcommands \"$path\")",
            "    if test (count $subcommands) -gt 0",
            "        printf '%s\\n' $subcommands",
            "        return",
            "    end",
            "",
            "    set -l argument_index (math \"$token_count - $index + 1\")",
            "    __peekaboo_fish_argument_values \"$path\" \"$argument_index\"",
            "end",
            "",
            "complete -c \(document.commandName) -f -a '(__peekaboo_fish_complete)'",
        ]

        return lines.joined(separator: "\n")
    }

    private func renderFishChoiceSwitch(
        _ paths: [CompletionPath],
        accessor: KeyPath<CompletionPath, [CompletionChoice]>
    ) -> String {
        var lines = ["    switch $argv[1]"]
        for path in paths {
            lines.append("        case '\(self.fishEscaped(path.key))'")
            for choice in path[keyPath: accessor] {
                lines.append("            printf '%s\\t%s\\n' '\(self.fishEscaped(choice.value))' '\(self.fishEscaped(choice.help ?? ""))'")
            }
        }
        lines.append(contentsOf: [
            "        case '*'",
            "    end",
        ])
        return lines.joined(separator: "\n")
    }

    private func renderFishOptionSwitch(document: CompletionScriptDocument) -> String {
        var lines = ["    switch $argv[1]", "        case ''"]
        for option in document.rootOptions {
            for name in option.names {
                lines.append("            printf '%s\\t%s\\n' '\(self.fishEscaped(name))' '\(self.fishEscaped(option.help))'")
            }
        }
        for path in document.flattenedPaths {
            lines.append("        case '\(self.fishEscaped(path.key))'")
            for option in path.options {
                for name in option.names {
                    lines.append("            printf '%s\\t%s\\n' '\(self.fishEscaped(name))' '\(self.fishEscaped(option.help))'")
                }
            }
        }
        lines.append(contentsOf: [
            "        case '*'",
            "    end",
        ])
        return lines.joined(separator: "\n")
    }

    private func renderFishArgumentSwitch(_ paths: [CompletionPath]) -> String {
        var lines = ["    switch \"$argv[1]:$argv[2]\""]
        for path in paths {
            for (index, argument) in path.arguments.enumerated() where !argument.choices.isEmpty {
                lines.append("        case '\(self.fishEscaped(path.key)):\(index)'")
                for choice in argument.choices {
                    lines.append("            printf '%s\\t%s\\n' '\(self.fishEscaped(choice.value))' '\(self.fishEscaped(choice.help ?? ""))'")
                }
            }
        }
        lines.append(contentsOf: [
            "        case '*'",
            "    end",
        ])
        return lines.joined(separator: "\n")
    }

    private func renderFishOptionValueSwitch(_ paths: [CompletionPath]) -> String {
        var lines = ["    switch \"$argv[1]:$argv[2]\""]
        for path in paths {
            for option in path.options where !option.valueChoices.isEmpty {
                for name in option.names {
                    lines.append("        case '\(self.fishEscaped(path.key)):\(self.fishEscaped(name))'")
                    for choice in option.valueChoices {
                        lines.append("            printf '%s\\t%s\\n' '\(self.fishEscaped(choice.value))' '\(self.fishEscaped(choice.help ?? ""))'")
                    }
                }
            }
        }
        lines.append(contentsOf: [
            "        case '*'",
            "    end",
        ])
        return lines.joined(separator: "\n")
    }

    private func fishEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

extension CommanderName {
    fileprivate var completionSpelling: String {
        switch self {
        case let .short(value), let .aliasShort(value):
            "-\(value)"
        case let .long(value), let .aliasLong(value):
            "--\(value)"
        }
    }
}
