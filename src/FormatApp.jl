module FormatApp

using JuliaWorkspaces, ArgParse, Logging

# pkgversion (not a Project.toml read) so this keeps working for an installed
# app, where `../Project.toml` need not exist on disc.
const _VERSION = string(@something(pkgversion(@__MODULE__), v"0.0.0"))

# ANSI colors (used only when writing to a TTY)
const _RESET = "\e[0m"
const _BOLD  = "\e[1m"
const _RED   = "\e[31m"
const _GREEN = "\e[32m"
const _CYAN  = "\e[36m"
const _DIM   = "\e[2m"

include("diff.jl")

# ---------------------------------------------------------------------------
# Target discovery
# ---------------------------------------------------------------------------

# Split requested paths into (directories, files). Returns `nothing` if any path
# does not exist.
function _classify_targets(paths::Vector{String})
    dirs = String[]
    files = String[]
    for p in paths
        ap = abspath(p)
        if isdir(ap)
            push!(dirs, ap)
        elseif isfile(ap)
            push!(files, ap)
        else
            printstyled(stderr, "error", color=:red, bold=true)
            println(stderr, ": path does not exist: ", ap)
            return nothing
        end
    end
    return (dirs, files)
end

# Normalize a path for comparison across separators / casing on Windows.
_norm(p::AbstractString) = lowercase(replace(abspath(p), '\\' => '/'))

# Directory whose `JuliaFormat.toml` governs `file_path`: walk up from the
# file's directory until a config file is found. A `.git` directory bounds the
# search (a config above the repository root should not apply), as does the
# filesystem root. Without this, formatting a single explicitly named file
# (or stdin) would miss a config sitting in an ancestor directory.
function _config_anchor_folder(file_path::AbstractString)
    dir = dirname(abspath(file_path))
    cur = dir
    while true
        has_config = try
            any(f -> lowercase(f) == "juliaformat.toml", readdir(cur))
        catch
            false
        end
        has_config && return cur
        isdir(joinpath(cur, ".git")) && return dir
        parent = dirname(cur)
        parent == cur && return dir
        cur = parent
    end
end

# Decide whether a workspace file (given as an absolute path) was requested by
# the user, either directly as a file or because it lives under a target folder.
function _is_requested(path::AbstractString, dirs::Vector{String}, files::Set{String})
    np = _norm(path)
    np in files && return true
    for d in dirs
        nd = _norm(d)
        endswith(nd, '/') || (nd *= '/')
        startswith(np, nd) && return true
    end
    return false
end

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

function parse_commandline(ARGS)
    s = ArgParseSettings(
        prog = "juliaformat",
        description = "juliaformat — a source code formatter for Julia. By default it rewrites files in place. Formatting style and options are read from the nearest JuliaFormat.toml configuration file, which also selects which files are formatted at all.",
        version = _VERSION,
        add_version = true,
    )

    @add_arg_table! s begin
        "path"
            help = "files or directories to format (defaults to current directory); a single `-` reads source from stdin and prints the result to stdout"
            arg_type = String
            nargs = '*'
        "--write", "-w"
            help = "rewrite files in place (the default behavior)"
            action = :store_true
        "--check"
            help = "do not write files; exit with code 1 if any file is not formatted (combine with --diff to also print the changes)"
            action = :store_true
        "--diff", "-d"
            help = "do not write files; print a unified diff of the changes"
            action = :store_true
        "--list", "-l"
            help = "do not write files; list the files that would be reformatted"
            action = :store_true
        "--stdin-filename"
            help = "with `-`: the path the stdin content nominally comes from, used to locate the governing JuliaFormat.toml and to label diffs"
            arg_type = String
            metavar = "PATH"
        "--log"
            help = "set log level (debug or info); warn/error always shown"
            arg_type = String
            metavar = "LEVEL"
            range_tester = x -> x in ("debug", "info")
    end

    return parse_args(ARGS, s)
end

# ---------------------------------------------------------------------------
# stdin mode
# ---------------------------------------------------------------------------

