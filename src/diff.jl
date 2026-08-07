# Unified diff (line based) — no external dependency.
#
# Emits `git diff` shaped output: `--- a/…` / `+++ b/…` headers, `@@` hunks
# with `_DIFF_CONTEXT` lines of context, and `\ No newline at end of file`
# markers. The LCS table is only built over the changed window between the
# common prefix and suffix, which keeps memory proportional to the actual
# change for the typical localized formatting diff.

const _DIFF_CONTEXT = 3

# Windows above this many table cells fall back to a single replace hunk
# instead of an LCS-minimal diff.
const _DIFF_MAX_TABLE_CELLS = 25_000_000

# Split into lines without their trailing newline; also report whether the
# text ends with a newline (an empty text has no lines at all).
function _diff_lines(s::AbstractString)
    isempty(s) && return SubString{String}[], true
    lines = split(s, '\n')
    ends_nl = endswith(s, '\n')
    ends_nl && pop!(lines)
    return lines, ends_nl
end

# Minimal edit script over the changed window, appended to `ops` as
# (:keep | :del | :add, line) tuples.
function _lcs_ops!(ops::Vector{Tuple{Symbol,String}}, a, b)
    n, m = length(a), length(b)
    ha = hash.(a)
    hb = hash.(b)
    same(i, j) = ha[i] == hb[j] && a[i] == b[j]
    dp = zeros(Int32, n + 1, m + 1)
    for i in n:-1:1, j in m:-1:1
        dp[i, j] = same(i, j) ? dp[i+1, j+1] + Int32(1) : max(dp[i+1, j], dp[i, j+1])
    end
    i = j = 1
    while i <= n && j <= m
        if same(i, j)
            push!(ops, (:keep, String(a[i])))
            i += 1
            j += 1
        elseif dp[i+1, j] >= dp[i, j+1]
            push!(ops, (:del, String(a[i])))
            i += 1
        else
            push!(ops, (:add, String(b[j])))
            j += 1
        end
    end
    while i <= n
        push!(ops, (:del, String(a[i])))
        i += 1
    end
    while j <= m
        push!(ops, (:add, String(b[j])))
        j += 1
    end
end

function _diff_ops(a, b)
    n, m = length(a), length(b)

    lo = 1
    while lo <= n && lo <= m && a[lo] == b[lo]
        lo += 1
    end
    hi = 0
    while lo + hi <= n && lo + hi <= m && a[n-hi] == b[m-hi]
        hi += 1
    end

    ops = Tuple{Symbol,String}[]
    sizehint!(ops, n + m)
    for i in 1:(lo-1)
        push!(ops, (:keep, String(a[i])))
    end
    awin = @view a[lo:(n-hi)]
    bwin = @view b[lo:(m-hi)]
    if length(awin) * length(bwin) > _DIFF_MAX_TABLE_CELLS
        for l in awin
            push!(ops, (:del, String(l)))
        end
        for l in bwin
            push!(ops, (:add, String(l)))
        end
    else
        _lcs_ops!(ops, awin, bwin)
    end
    for i in (n-hi+1):n
        push!(ops, (:keep, String(a[i])))
    end
    return ops
end

_hunk_pos(start, count) = count == 1 ? "$start" : "$start,$count"

"""
    _print_diff(io, path, original, formatted, use_color)

Print a git-style unified diff between `original` and `formatted` for `path`.
Prints nothing when the two texts are equal.
"""
function _print_diff(io::IO, path::AbstractString, original::AbstractString, formatted::AbstractString, use_color::Bool)
    a, a_nl = _diff_lines(original)
    b, b_nl = _diff_lines(formatted)
    ops = _diff_ops(a, b)

    changed = findall(op -> op[1] !== :keep, ops)
    isempty(changed) && return

    label = replace(path, '\\' => '/')
    header_a = "--- a/$label"
    header_b = "+++ b/$label"
    if use_color
        println(io, _BOLD, header_a, _RESET)
        println(io, _BOLD, header_b, _RESET)
    else
        println(io, header_a)
        println(io, header_b)
    end

    # Line numbers of each op in the original (a) and formatted (b) text:
    # aline[k]/bline[k] is the number of a/b lines consumed before op k.
    aline = Vector{Int}(undef, length(ops))
    bline = Vector{Int}(undef, length(ops))
    ai = bi = 0
    for (k, (op, _)) in enumerate(ops)
        aline[k] = ai
        bline[k] = bi
        op !== :add && (ai += 1)
        op !== :del && (bi += 1)
    end
    total_a = ai
    total_b = bi

    # Group changed ops into hunks: two change groups separated by more than
    # 2 * context keep lines get their own hunks.
    hunks = UnitRange{Int}[]
    hunk_start = changed[1]
    hunk_stop = changed[1]
    for k in changed[2:end]
        if k - hunk_stop - 1 > 2 * _DIFF_CONTEXT
            push!(hunks, hunk_start:hunk_stop)
            hunk_start = k
        end
        hunk_stop = k
    end
    push!(hunks, hunk_start:hunk_stop)

    no_newline_marker = "\\ No newline at end of file"

    for h in hunks
        lo = max(1, first(h) - _DIFF_CONTEXT)
        hi = min(length(ops), last(h) + _DIFF_CONTEXT)

        a_count = count(k -> ops[k][1] !== :add, lo:hi)
        b_count = count(k -> ops[k][1] !== :del, lo:hi)
        # Unified-diff convention: an empty side reports the line before the hunk.
        a_start = a_count == 0 ? aline[lo] : aline[lo] + 1
        b_start = b_count == 0 ? bline[lo] : bline[lo] + 1

        hunk_header = "@@ -$(_hunk_pos(a_start, a_count)) +$(_hunk_pos(b_start, b_count)) @@"
        use_color ? println(io, _CYAN, hunk_header, _RESET) : println(io, hunk_header)

        for k in lo:hi
            op, line = ops[k]
            if op === :del
                use_color ? println(io, _RED, "-", line, _RESET) : println(io, "-", line)
                aline[k] + 1 == total_a && !a_nl && println(io, no_newline_marker)
            elseif op === :add
                use_color ? println(io, _GREEN, "+", line, _RESET) : println(io, "+", line)
                bline[k] + 1 == total_b && !b_nl && println(io, no_newline_marker)
            else
                use_color ? println(io, _DIM, " ", line, _RESET) : println(io, " ", line)
                aline[k] + 1 == total_a && !a_nl && println(io, no_newline_marker)
            end
        end
    end
end
