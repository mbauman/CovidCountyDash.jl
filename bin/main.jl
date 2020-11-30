using CovidCountyDash

if true
    # Patch up PlotlyBase with https://github.com/sglyon/PlotlyBase.jl/pull/35
    import PlotlyBase
    @eval PlotlyBase function GenericTrace(df::DataFrames.AbstractDataFrame; group=nothing, kind="scatter", kwargs...)
         d = Dict{Symbol,Any}(kwargs)
         if _has_group(df, group)
             _traces = map(dfg -> GenericTrace(dfg; kind=kind, name=_group_name(dfg, group), kwargs...), DataFrames.groupby(df, group))
             return GenericTrace[t for t in _traces]
         else
             if (group !== nothing)
                 @warn "Unknown group $(group), skipping"
            end
        end
        for (k, v) in d
            if isa(v, Symbol) && hasproperty(df, v)
                d[k] = df[!, v]
            elseif isa(v, Function)
                d[k] = v(df)
            end
        end
        GenericTrace(kind; d...)
    end
end

const df = download_and_preprocess(joinpath(@__DIR__, "..", "data", "pop2019.csv"))
@info "Got the data"

app = create_app(df)
@info "Setup and now serving..."
# Heroku passes the port as the first argument; JuliaHub as a PORT ENV var
port = something(tryparse(Int, length(ARGS) > 0 ? ARGS[1] : get(ENV, "PORT", "")), 8080)
run_server(app, "0.0.0.0", port)
