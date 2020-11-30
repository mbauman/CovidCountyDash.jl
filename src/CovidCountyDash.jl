module CovidCountyDash
import HTTP, CSV
using Dash, DashCoreComponents, DashHtmlComponents
using DataFrames, Dates, PlotlyBase, Statistics
using Base: splat

export download_and_preprocess, create_app, HTTP, DataFrame, run_server

function download_and_preprocess(popfile)
    d = CSV.read(IOBuffer(String(HTTP.get("https://raw.githubusercontent.com/nytimes/covid-19-data/master/us-counties.csv").body)), DataFrame, normalizenames=true)
    pop = CSV.read(popfile, DataFrame)
    dd = leftjoin(d, pop, on=:fips, matchmissing=:equal)
    # # New York City
    # All cases for the five boroughs of New York City (New York, Kings, Queens, Bronx and Richmond counties) are assigned to a single area called New York City.
    nyc_mask = (dd.state .== "New York") .& (dd.county .== "New York City")
    dd[nyc_mask, :pop] .=
        sum(pop.pop[pop.fips .∈ ((36061, # New York
                                 36047, # Kings
                                 36081, # Queens
                                 36005, # Bronx
                                 13245, # Richmond
                                 ),)])
    dd[nyc_mask, :county] .= "New York City¹"

    # # Kansas City, Mo
    # Four counties (Cass, Clay, Jackson and Platte) overlap the municipality of Kansas City, Mo. The cases and deaths that we show for these four counties are only for the portions exclusive of Kansas City. Cases and deaths for Kansas City are reported as their own line.
    mo = dd.state .== "Missouri"
    # 2018 estimated pop for KCMO: https://www.census.gov/quickfacts/fact/table/kansascitycitymissouri/PST045218
    dd[mo .& (dd.county .== "Kansas City"), :pop] .= 491918
    dd[mo .& (dd.county .== "Kansas City"), :county] .= "Kansas City²"
    # subtract out 2018 estimates of KCMO from counties: https://www.marc.org/Data-Economy/Metrodataline/Population/Current-Population-Data
    dd[mo .& (dd.county .== "Cass"), :pop] .-= 201
    dd[mo .& (dd.county .== "Clay"), :pop] .-= 126460
    dd[mo .& (dd.county .== "Jackson"), :pop] .-= 315801
    dd[mo .& (dd.county .== "Platte"), :pop] .-= 49456
    dd[mo .& (dd.county .== "Cass"), :county] .= "Cass³"
    dd[mo .& (dd.county .== "Clay"), :county] .= "Clay³"
    dd[mo .& (dd.county .== "Jackson"), :county] .= "Jackson³"
    dd[mo .& (dd.county .== "Platte"), :county] .= "Platte³"

    # # Joplin, MO
    # Dammit NYT. "Starting June 25, cases and deaths for Joplin are reported separately from Jasper and Newton counties. The cases and deaths reported for those counties are only for the portions exclusive of Joplin. Joplin cases and deaths previously appeared in the counts for those counties or as Unknown."
    # https://www.census.gov/quickfacts/fact/table/joplincitymissouri,US/PST045219
    dd[mo .& (dd.county .== "Joplin"), :pop] .= 50798
    dd[mo .& (dd.county .== "Joplin"), :county] .= "Joplin⁴"
    # Very little of Joplin is in Newton; cannot find exact figures. Guess a 95/5 split?
    dd[mo .& (dd.county .== "Jasper"), :pop] .-= 50798 * 95 ÷ 100
    dd[mo .& (dd.county .== "Newton"), :pop] .-= 50798 *  5 ÷ 100
    dd[mo .& (dd.county .== "Jasper"), :county] .= "Jasper⁵"
    dd[mo .& (dd.county .== "Newton"), :county] .= "Newton⁵"

    # Set all unknown counties to 0
    dd[dd.county .== "Unknown", :pop] .= 0
    # Except Guam, which _only_ has a single unknown county. This would be better handled by
    # using the states CSV separately when no counties are selected.
    isguam = dd.state .== "Guam"
    if length(unique(dd[isguam, :county])) == 1
        dd[isguam, :pop] .= pop[pop.fips .== 66000, :pop]
    end

    return dd
end

