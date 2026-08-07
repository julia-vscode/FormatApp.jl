using Test
using JuliaFormatApp

# Run JuliaFormatApp._run with captured stdout/stderr, returning
# (exit_code, stdout::String, stderr::String). Optionally feeds `input` as stdin.
function run_cli(args::Vector{String}; input::Union{Nothing,String}=nothing)
    out_path, out_io = mktemp()
    err_path, err_io = mktemp()
    local code
    try
        if input === nothing
            code = redirect_stdio(() -> JuliaFormatApp._run(args); stdout=out_io, stderr=err_io)
        else
            in_path, in_io = mktemp()
            write(in_io, input)
            close(in_io)
            open(in_path) do in_stream
                code = redirect_stdio(() -> JuliaFormatApp._run(args); stdout=out_io, stderr=err_io, stdin=in_stream)
            end
        end
    finally
        close(out_io)
        close(err_io)
    end
    return code, read(out_path, String), read(err_path, String)
end

const MESSY = "function  foo(x )\nreturn x+1\nend\n"
const CLEAN = "function foo(x)\n    return x+1\nend\n"

@testset "flag compatibility matrix" begin
    dir = mktempdir()
    write(joinpath(dir, "a.jl"), CLEAN)

    for bad in (["--write", "--check"], ["--write", "--diff"], ["--write", "--list"],
                ["--list", "--check"], ["--list", "--diff"])
        code, _, err = run_cli([bad..., dir])
        @test code == 2
        @test occursin("cannot be combined", err)
    end

    # --write --check must not have written anything.
    messy_file = joinpath(dir, "b.jl")
    write(messy_file, MESSY)
    code, _, _ = run_cli(["--write", "--check", dir])
    @test code == 2
    @test read(messy_file, String) == MESSY

    # --check --diff remains a supported combination.
    code, out, _ = run_cli(["--check", "--diff", dir])
    @test code == 1
    @test occursin("@@", out)
end

@testset "check and write modes" begin
    dir = mktempdir()
    file = joinpath(dir, "a.jl")
    write(file, MESSY)

    code, out, err = run_cli(["--check", dir])
    @test code == 1
    @test occursin("would reformat", out)
    @test read(file, String) == MESSY

    code, out, _ = run_cli([dir])
    @test code == 0
    @test occursin("formatted", out)
    formatted = read(file, String)
    @test formatted != MESSY

    code, _, _ = run_cli(["--check", dir])
    @test code == 0
end

@testset "unified diff output" begin
    dir = mktempdir()
    file = joinpath(dir, "a.jl")
    # Two separated messy spots in an otherwise formatted file produce two hunks.
    lines = vcat(["x$i = $i" for i in 1:10], ["foo( 1 )"], ["y$i = $i" for i in 1:10],
                 ["bar( 2 )"], ["z$i = $i" for i in 1:10])
    write(file, join(lines, "\n") * "\n")

    code, out, _ = run_cli(["--diff", dir])
    @test code == 0
    # Windows drive letters may round-trip through URIs with different casing.
    label = lowercase(replace(file, '\\' => '/'))
    @test occursin("--- a/$label", lowercase(out))
    @test occursin("+++ b/$label", lowercase(out))
    # Exactly two hunks, each with the standard header shape and 3 context lines.
    hunk_headers = collect(eachmatch(r"@@ -(\d+),(\d+) \+(\d+),(\d+) @@", out))
    @test length(hunk_headers) == 2
    m = hunk_headers[1]
    # First hunk: one changed line at line 11 with 3 context lines either side.
    @test parse(Int, m[1]) == 8 && parse(Int, m[2]) == 7
    @test occursin("-foo( 1 )", out)
    @test occursin("+foo(1)", out)
    @test occursin(" x10 = 10", out)

    # A file without a trailing newline carries the marker.
    file2 = joinpath(dir, "b.jl")
    write(file2, "foo( 1 )")
    code, out, _ = run_cli(["--diff", file2])
    @test occursin("\\ No newline at end of file", out)
end

@testset "exclusion is skipped, not an error" begin
    dir = mktempdir()
    write(joinpath(dir, "JuliaFormat.toml"), "exclude = [\"gen/**\"]\n")
    gen = mkpath(joinpath(dir, "gen"))
    excluded = joinpath(gen, "a.jl")
    write(excluded, MESSY)
    write(joinpath(dir, "b.jl"), CLEAN)

    code, _, err = run_cli(["--check", dir])
    @test code == 0
    @test occursin("1 excluded", err)
    @test read(excluded, String) == MESSY
end

@testset "config anchor found from a file target in a subdirectory" begin
    dir = mktempdir()
    write(joinpath(dir, "JuliaFormat.toml"), "exclude = [\"sub/**\"]\n")
    sub = mkpath(joinpath(dir, "sub"))
    file = joinpath(sub, "a.jl")
    write(file, MESSY)

    # Formatting the file directly must discover the root config one level up
    # and honor its exclusion.
    code, _, err = run_cli(["--check", file])
    @test code == 0
    @test occursin("excluded", err)

    # Same anchor logic applies to styles: a root config selecting `default`
    # affects an explicitly named file below it.
    write(joinpath(dir, "JuliaFormat.toml"), "style = \"default\"\n")
    write(file, "foo(a,b)\n")
    code, out, _ = run_cli(["--check", "--diff", file])
    @test code == 1
    @test occursin("+foo(a, b)", out)
end

@testset "stdin" begin
    # Default: formatted text on stdout.
    code, out, _ = run_cli(["-"]; input="x=1\ny =  2\n")
    @test code == 0
    @test out == "x=1\ny = 2\n"

    # --check: exit 1 on unformatted input, 0 on formatted input.
    code, out, _ = run_cli(["-", "--check"]; input="y =  2\n")
    @test code == 1
    code, _, _ = run_cli(["-", "--check"]; input="y = 2\n")
    @test code == 0

    # --diff labels with --stdin-filename.
    dir = mktempdir()
    write(joinpath(dir, "JuliaFormat.toml"), "style = \"default\"\n")
    target = joinpath(dir, "code.jl")
    code, out, _ = run_cli(["-", "--diff", "--stdin-filename", target]; input="foo(a,b)\n")
    @test code == 0
    @test occursin(lowercase(replace(target, '\\' => '/')), lowercase(out))
    @test occursin("+foo(a, b)", out)

    # --stdin-filename anchors config discovery: an exclusion passes input through.
    write(joinpath(dir, "JuliaFormat.toml"), "exclude = [\"code.jl\"]\n")
    code, out, _ = run_cli(["-", "--stdin-filename", target]; input=MESSY)
    @test code == 0
    @test out == MESSY

    # Invalid combinations.
    code, _, err = run_cli(["-", "--list"]; input="x = 1\n")
    @test code == 2
    code, _, err = run_cli(["-", "--write"]; input="x = 1\n")
    @test code == 2
    code, _, err = run_cli(["-", joinpath(mktempdir(), "x.jl")]; input="x = 1\n")
    @test code == 2
    code, _, err = run_cli(["--stdin-filename", "foo.jl", mktempdir()])
    @test code == 2

    # Syntax errors report failure.
    code, _, err = run_cli(["-"]; input="function foo( end\n")
    @test code == 1
    @test occursin("failed to format", err)
end
