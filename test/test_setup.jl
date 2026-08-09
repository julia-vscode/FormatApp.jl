@testmodule CLIHelper begin
    using FormatApp

    # Run FormatApp._run with captured stdout/stderr, returning
    # (exit_code, stdout::String, stderr::String). Optionally feeds `input` as stdin.
    function run_cli(args::Vector{String}; input::Union{Nothing,String}=nothing)
        out_path, out_io = mktemp()
        err_path, err_io = mktemp()
        local code
        try
            if input === nothing
                code = redirect_stdio(() -> FormatApp._run(args); stdout=out_io, stderr=err_io)
            else
                in_path, in_io = mktemp()
                write(in_io, input)
                close(in_io)
                open(in_path) do in_stream
                    code = redirect_stdio(() -> FormatApp._run(args); stdout=out_io, stderr=err_io, stdin=in_stream)
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
end