# utilities to compute the cases by day, subseted and aligned
isset(x) = x !== nothing && !isempty(x)
f32(x) = Float32(x)
f32(::Missing) = missing
rolling(f, v, n) = n == 1 ? v : [f32(f(@view v[max(firstindex(v),i-n+1):i])) for i in eachindex(v)]
function subset(df, states, counties)
    mask = isset(counties) ? (df.county .∈ (counties,)) .& (df.state .∈ (states,)) : df.state .∈ (states,)
    return combine(groupby(df[mask, :], :date), :cases=>sum, :deaths=>sum, :pop=>sum, renamecols=false)
end
const EMPTY = DataFrame(values=Float32[], popvalues=Float32[], dates=Date[],location=String[])
function precompute(df, states, counties; type=:cases, roll=1, value="values")
    !isset(states) && return EMPTY
    subdf = subset(df, states, counties)
    vals = subdf[!, type]
    values = value == "diff" ? [NaN32; rolling(mean, diff(vals), roll)] : vals
    popvalues = values .* (100 / maximum(subdf.pop))
    loc = !isset(counties) ?
        (length(states) <= 2 ? join(states, " + ") : "$(states[1]) + $(length(states)-1) other states") :
        (length(counties) <= 2 ? join(counties, " + ") * ", " * states[] :
            "$(counties[1]), $(states[]) + $(length(counties)-1) other counties")
    return DataFrame(values=values, popvalues=popvalues, dates=subdf.date, location=loc)
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
function plotit(df, value, type, roll, checkopts, pp...)
    roll = something(roll, 1)
    logy = checkopts === nothing ? false : "logy" in checkopts
    popnorm = checkopts === nothing ? false : "popnorm" in checkopts
    data = reduce(vcat, [precompute(df, state, county, type=Symbol(type), roll=roll, value=value) for (state, county) in Iterators.partition(pp, 2)])
    layout = Layout(
        xaxis_title = "Date",
        yaxis_title = value == "values" ? "Total confirmed $type" :
                      roll > 1 ? "Average daily $type (rolling $roll-day mean)" : "Number of daily $type",
        xaxis = Dict(),
        yaxis_ticksuffix = popnorm ? "%" : "",
        hovermode = "closest",
        title = string(value == "values" ? "Total " : "Daily " , "Confirmed ", uppercasefirst(type)),
        height = "40%",
        yaxis_type= logy ? "log" : "linear",
        yaxis_automargin = true,
    )
    isempty(data) && return Plot(data, layout, x = extrema(df.date), y = [NaN32, NaN32], mode="lines")
    y, customdata = popnorm ? (:popvalues, :values) : (:values, :popvalues)
    valtrace, poptrace = popnorm ? (:customdata, :y) : (:y, :customdata)
    perday = roll > 1 && value == "diff" ? "/day" : ""
    return Plot(data, layout,
        x = :dates,
        y = y,
        customdata = customdata,
        group = :location,
        hovertemplate = "%{x|%b %d}: %{$valtrace:,.1f} $type$perday (%{$poptrace:.2g}%)",
        mode = "lines",
    )
end

