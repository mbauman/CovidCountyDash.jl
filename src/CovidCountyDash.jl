module CovidCountyDash
import HTTP, CSV
using Dash, DashCoreComponents, DashHtmlComponents
using DataFrames, Dates, PlotlyBase, Statistics
using DataStructures: OrderedDict
using Base: splat

export download_and_preprocess, create_app, HTTP, DataFrame, run_server

const POP = CSV.read(joinpath(@__DIR__, "..", "data", "pop2019.csv"), DataFrame)
const STATES = OrderedDict(f=>s for (s, f) in eachrow(select(filter(x->ismissing(x.county), POP), :state, :fips)))
const COUNTIES = OrderedDict(sf=>OrderedDict(cf=>c for (c, cf) in eachrow(select(filter(x->sf == x.fips÷1000, POP), :county, :fips))) for sf in keys(STATES))

counties(::Nothing) = []
counties(statefips) = length(statefips) == 1 ? [(label=c, value=fips) for (fips, c) in COUNTIES[statefips[]]] : []

const SHORTSTATE = Dict(
     1 => "AL",  2 => "AK",  4 => "AZ",  5 => "AR",  6 => "CA",  8 => "CO",  9 => "CT",
    10 => "DE", 11 => "DC", 12 => "FL", 13 => "GA", 15 => "HI", 16 => "ID", 17 => "IL",
    18 => "IN", 19 => "IA", 20 => "KS", 21 => "KY", 22 => "LA", 23 => "ME", 24 => "MD",
    25 => "MA", 26 => "MI", 27 => "MN", 28 => "MS", 29 => "MO", 30 => "MT", 31 => "NE",
    32 => "NV", 33 => "NH", 34 => "NJ", 35 => "NM", 36 => "NY", 37 => "NC", 38 => "ND",
    39 => "OH", 40 => "OK", 41 => "OR", 42 => "PA", 44 => "RI", 45 => "SC", 46 => "SD",
    47 => "TN", 48 => "TX", 49 => "UT", 50 => "VT", 51 => "VA", 53 => "WA", 54 => "WV",
    55 => "WI", 56 => "WY", 66 => "GU", 69 => "MP", 72 => "PR", 78 => "VI", )

labelname(::Nothing) = nothing
labelname(fips) = fips < 1000 ? SHORTSTATE[fips] : COUNTIES[fips ÷ 1000][fips]

function download_and_preprocess()
    counties = CSV.read(IOBuffer(String(HTTP.get("https://raw.githubusercontent.com/nytimes/covid-19-data/master/us-counties.csv").body)), DataFrame, normalizenames=true)
    states = CSV.read(IOBuffer(String(HTTP.get("https://raw.githubusercontent.com/nytimes/covid-19-data/master/us-states.csv").body)), DataFrame, normalizenames=true)
    states[!, :county] .= missing
    d = transform!(vcat(counties, states),
        [:state, :county, :fips]=>ByRow() do state, county, fips
            if ismissing(fips)
                if state == "New York" && county == "New York City"
                    36998
                elseif state == "Missouri" && county == "Kansas City"
                    29998
                elseif state == "Missouri" && county == "Joplin"
                    29997
                elseif county == "Unknown"
                    POP[(POP.state .== state) .& ismissing.(POP.county), :fips][]*1000+999
                else
                    @warn "Missing fips for $county, $state"
                    fips
                end
            else
                fips
            end
        end => :fips)
    return sort!(d, [:fips, :date])
end

# utilities to compute the cases by day, subseted and aligned
isset(x) = x !== nothing && !isempty(x)
f32(x) = Float32(x)
f32(::Missing) = missing
rolling(f, v, n) = n == 1 ? v : [f32(f(@view v[max(firstindex(v),i-n+1):i])) for i in eachindex(v)]
function subset(df, states, counties)
    f = x->isset(counties) ? x.fips ∈ counties : x.fips ∈ states
    subset = sort!(combine(groupby(filter(f, df; view=true), :date), :cases=>sum, :deaths=>sum, renamecols=false), :date)
    return subset, sum(filter(f, POP; view=true).pop)
end
const EMPTY = DataFrame(values=Float32[], popvalues=Float32[], dates=Date[],location=String[])
function precompute(df, states, counties; type=:cases, roll=1, value="values")
    !isset(states) && return EMPTY
    subdf, pop = subset(df, states, counties)
    isempty(subdf) && return EMPTY
    vals = subdf[!, type]
    values = value == "diff" ? [NaN32; rolling(mean, diff(vals), roll)] : vals
    popvalues = values .* (100 / pop)
    loc = isset(counties) ?
        (length(counties) <= 2 ? join(labelname.(counties), " + ") * ", " * labelname(states[]) :
            "$(labelname(counties[1])), $(labelname(states[])) + $(length(counties)-1) other counties") :
        (length(states) <= 2 ? join(labelname.(states), " + ") :
            "$(labelname(states[1])) + $(length(states)-1) other states")
    return DataFrame(values=values, popvalues=popvalues, dates=subdf.date, location=loc)
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
                             [html_tr([html_td(dcc_dropdown(id="state-$n", options=[(label=s, value=f) for (f, s) in STATES], multi=true), style=(width="40%",)),
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
        callback!(counties, app, Output("county-$n", "options"), Input("state-$n", "value"))
        callback!(x->nothing, app, Output("county-$n", "value"), Input("state-$n", "value"))
    end
    contains_footnote(fips, ⁱ) = isset(fips) && any(endswith.(labelname.(fips), ⁱ))
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
