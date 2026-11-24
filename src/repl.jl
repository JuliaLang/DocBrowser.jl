# Opening the browser from the REPL's help mode, for a REPL that does not do it by itself.
# There is no hook for this, so the help mode's key bindings and its handler for finished lines
# are changed once the REPL is set up.

const LineEdit = REPL.LineEdit

# Raw mode and bracketed paste, as the REPL's prompt has them.
function enter_input_mode(term)
    isdefined(LineEdit, :enter_input_mode) && return LineEdit.enter_input_mode(term)
    REPL.Terminals.raw!(term, true)
    term isa REPL.Terminals.UnixTerminal && write(term.out_stream, "\e[?2004h")
    return nothing
end

# Whether a line of help mode names a place in the docs, which the browser opens.
is_docs_place(line::AbstractString) = occursin(r"^\s*(docs:|https?://(pkg)?docs\.julialang\.org/)", line)

buffer_text(s) = String(take!(copy(LineEdit.buffer(s))))

# Run the browser. A failure is reported, so that it does not break the prompt.
function browse_from_repl(term, query)
    try
        return Base.invokelatest(browse, term; query, context=Base.active_module())
    catch err
        err isa InterruptException || @error "The documentation browser failed" exception=(err, catch_backtrace())
        return nothing
    end
end

# Run the browser in place of the current prompt, then return to `julia_prompt` with the name
# the user picked, if any, typed in.
function open_from_prompt(s::LineEdit.MIState, julia_prompt::LineEdit.Prompt)
    term = LineEdit.terminal(s)
    mode = LineEdit.mode(s)
    query = buffer_text(s)
    termbuf = LineEdit.TerminalBuffer(IOBuffer())
    s.mode_state[mode] = LineEdit.deactivate(mode, LineEdit.state(s), termbuf, term)
    LineEdit.commit_changes(term, termbuf)
    name = browse_from_repl(term, query)
    mode isa LineEdit.Prompt && LineEdit.reset_state(LineEdit.state(s, mode))
    enter_input_mode(term)
    s.current_mode = julia_prompt
    # Whatever was typed went to the browser, so the prompt starts empty, as after `help?>`.
    if haskey(s.mode_state, julia_prompt)
        LineEdit.reset_state(LineEdit.state(s, julia_prompt))
    else
        s.mode_state[julia_prompt] = LineEdit.init_state(term, julia_prompt)
    end
    termbuf = LineEdit.TerminalBuffer(IOBuffer())
    LineEdit.activate(julia_prompt, LineEdit.state(s, julia_prompt), termbuf, term)
    LineEdit.commit_changes(term, termbuf)
    name === nothing || LineEdit.edit_insert(LineEdit.buffer(s), name)
    LineEdit.refresh_line(s)
    return nothing
end

# The prompt of a mode, as plain text.
prompt_text(m) = m isa LineEdit.Prompt ? as_string(LineEdit.prompt_string(m.prompt)) : ""

const INSTALLED = WeakKeyDict{Any,Nothing}()

"""
    DocBrowser.install(repl = Base.active_repl)

Make Enter on an empty `help?>` prompt, or on a place in the docs, open the browser. Loading
the package does this for the running REPL, or for the REPL that starts next.
"""
function install(repl = Base.active_repl)
    haskey(INSTALLED, repl) && return nothing
    modes = repl.interface.modes
    i = findfirst(m -> endswith(prompt_text(m), "help?> "), modes)
    j = findfirst(m -> endswith(prompt_text(m), "julia> "), modes)
    (i === nothing || j === nothing) && return nothing
    help, julia_prompt = modes[i]::LineEdit.Prompt, modes[j]::LineEdit.Prompt
    enter = help.keymap_dict['\r']
    help.keymap_dict = LineEdit.keymap_merge(help.keymap_dict, Dict{Any,Any}(
        '\r' => function (s::LineEdit.MIState, o...)
            isempty(s) || is_docs_place(buffer_text(s)) || return enter(s, o...)
            open_from_prompt(s, julia_prompt)
        end,
        # Alt-Enter opens it at what was typed
        "\e\r" => (s::LineEdit.MIState, o...) -> open_from_prompt(s, julia_prompt),
    ))
    question = julia_prompt.keymap_dict['?']
    julia_prompt.keymap_dict = LineEdit.keymap_merge(julia_prompt.keymap_dict, Dict{Any,Any}(
        '?' => function (s::LineEdit.MIState, o...)
            question(s, o...)
            LineEdit.mode(s) === help && isempty(s) || return
            # shown until the first key press redraws the line
            LineEdit.state(s, help).hint = "press return to browse the docs"
            LineEdit.refresh_line(s)
        end,
    ))
    # A pasted `help?> docs: ...` line reaches the mode's handler without a key press.
    done = help.on_done
    help.on_done = function (s, buf, ok)
        line = String(take!(copy(buf)))
        ok && is_docs_place(line) || return done(s, buf, ok)
        name = browse_from_repl(LineEdit.terminal(s), line)
        LineEdit.transition(s, julia_prompt)
        name === nothing || (LineEdit.edit_insert(LineEdit.buffer(s), name); LineEdit.refresh_line(s))
        return nothing
    end
    INSTALLED[repl] = nothing
    return nothing
end

function install_when_ready()
    isinteractive() || return nothing
    repl = isdefined(Base, :active_repl) ? Base.active_repl : nothing
    if repl isa REPL.LineEditREPL && isdefined(repl, :interface)
        dynamic(install)(repl)
    else
        # Set up the interface the way the REPL would, so that it can be changed before it runs.
        atreplinit() do repl
            repl isa REPL.LineEditREPL || return
            isdefined(repl, :interface) || (repl.interface = REPL.setup_interface(repl))
            dynamic(install)(repl)
        end
    end
    return nothing
end