function create_app(df;max_lines=6)
    states = sort!(unique(df.state))
    app = dash(external_stylesheets=["https://stackpath.bootstrapcdn.com/bootstrap/4.4.1/css/bootstrap.min.css"])
    app.title = "🦠 COVID-19 Tracked by US County"
    app.layout =
        html_div(style=(padding="2%",), [
            html_h1("🦠 COVID-19 Tracked by US County", style=(textAlign = "center",)),
            html_div(style=(width="60%",margin="auto", textAlign="center"), [
                "Visualization of ",
                html_a("data", href="https://github.com/nytimes/covid-19-data"),
                " from ",
                html_a("The New York Times", href="https://www.nytimes.com/interactive/2020/us/coronavirus-us-cases.html"),
                ", based on reports from state and local health agencies",
                html_p("Loaded data through $(Dates.format(maximum(df.date), "U d"))",
                    style=(height="2rem", lineHeight="2rem",margin="0")),
                ]),
            html_div(className="row", [
                html_div(className="col-8",
                    html_table(style=(width="100%",),
                        vcat(html_tr([html_th("State",style=(width="40%",)),
                                      html_th("County",style=(width="60%",))]),
                             [html_tr([html_td(dcc_dropdown(id="state-$n", options=[(label=s, value=s) for s in states], multi=true), style=(width="40%",)),
                                      html_td(dcc_dropdown(id="county-$n", options=[], multi=true), style=(width="60%",))], id="scrow-$n")
                              for n in 1:max_lines])
                    )
                ),
                html_div(className="col-4", [
                    html_b("Options"),
                    dcc_radioitems(id="type", labelStyle=(display="block",),
                        options=[
                            (label="Confirmed positive cases", value="cases"),
                            (label="Confirmed deaths", value="deaths")],
                        value="cases"),
                    html_hr(style=(margin=".25em",)),
                    dcc_radioitems(id="values", labelStyle=(display="block",),
                        options=[
                            (label="Cumulative", value="values"),
                            (label="New daily cases", value="diff")],
                        value="diff"),
                    html_div(id="smoothing_selector", style=(visibility="visible", display="block"), [
                        html_span("Rolling", style=(var"padding-left"="1.5em",)),
                        dcc_input(id="roll", type="number", min=1, max=14, step=1, value=7, style=(margin="0 .5em 0 .5em",)),
                        html_span("day mean")
                    ]),
                    html_hr(style=(margin=".25em",)),
                    dcc_checklist(id="checkopts", labelStyle=(display="block",),
                        options=[
                            (label="Normalize by population", value="popnorm"),
                            (label="Use logarithmic y-axis", value="logy")
                        ],
                        value=["popnorm"])
                ])
            ]),
            html_div(style = (width="80%", display="block", margin="auto"), [
                dcc_graph(id = "theplot", figure=plotit(df, "values", "cases", 7, ["popnorm"], [], [])),
                html_span(id="footnote¹", style=(textAlign="center", display="none", fontSize="small"),
                    "¹ The five boroughs of New York City (New York, Kings, Queens, Bronx, and Richmond counties) are combined into a single entry."),
                html_span(id="footnote²", style=(textAlign="center", display="none", fontSize="small"),
                    "² Kansas City, MO is reported independently of the four counties it spans (Cass, Clay, Jackson, and Platte counties)"),
                html_span(id="footnote³", style=(textAlign="center", display="none", fontSize="small"),
                    "³ Excluding data from Kansas City, MO"),
                html_span(id="footnote⁴", style=(textAlign="center", display="none", fontSize="small"),
                    "⁴ Starting June 25, Joplin, MO is reported independently of the two counties it spans (Jasper and Newton counties)"),
                html_span(id="footnote⁵", style=(textAlign="center", display="none", fontSize="small"),
                    "⁵ Excluding data from Joplin, MO "),
                ]),
            html_br(),
            html_span([html_a("Code source", href="https://github.com/mbauman/CovidCountyDash.jl"),
                " (",  html_a("Julia", href="https://julialang.org"),
                " + ", html_a("Plotly Dash", href="https://plotly.com/dash/"),
                " + ", html_a("Dash.jl", href="https://juliahub.com/ui/Packages/Dash/oXkBb"),
                ")"],
                style=(textAlign = "center", display = "block"))
        ])

    hide_missing_row(s, c) = !isset(s) && !isset(c) ? (display="none",) : (display="table-row",)
    for n in 2:max_lines
        callback!(hide_missing_row, app, Output("scrow-$n", "style"), [Input("state-$n", "value"), Input("state-$(n-1)", "value")])
    end
    for n in 1:max_lines
        callback!(x->counties(df, x), app, Output("county-$n", "options"), Input("state-$n", "value"))
        callback!(x->nothing, app, Output("county-$n", "value"), Input("state-$n", "value"))
    end
    contains_footnote(x, ⁱ) = isset(x) && any(endswith.(x, ⁱ))
    for ⁱ in "¹²³⁴⁵"
        callback!(app, Output("footnote$ⁱ", "style"), Input.(["county-$n" for n in 1:max_lines], "value")) do counties...
            if any(contains_footnote.(counties, ⁱ))
                return (textAlign="center", display="block", fontSize="small")
            else
                return (textAlign="center", display="none", fontSize="small")
            end
        end
    end
    callback!((args...)->plotit(df, args...), app, Output("theplot", "figure"),
        splat(Input).([("values", "value"); ("type", "value"); ("roll", "value"); ("checkopts", "value");
                [("$t-$n", "value") for n in 1:max_lines for t in (:state, :county)]]))
    callback!(identity, app, Output("cases_or_deaths","children"), Input("type","value"))
    callback!(app, Output("values","options"), Input("type","value")) do type
        return [(label="Cumulative", value="values"), (label="New daily $(type)", value="diff")]
    end
    callback!(app, Output("smoothing_selector","style"), Input("values","value")) do value
        if value == "diff"
            return (visibility="visible", display="block")
        else
            return (visibility="hidden", display="none")
        end
    end
    return app
end
end
