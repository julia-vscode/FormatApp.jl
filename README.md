# JuliaFormat.jl

`juliaformat` is a command line source code formatter for Julia. It exposes the
formatting capabilities of [JuliaWorkspaces.jl](https://github.com/julia-vscode/JuliaWorkspaces.jl)
as a standalone app, and is a companion to [JuliaLint.jl](https://github.com/julia-vscode/JuliaLint.jl).

By default `juliaformat` rewrites files in place. The formatting style and
options are read from the nearest `juliaformat.toml` configuration file; when no
configuration is found the `minimal` style is used.

## Installation

`juliaformat` is distributed as a Julia app. Install it with the `app` command in the package REPL:

```
pkg> app add https://github.com/julia-vscode/JuliaFormat.jl
```

This installs the `juliaformat` executable and makes it available on your
`PATH`.

## Usage

```
juliaformat [options] [path...]
```

`path` may be one or more files or directories. Directories are searched
recursively for Julia files. When no path is given, the current directory is
used.

### Options

| Option | Description |
| --- | --- |
| `-w`, `--write` | Rewrite files in place (the default behavior). |
| `--check` | Do not write files; exit with code `1` if any file is not formatted. |
| `-d`, `--diff` | Do not write files; print a unified diff of the changes. |
| `-l`, `--list` | Do not write files; list the files that would be reformatted. |
| `--log LEVEL` | Set the log level (`debug` or `info`); warnings and errors are always shown. |
| `--version` | Print the version and exit. |
| `-h`, `--help` | Print help and exit. |

`--check`, `--diff` and `--list` are mutually exclusive.

### Examples

```sh
# Format every Julia file under src/ in place
juliaformat src/

# Format a single file
juliaformat src/MyModule.jl

# Fail (exit code 1) if anything is unformatted — useful in CI
juliaformat --check src/

# Show what would change without writing
juliaformat --diff src/

# List the files that would be reformatted
juliaformat --list .
```

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success (and, in `--check` mode, everything is already formatted). |
| `1` | In `--check` mode, some files need reformatting; or a file failed to format/write. |
| `2` | Invalid combination of options. |

## Configuration

Formatting is configured through `juliaformat.toml` files discovered in the
workspace. For example:

```toml
style = "blue"
```

Supported styles are `default`, `yas`, `blue`, `sciml`, `minimal` (default) and
`runic`. Additional `JuliaFormatter` options (such as `margin` or `indent`) may
be set alongside `style`.
