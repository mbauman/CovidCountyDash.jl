module CovidCountyDash
import HTTP, CSV
using DataFrames, Dates, PlotlyBase, Dashboards, Sockets, Statistics

export download_and_preprocess, create_app, make_handler, HTTP, DataFrame, @ip_str

function download_and_preprocess(popfile)
    d = CSV.read(IOBuffer(String(HTTP.get("https://raw.githubusercontent.com/nytimes/covid-19-data/master/us-counties.csv").body)), normalizenames=true)
    pop = CSV.read(popfile)
    dd = join(d, pop, on=:fips, kind=:left)
    # # New York City
    # All cases for the five boroughs of New York City (New York, Kings, Queens, Bronx and Richmond counties) are assigned to a single area called New York City.
    dd[(dd.state .== "New York") .& (dd.county .== "New York City"), :pop] .=
        sum(pop.pop[pop.fips .∈ ((36061, # New York
                                 36047, # Kings
                                 36081, # Queens
                                 36005, # Bronx
                                 13245, # Richmond
                                 ),)])
    # # Kansas City, Mo
    # Four counties (Cass, Clay, Jackson and Platte) overlap the municipality of Kansas City, Mo. The cases and deaths that we show for these four counties are only for the portions exclusive of Kansas City. Cases and deaths for Kansas City are reported as their own line.
    mo = dd.state .== "Missouri"
    # 2018 estimated pop for KCMO: https://www.census.gov/quickfacts/fact/table/kansascitycitymissouri/PST045218
    dd[mo .& (dd.county .== "Kansas City"), :pop] .= 491918
    # subtract out 2018 estimates of KCMO from counties: https://www.marc.org/Data-Economy/Metrodataline/Population/Current-Population-Data
    dd[mo .& (dd.county .== "Cass"), :pop] .-= 201
    dd[mo .& (dd.county .== "Clay"), :pop] .-= 126460
    dd[mo .& (dd.county .== "Jackson"), :pop] .-= 315801
    dd[mo .& (dd.county .== "Platte"), :pop] .-= 49456
    # Set all unknown counties to 0
    dd[dd.county .== "Unknown", :pop] .= 0
    return dd
end

# utilities to compute the cases by day, subseted and aligned
isset(x) = x !== nothing && !isempty(x)
rolling(f, v, n) = n == 1 ? v : [f(@view v[max(firstindex(v),i-n+1):i]) for i in eachindex(v)]
function subset(df, states, counties)
    mask = isset(counties) ? (df.county .∈ (counties,)) .& (df.state .∈ (states,)) : df.state .∈ (states,)
    return by(df[mask, :], :date, cases=:cases=>sum, deaths=:deaths=>sum, pop=:pop=>sum)
end
function precompute(df, states, counties; alignment = 10, type=:cases, roll=1, popnorm=false)
    !isset(states) && return DataFrame(days=Int[],values=Int[],diff=Int[],dates=Date[],location=String[])
    subdf = subset(df, states, counties)
    vals = float.(subdf[:, type])
    dates = subdf[:, :date]
    idx = findfirst(vals .>= alignment)
    crossing = idx !== nothing ? dates[idx] : maximum(dates) + Day(1)
    if popnorm
        vals .*= 100 ./ subdf.pop
    end
    loc = !isset(counties) ?
        (length(states) <= 2 ? join(states, " + ") : "$(states[1]) + $(length(states)-1) other states") :
        (length(counties) <= 2 ? join(counties, " + ") * ", " * states[] :
            "$(counties[1]), $(states[]) + $(length(counties)-1) other counties")
    return DataFrame(days=(x->x.value).(dates .- crossing),values=vals, dates = dates, diff = [missing; rolling(mean, diff(vals), roll)], location=loc)
end
# Given a state, list its counties
function counties(df, states)
    !isset(states) && return NamedTuple{(:label, :value),Tuple{String,String}}[]
    if length(states) == 1
        [(label=c, value=c) for c in sort!(unique(df[df.state .== states[1], :county]))]
    else
        # We don't keep the state/county pairings straight so disable it
        # [(label="$c, $s", value=c) for s in states for c in sort!(unique(df[df.state .== s, :county]))]
        NamedTuple{(:label, :value),Tuple{String,String}}[]
    end
end
# put together the plot given a sequence of alternating state/county pairs
function plotit(df, value, logy, type, realign, alignment, roll, popnorm, pp...)
    alignment = something(alignment, 10)
    roll = something(roll, 1)
    data = reduce(vcat, [precompute(df, state, county, type=Symbol(type), alignment=alignment, roll=roll, popnorm=popnorm) for (state, county) in Iterators.partition(pp, 2)])
    data.text = Dates.format.(data.dates, "U d")
    layout = Layout(
        xaxis_title = realign ? "Days since $alignment total $(type)" : "Date",
        yaxis_title = value == "values" ? "Total confirmed $type" :
                      roll > 1 ? "Average daily $type (rolling $roll-day mean)" : "Number of daily $type",
        xaxis = realign && !isempty(data) ? Dict(:range=>[-1, ceil(maximum(data.days)/5)*5]) : Dict(),
        yaxis_ticksuffix = popnorm ? "%" : "",
        hovermode = "closest",
        title = string(value == "values" ? "Total " : "Daily " , "Confirmed ", uppercasefirst(type)),
        height = "40%",
        yaxis_type= logy ? "log" : "linear",
        margin=(l=220,),
    )
    isempty(data) && return Plot(data, layout)
    return Plot(data, layout,
        x = realign ? :days : :dates,
        y = Symbol(value),
        text = :text,
        group = :location,
        hovertemplate = "%{text}: %{y}",
        mode = "lines",
    )
