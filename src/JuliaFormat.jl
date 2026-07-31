module JuliaFormat

using JuliaWorkspaces, ArgParse, Logging

const _VERSION = let
    proj = joinpath(dirname(@__DIR__), "Project.toml")
    m = match(r"^version\s*=\s*\"([^\"]+)\""m, read(proj, String))
    m === nothing ? "0.0.0" : String(m[1])
end

# ANSI colors (used only when writing to a TTY)
const _RESET = "\e[0m"
const _BOLD  = "\e[1m"
const _RED   = "\e[31m"
const _GREEN = "\e[32m"
const _CYAN  = "\e[36m"
const _DIM   = "\e[2m"

# ---------------------------------------------------------------------------
# Unified diff (line based, LCS) — no external dependency
# ---------------------------------------------------------------------------

function _split_lines(s::AbstractString)
    lines = split(s, '\n')
    if !isempty(lines) && last(lines) == "" && endswith(s, '\n')
        pop!(lines)
    end
    return lines
end

# Longest common subsequence table over two vectors of lines.
function _lcs_table(a::Vector{<:AbstractString}, b::Vector{<:AbstractString})
    n, m = length(a), length(b)
    dp = zeros(Int, n + 1, m + 1)
    for i in n:-1:1
        for j in m:-1:1
            dp[i, j] = a[i] == b[j] ? dp[i + 1, j + 1] + 1 : max(dp[i + 1, j], dp[i, j + 1])
        end
    end
    return dp
end

# Produce a list of (op, line) tuples where op is :keep, :del or :add.
function _diff_ops(a::Vector{<:AbstractString}, b::Vector{<:AbstractString})
    dp = _lcs_table(a, b)
    ops = Tuple{Symbol,String}[]
    i, j = 1, 1
    n, m = length(a), length(b)
    while i <= n && j <= m
        if a[i] == b[j]
            push!(ops, (:keep, String(a[i])))
            i += 1; j += 1
        elseif dp[i + 1, j] >= dp[i, j + 1]
            push!(ops, (:del, String(a[i])))
            i += 1
        else
            push!(ops, (:add, String(b[j])))
            j += 1
        end
    end
    while i <= n
        push!(ops, (:del, String(a[i]))); i += 1
    end
    while j <= m
        push!(ops, (:add, String(b[j]))); j += 1
    end
    return ops
end

"""
    _print_diff(io, path, original, formatted, use_color)

Print a git-style unified diff between `original` and `formatted` for `path`.
"""
function _print_diff(io::IO, path::AbstractString, original::AbstractString, formatted::AbstractString, use_color::Bool)
    a = _split_lines(original)
    b = _split_lines(formatted)
    ops = _diff_ops(a, b)

    header_a = "--- $path (original)"
    header_b = "+++ $path (formatted)"
    if use_color
        println(io, _BOLD, header_a, _RESET)
        println(io, _BOLD, header_b, _RESET)
    else
        println(io, header_a)
        println(io, header_b)
    end

    for (op, line) in ops
        if op === :del
            use_color ? println(io, _RED, "-", line, _RESET) : println(io, "-", line)
        elseif op === :add
            use_color ? println(io, _GREEN, "+", line, _RESET) : println(io, "+", line)
        else
            use_color ? println(io, _DIM, " ", line, _RESET) : println(io, " ", line)
        end
    end
end

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
        description = "juliaformat — a source code formatter for Julia. By default it rewrites files in place. Formatting style and options are read from the nearest juliaformat.toml configuration file.",
        version = _VERSION,
        add_version = true,
    )

    @add_arg_table! s begin
        "path"
            help = "files or directories to format (defaults to current directory)"
            arg_type = String
            nargs = '*'
        "--write", "-w"
            help = "rewrite files in place (the default behavior)"
            action = :store_true
        "--check"
            help = "do not write files; exit with code 1 if any file is not formatted"
            action = :store_true
        "--diff", "-d"
            help = "do not write files; print a unified diff of the changes"
            action = :store_true
        "--list", "-l"
            help = "do not write files; list the files that would be reformatted"
            action = :store_true
        "--log"
            help = "set log level (debug or info); warn/error always shown"
            arg_type = String
            metavar = "LEVEL"
            range_tester = x -> x in ("debug", "info")
    end

    return parse_args(ARGS, s)
end

# ---------------------------------------------------------------------------
# Core runner (returns an exit code; testable without building the app)
# ---------------------------------------------------------------------------

function _run(ARGS)
    parsed_args = parse_commandline(ARGS)
    parsed_args === nothing && return 0  # --help / --version handled by ArgParse

    # --- Logging ---
    ENV["JULIA_LOAD_PATH"] = ";"
    log_level = parsed_args["log"]
    if log_level == "debug"
        global_logger(ConsoleLogger(stderr, Logging.Debug))
    elseif log_level == "info"
        global_logger(ConsoleLogger(stderr, Logging.Info))
    else
        global_logger(ConsoleLogger(stderr, Logging.Warn))
    end

    # --- Mode selection (mutually exclusive) ---
    check = parsed_args["check"]::Bool
    diff  = parsed_args["diff"]::Bool
    list  = parsed_args["list"]::Bool
    write = parsed_args["write"]::Bool

    n_modes = count(identity, (check, diff, list))
    if n_modes > 1
        printstyled(stderr, "error", color=:red, bold=true)
        println(stderr, ": --check, --diff and --list are mutually exclusive")
        return 2
    end
    # Default mode is write-in-place. --write is an explicit synonym.
    write = write || n_modes == 0

    # --- Targets ---
    raw_paths = parsed_args["path"]::Vector{String}
    isempty(raw_paths) && (raw_paths = [pwd()])

    classified = _classify_targets(raw_paths)
    classified === nothing && return 1
    dirs, files = classified

    # Build a workspace covering all requested directories plus the parent
    # folders of any explicitly requested files.
    folders = copy(dirs)
    for f in files
        push!(folders, dirname(f))
    end
    unique!(folders)

    file_set = Set(_norm.(files))

    jw = workspace_from_folders(folders, dynamic=JuliaWorkspaces.DynamicIndexingOnly, symbolcache_download=false)

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

    for uri in target_uris
        path = JuliaWorkspaces.uri2filepath(uri)

        local edit
        try
            edit = get_format_edits(jw, uri)
        catch err
            n_errors += 1
            printstyled(stderr, "error", color=:red, bold=true)
            println(stderr, ": failed to format ", path, ": ", sprint(showerror, err))
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
        isempty(parts) || println(stderr, join(parts, ", "))
    elseif check
        if n_reformatted > 0
            println(stderr, "$n_reformatted file$(n_reformatted == 1 ? "" : "s") would be reformatted, $n_unchanged already formatted")
        else
            println(stderr, "all $n_unchanged file$(n_unchanged == 1 ? "" : "s") already formatted")
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
    workload_dir = mktempdir()
    write(joinpath(workload_dir, "script.jl"), """
    x=1+ 2
    function  f( a,b )
      a+ b
    end
    """)

    @compile_workload begin
        parse_commandline(String[])
        redirect_stdout(devnull) do
            redirect_stderr(devnull) do
                _run([workload_dir, "--check"])
                _run([workload_dir, "--diff"])
                _run([workload_dir, "--list"])
            end
        end
    end
end

end # module JuliaFormat