# Format the text arriving on stdin. Default: print the formatted source to
# stdout. `--check` exits 1 when the input is not formatted; `--diff` prints a
# unified diff. `stdin_filename`, when given, anchors JuliaFormat.toml
# discovery (including include/exclude) and labels check/diff output.
function _run_stdin(check::Bool, diff::Bool, stdin_filename; input::IO=stdin)
    text = read(input, String)

    local jw, uri, label
    if stdin_filename !== nothing
        ap = abspath(stdin_filename)
        label = stdin_filename
        jw = workspace_from_folders([_config_anchor_folder(ap)])
        uri = JuliaWorkspaces.filepath2uri(ap)
        file = TextFile(uri, SourceText(text, "julia"))
        # The file may or may not exist on disc under the anchor folder; the
        # stdin content wins either way.
        has_file(jw, uri) ? JuliaWorkspaces.update_file!(jw, file) : add_file!(jw, file)
    else
        # No filename: no config discovery, the built-in defaults apply.
        label = "<stdin>"
        jw = JuliaWorkspace()
        uri = JuliaWorkspaces.filepath2uri(joinpath(pwd(), "__juliaformat_stdin__.jl"))
        add_file!(jw, TextFile(uri, SourceText(text, "julia")))
    end

    edit = try
        get_format_edits(jw, uri)
    catch err
        printstyled(stderr, "error", color=:red, bold=true)
        println(stderr, ": failed to format ", label, ": ", sprint(showerror, err))
        return 1
    end

    if edit === nothing
        # Excluded by configuration: the input passes through untouched.
        check || diff || print(stdout, text)
        return 0
    end

    formatted = isempty(edit.edits) ? text : edit.edits[1].new_text
    changed = formatted != text

    if check || diff
        diff && changed && _print_diff(stdout, label, text, formatted, stdout isa Base.TTY)
        check && changed && println(stderr, "would reformat ", label)
        return (check && changed) ? 1 : 0
    end

    print(stdout, formatted)
    return 0
end

# ---------------------------------------------------------------------------
# Core runner (returns an exit code; testable without building the app)
# ---------------------------------------------------------------------------

function _run(ARGS)
    parsed_args = parse_commandline(ARGS)
    parsed_args === nothing && return 0  # --help / --version handled by ArgParse

    # --- Logging ---
    log_level = parsed_args["log"]
    if log_level == "debug"
        global_logger(ConsoleLogger(stderr, Logging.Debug))
    elseif log_level == "info"
        global_logger(ConsoleLogger(stderr, Logging.Info))
    else
        global_logger(ConsoleLogger(stderr, Logging.Warn))
    end

    # --- Mode selection ---
    check = parsed_args["check"]::Bool
    diff  = parsed_args["diff"]::Bool
    list  = parsed_args["list"]::Bool
    write = parsed_args["write"]::Bool
    stdin_filename = parsed_args["stdin-filename"]

    # `--check --diff` is a supported combination (the diff is printed and the
    # exit code reports whether anything would change — the shape CI wants, and
    # what Black/cargo-fmt/ruff all offer). `--list` composes with neither:
    # with `--check` it is redundant, with `--diff` the outputs interleave.
    # An explicit `--write` contradicts every no-write mode.
    if write && (check || diff || list)
        printstyled(stderr, "error", color=:red, bold=true)
        println(stderr, ": --write cannot be combined with --check, --diff or --list")
        return 2
    end
    if list && (check || diff)
        printstyled(stderr, "error", color=:red, bold=true)
        println(stderr, ": --list cannot be combined with --check or --diff")
        return 2
    end
    # Default mode is write-in-place. --write is an explicit synonym.
    write = write || !(check || diff || list)

    # --- Targets ---
    raw_paths = parsed_args["path"]::Vector{String}

    # --- stdin mode ---
    if "-" in raw_paths
        if length(raw_paths) != 1
            printstyled(stderr, "error", color=:red, bold=true)
            println(stderr, ": `-` (stdin) cannot be combined with other paths")
            return 2
        end
        if parsed_args["write"]::Bool || list
            printstyled(stderr, "error", color=:red, bold=true)
            println(stderr, ": --write and --list are not supported with `-` (stdin)")
            return 2
        end
        return _run_stdin(check, diff, stdin_filename)
    end
    if stdin_filename !== nothing
        printstyled(stderr, "error", color=:red, bold=true)
        println(stderr, ": --stdin-filename requires reading from stdin via `-`")
        return 2
    end

    isempty(raw_paths) && (raw_paths = [pwd()])

    classified = _classify_targets(raw_paths)
    classified === nothing && return 1
    dirs, files = classified

    # Build a workspace covering all requested directories plus, for any
    # explicitly requested file, the directory of its governing
    # JuliaFormat.toml (so a config in an ancestor directory is honored).
    folders = copy(dirs)
    for f in files
        push!(folders, _config_anchor_folder(f))
    end
    unique!(folders)

    file_set = Set(_norm.(files))

    # Formatting is purely syntactic, so no dynamic environment analysis is needed.
    jw = workspace_from_folders(folders)

    # Collect the URIs of Julia files that the user actually requested.
    target_uris = filter(uri -> begin
        path = JuliaWorkspaces.uri2filepath(uri)
        path !== nothing && _is_requested(path, dirs, file_set)
    end, collect(get_julia_files(jw)))

    sort!(target_uris, by=uri -> something(JuliaWorkspaces.uri2filepath(uri), ""))

    if isempty(target_uris)
        printstyled(stderr, "warning", color=:yellow, bold=true)
        println(stderr, ": no Julia files found to format")
        return 0
    end

    use_color = stdout isa Base.TTY

    n_reformatted = 0
    n_unchanged   = 0
    n_errors      = 0
    n_skipped     = 0

    for uri in target_uris
        path = JuliaWorkspaces.uri2filepath(uri)

        # A file the configuration excludes is skipped, not an error — walking a
        # directory routinely turns up files the user has opted out of.
        if JuliaWorkspaces.is_format_excluded(jw, uri)
            n_skipped += 1
            @debug "skipping excluded file" path
            continue
        end

        local edit
        try
            edit = get_format_edits(jw, uri)
        catch err
            n_errors += 1
            printstyled(stderr, "error", color=:red, bold=true)
            println(stderr, ": failed to format ", path, ": ", sprint(showerror, err))
            continue
        end

        # `nothing` means the configuration excludes the file (the
        # is_format_excluded pre-check above normally catches this already).
        if edit === nothing
            n_skipped += 1
            continue
        end

        if isempty(edit.edits)
            n_unchanged += 1
            continue
        end

        formatted = edit.edits[1].new_text
        original  = get_text_file(jw, uri).content.content

        n_reformatted += 1

        if write
            try
                open(path, "w") do io
                    print(io, formatted)
                end
            catch err
                n_errors += 1
                printstyled(stderr, "error", color=:red, bold=true)
                println(stderr, ": failed to write ", path, ": ", sprint(showerror, err))
                continue
            end
            use_color ? println(stdout, _CYAN, "formatted", _RESET, " ", path) :
                        println(stdout, "formatted ", path)
        elseif list
            println(stdout, path)
        elseif diff
            _print_diff(stdout, path, original, formatted, use_color)
        elseif check
            println(stdout, "would reformat ", path)
        end
    end

    # --- Summary (to stderr so it does not pollute --diff / --list output) ---
    if write
        parts = String[]
        n_reformatted > 0 && push!(parts, "$n_reformatted reformatted")
        n_unchanged   > 0 && push!(parts, "$n_unchanged unchanged")
        n_errors      > 0 && push!(parts, "$n_errors error$(n_errors == 1 ? "" : "s")")
        n_skipped     > 0 && push!(parts, "$n_skipped excluded")
        isempty(parts) || println(stderr, join(parts, ", "))
    elseif check
        skipped_note = n_skipped > 0 ? ", $n_skipped excluded" : ""
        if n_reformatted > 0
            println(stderr, "$n_reformatted file$(n_reformatted == 1 ? "" : "s") would be reformatted, $n_unchanged already formatted", skipped_note)
        else
            println(stderr, "all $n_unchanged file$(n_unchanged == 1 ? "" : "s") already formatted", skipped_note)
        end
    end

    # --- Exit code ---
    n_errors > 0 && return 1
    check && n_reformatted > 0 && return 1
    return 0
