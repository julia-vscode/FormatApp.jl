# FormatApp.jl

> [!WARNING]
> **FormatApp is beta software.** It is still under active development, may be
> unstable, and everything described here — including commands, options, output,
> and the configuration format — is subject to change without notice.

`juliaformat` is a command line source code formatter for Julia. It exposes the
formatting capabilities of [JuliaWorkspaces.jl](https://github.com/julia-vscode/JuliaWorkspaces.jl)
as a standalone app, and is a companion to [LintApp.jl](https://github.com/julia-vscode/LintApp.jl).

By default `juliaformat` rewrites files in place. The formatting style and
options are read from the nearest `JuliaFormat.toml` configuration file; when no
configuration is found the `minimal` style is used.

## Installation

`juliaformat` is distributed as a Julia app. Install it with the `app` command in the package REPL:

```
pkg> app add https://github.com/julia-vscode/FormatApp.jl
```

This installs the `juliaformat` executable and makes it available on your
`PATH`.

## Usage

```
juliaformat [options] [path...]
```

`path` may be one or more files or directories. Directories are searched
recursively for Julia files. When no path is given, the current directory is
used. A single `-` reads source code from stdin instead (see below).

When a file is named explicitly, the governing `JuliaFormat.toml` is looked up
in the file's directory and its ancestors (stopping at a `.git` directory), so
a repository-root configuration applies even when formatting one file deep in
the tree.

### Options

| Option | Description |
| --- | --- |
| `-w`, `--write` | Rewrite files in place (the default behavior). |
| `--check` | Do not write files; exit with code `1` if any file is not formatted. |
| `-d`, `--diff` | Do not write files; print a unified diff of the changes. |
| `-l`, `--list` | Do not write files; list the files that would be reformatted. |
| `--stdin-filename PATH` | With `-`: the path the stdin content nominally comes from. |
| `--log LEVEL` | Set the log level (`debug` or `info`); warnings and errors are always shown. |
| `--version` | Print the version and exit. |
| `-h`, `--help` | Print help and exit. |

`--check` may be combined with `--diff`: the diff is printed and the exit code
reports whether anything would change, which is the shape a CI job wants.
`--list` composes with neither (with `--check` it is redundant, with `--diff`
the outputs would interleave). `--write` cannot be combined with any of the
no-write modes.

### stdin

`juliaformat -` reads Julia source from stdin and prints the formatted result
to stdout, which is what editor and tooling integrations want. `--check` and
`--diff` work as for files; `--write` and `--list` do not apply.

Without further arguments the built-in defaults (the `minimal` style) are
used — no configuration file is consulted. Pass `--stdin-filename PATH` to
format the input as if it were that file: the governing `JuliaFormat.toml` is
discovered from `PATH`, including its `include`/`exclude` globs (input from an
excluded file passes through unchanged), and diffs are labeled with it.

```sh
echo 'foo( 1,2 )' | juliaformat -
juliaformat - --stdin-filename src/MyModule.jl < src/MyModule.jl
```

### Examples

```sh
# Format every Julia file under src/ in place
juliaformat src/

# Format a single file
juliaformat src/MyModule.jl

# Fail (exit code 1) if anything is unformatted — useful in CI
juliaformat --check src/

# The CI sweet spot: fail AND show the changes in the log
juliaformat --check --diff .

# Show what would change without writing (always exits 0)
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

Formatting is configured through `JuliaFormat.toml` files discovered in the
workspace (the name is matched case-insensitively).

**The nearest configuration file governs a file wholesale.** When several
`JuliaFormat.toml` files exist along a path, only the closest one applies —
settings are *not* merged across files. Keys it does not set take their built-in
defaults, never a value from a file further up the tree.

A single `JuliaFormat.toml` at the project root should be your default. When
part of the tree needs different settings, use an `[[override]]` block in that
one file rather than a second config file — a nested file is a last resort, for
a subtree that is genuinely independent of the project, such as a vendored
repository.

Because a nested config *replaces* rather than extends the one above it, a
`JuliaFormat.toml` with another in an enclosing directory reports an
informational `shadowed_config` diagnostic naming the file it takes over from —
the linter's `shadowed_config` rule controls it.

### Top-level keys

| Key | Default | Description |
| --- | --- | --- |
| `config-version` | `1` | The config format version. Absent means `1`. |
| `style` | `"minimal"` | The style preset: `default`, `yas`, `blue`, `sciml`, `minimal` or `runic`. |
| `include` | all `.jl` files | Glob patterns selecting the files to format. |
| `exclude` | none | Glob patterns excluding files from formatting. Wins over `include`. |
| `[options]` | — | `JuliaFormatter` options applied on top of the style preset. |
| `[[override]]` | — | Re-scope `style` and `[options]` to matching paths. |

Globs are gitignore-style, relative to the directory holding the config file:
`*` matches within a path segment, `**` spans segments, `?` matches a single
character, and a pattern with no `/` matches at any depth. Excluded files are
skipped rather than reported as errors.

`style` names a preset; `[options]` are deltas on top of it and accept any field
of `JuliaFormatter.Options` (such as `margin` or `indent`). The `runic` style
takes no options at all — combining it with `[options]` is reported as a
configuration error rather than silently ignored.

This is deliberately a different file from JuliaFormatter.jl's own
`.JuliaFormatter.toml`, which `juliaformat` never reads: one file interpreted by
two independently versioned tools would diverge silently.

### Example

```toml
style = "blue"
exclude = ["gen/**"]

[options]
margin = 92
always_for_in = true

# Documentation examples are formatted narrower so they fit in a code block.
[[override]]
paths = ["docs/**"]

[override.options]
margin = 80
```

### Excluded files

A file that `include`/`exclude` leaves out is **skipped**, not failed. Walking a
directory routinely turns up files a project has opted out of, so they are
counted separately and never affect the exit code:

```
$ juliaformat --check .
would reformat src/a.jl
1 file would be reformatted, 3 already formatted, 2 excluded
```

### Migrating from the old format

Formatter options used to sit at the top level of the file, alongside `style`.
They now live under `[options]`. An existing config is not silently ignored:
each top-level option key produces a diagnostic naming the change.

```toml
# Before
style = "blue"
margin = 92

# After
style = "blue"

[options]
margin = 92
```

### Full reference

This page covers what `juliaformat` needs. For the complete specification —
the discovery and override mechanism shared with `JuliaLint.toml` and
`JuliaTestItems.toml`, and the full glob grammar — see the
[JuliaWorkspaces configuration reference](https://www.julia-vscode.org/JuliaWorkspaces.jl/dev/configuration/).