end

function create_app(df;max_lines=6)
    states = sort!(unique(df.state))
    app2 = Dash("🦠 COVID-19 Tracked by US County", external_stylesheets=["https://stackpath.bootstrapcdn.com/bootstrap/4.4.1/css/bootstrap.min.css"]) do
        html_div(style=(padding="2%",), [
            html_h1("🦠 COVID-19 Tracked by US County", style=(textAlign = "center",)),
            html_div(style=(width="60%",margin="auto", textAlign="center"), [
                "Visualization of ",
                html_a("data", href="https://github.com/nytimes/covid-19-data"),
                " from ",
                html_a("The New York Times", href="https://www.nytimes.com/interactive/2020/us/coronavirus-us-cases.html"),
                ", based on reports from state and local health agencies; inspired by ",
                html_a("John Burn-Murdoch's", href="https://twitter.com/jburnmurdoch"),
                " ",
                html_a("analyses", href="https://www.ft.com/coronavirus-latest"),
                " of national-level data",
                html_p("Loaded data through $(Dates.format(maximum(df.date), "U d"))",
                    style=(height="2rem", lineHeight="2rem",margin="0")),
                ]),
            dbc_row([
                dbc_col(width=8,
                    html_table(style=(width="100%",),
                        vcat(html_tr([html_th("State",style=(width="40%",)),
                                      html_th("County",style=(width="60%",))]),
                             [html_tr([html_td(dcc_dropdown(id="state-$n", options=[(label=s, value=s) for s in states], multi=true), style=(width="40%",)),
                                      html_td(dcc_dropdown(id="county-$n", options=[], multi=true), style=(width="60%",))], id="scrow-$n")
                              for n in 1:max_lines])
                    )
                ),
                dbc_col(width=4, [
                    html_b("Options"),
                    dbc_radioitems(id="type", options=[(label="Confirmed positive cases", value="cases"), (label="Confirmed deaths", value="deaths")], value="cases"),
                    html_hr(style=(margin=".25em",)),
                    dbc_radioitems(id="values", options=[(label="Cumulative", value="values"), (label="New daily cases", value="diff")], value="diff"),
                    html_div(id="smoothing_selector", style=(visibility="visible", display="block"), [
                        html_span("Rolling", style=(var"padding-left"="1.5em",)),
                        dcc_input(id="roll", type="number", placeholder="alignment", min=1, max=10, step=1, value=7, style=(margin="0 .5em 0 .5em",)),
                        html_span("day mean")
                    ]),
                    html_hr(style=(margin=".25em",)),
                    html_div(html_label((dbc_checkbox(id="realign", checked=false, style=(margin="0 .5em 0 .1em",)), "Realign by initial value"))),
                    html_div(id="alignment_selector", style=(visibility="visible", display="block"), [
                        html_span("Align on", style=(var"padding-left"="1.5em",)),
                        dcc_input(id="alignment", type="number", placeholder="alignment", min=1, max=10000, step=1, value=10, style=(margin="0 .5em 0 .5em",)),
                        html_span("total "),
                        html_span("cases", id="cases_or_deaths")
                        ]),
                    html_label((dbc_checkbox(id="popnorm", checked=false, style=(margin="0 .5em 0 .1em",)), "Normalize by population")),
                    html_br(),
                    html_label((dbc_checkbox(id="logy", checked=false, style=(margin="0 .5em 0 .1em",)), "Use logarithmic y-axis"))
                ])
            ]),
            html_div(dcc_graph(id = "theplot", figure=Plot()), style = (width="80%", display="block", margin="auto")),
            html_br(),
            html_a("Code source (Julia + Plotly Dash + Dashboards.jl)", href="https://github.com/mbauman/covid19",
                style=(textAlign = "center", display = "block"))
        ])
    end

    hide_missing_row(s, c) = !isset(s) && !isset(c) ? (display="none",) : (display="table-row",)
    for n in 2:max_lines
        callback!(hide_missing_row, app2, CallbackId([], [(Symbol(:state,"-",n), :value), (Symbol(:state,"-",n-1), :value)], [(Symbol(:scrow,"-",n), :style)]))
    end
    for n in 1:max_lines
        callback!(x->counties(df, x), app2, CallbackId([], [(Symbol(:state,"-",n), :value)], [(Symbol(:county,"-",n), :options)]))
        callback!(x->nothing, app2, CallbackId([], [(Symbol(:state,"-",n), :value)], [(Symbol(:county,"-",n), :value)]))
    end
    callback!((args...)->plotit(df, args...), app2, CallbackId([], [(:values, :value); (:logy, :checked); (:type, :value); (:realign, :checked); (:alignment, :value); (:roll, :value); (:popnorm, :checked); [(Symbol(t,"-",n), :value) for n in 1:max_lines for t in (:state, :county)]], [(:theplot, :figure)]))
    callback!(identity, app2, callid"type.value => cases_or_deaths.children")
    callback!(app2, callid"type.value => values.options") do type
        return [(label="Cumulative", value="values"), (label="New daily $(type)", value="diff")]
    end
    callback!(app2, callid"realign.checked => alignment_selector.style") do realign
        if realign
            return (visibility="visible", display="block")
        else
            return (visibility="hidden", display="none")
        end
    end
    callback!(app2, callid"values.value => smoothing_selector.style") do value
        if value == "diff"
            return (visibility="visible", display="block")
        else
            return (visibility="hidden", display="none")
        end
    end
    return app2
end
end