end

# ---------------------------------------------------------------------------
# Native app entry point
# ---------------------------------------------------------------------------

(@main)(ARGS) = _run(ARGS)

# ---------------------------------------------------------------------------
# Precompile workload
# ---------------------------------------------------------------------------

using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    badly_formatted = """
    x=1+ 2
    function  f( a,b )
      a+ b
    end
    """

    workload_dir = mktempdir()
    script_path = joinpath(workload_dir, "script.jl")
    write(script_path, badly_formatted)

    # Separate directory for the write-in-place mode so the read-only modes
    # above keep operating on unformatted input.
    write_dir = mktempdir()
    write(joinpath(write_dir, "script.jl"), badly_formatted)

    # Subfolder configured for Runic so the app-side dispatch into the second
    # formatter backend is compiled too.
    runic_dir = mktempdir()
    write(joinpath(runic_dir, "JuliaFormat.toml"), """
    style = "runic"
    """)
    write(joinpath(runic_dir, "runic_file.jl"), """
    g(x)=x^ 2
    z  = g( 3 )
    """)

    @compile_workload begin
        parse_commandline(String[])
        redirect_stdout(devnull) do
            redirect_stderr(devnull) do
                _run([workload_dir, "--check"])
                _run([workload_dir, "--diff"])
                _run([workload_dir, "--list"])
                _run([runic_dir, "--check"])
                # Default mode: rewrite files in place.
                _run([write_dir])
                # stdin mode, with and without a nominal filename. Called via
                # the handler directly: the precompile process has no real
                # stdin to redirect on Windows.
                _run_stdin(true, false, script_path; input=IOBuffer(badly_formatted))
                _run_stdin(false, true, nothing; input=IOBuffer(badly_formatted))
                _run_stdin(false, false, nothing; input=IOBuffer(badly_formatted))
            end
        end
    end
end

end # module FormatApp
