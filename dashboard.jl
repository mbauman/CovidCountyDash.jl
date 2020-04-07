@info "Launched"
import HTTP, CSV
using DataFrames, Dates, PlotlyBase, Dashboards, Sockets

@info "Loaded"
const df = Ref(DataFrame(state=[], county=[], cases=[], deaths=[]))
@async df[] = CSV.read(IOBuffer(String(HTTP.get("https://raw.githubusercontent.com/nytimes/covid-19-data/master/us-counties.csv").body)), normalizenames=true)
const max_lines = 6

# utilities to compute the cases by day, subseted and aligned
subset(df, state, county) = df[(df.county .== county) .& (df.state .== state), :]
subset(df, state, county::Nothing) = by(df[df.state .== state, :], :date, cases=:cases=>sum, deaths=:deaths=>sum)
precompute(df, ::Nothing, ::Nothing; kwargs...) = DataFrame(days=Int[],values=Int[],diff=Int[],dates=Date[],location=String[])
function precompute(df, state, county; alignment = 10, type=:cases)
    subdf = subset(df, state, county)
    vals = subdf[:, type]
    dates = subdf[:, :date]
    idx = findfirst(vals .>= alignment)
    idx === nothing && return precompute(df, nothing, nothing)
    return DataFrame(days=(x->x.value).(dates .- dates[idx]),values=vals, dates = dates, diff = [missing; diff(vals)], location=county===nothing ? state : "$county, $state")
end
# Given a state, list its counties
counties(state) = NamedTuple{(:label, :value),Tuple{String,String}}[]
counties(state::String) = [(label=c, value=c) for c in sort!(unique(df[][df[].state .== state, :county]))]
# put together the plot given a sequence of alternating state/county pairs
function plotit(value, logy, type, realign, alignment, pp...)
    alignment = something(alignment, 10)
    data = reduce(vcat, [precompute(df[], state, county, type=Symbol(type), alignment=alignment) for (state, county) in Iterators.partition(pp, 2)])
    data.text = Dates.format.(data.dates, "U d")
    layout = Layout(
            xaxis_title = realign ? "Days since $alignment total $(type)" : "Date",
            yaxis_title = "Number of $(value == "values" ? "total" : "new daily") $(type)",
            xaxis = realign && !isempty(data) ? Dict(:range=>[-1, ceil(maximum(data.days)/5)*5]) : Dict(),
            hovermode = "closest",
            title = string(value == "values" ? "Total " : "Daily " , "Confirmed ", uppercasefirst(type)),
            height = "40%",
            yaxis_type= logy ? "log" : "linear",
        )
    isempty(data) && return Plot(data, layout)
    return Plot(data, layout,
        x = realign ? :days : :dates,
        y = Symbol(value),
        text = :text,
        group = :location,
        hovertemplate = "%{text}: %{y}",
        mode = "lines+markers",
        marker_size = 5,
        marker_line_width = 2,
        marker_opacity = 0.6,
    )
end
@info "Defined"
# The app itself:
app2 = Dash("🦠 COVID-19 Tracked by US County", external_stylesheets=["https://stackpath.bootstrapcdn.com/bootstrap/4.4.1/css/bootstrap.min.css"]) do
    html_div(style=(padding="2%",)) do
        dcc_interval(id="loader", interval=1000, max_intervals=-1),
        html_h1("🦠 COVID-19 Tracked by US County", style=(textAlign = "center",)),
        html_div(
            ["Visualization of ",
             html_a("data", href="https://github.com/nytimes/covid-19-data"),
             " from ",
             html_a("The New York Times", href="https://www.nytimes.com/interactive/2020/us/coronavirus-us-cases.html"),
             ", based on reports from state and local health agencies",
             html_div(dbc_spinner(), id="spinner")
             ],
            style=(width="60%",margin="auto", textAlign="center")),
        dbc_row() do
            dbc_col(width=8) do
                html_table(style=(width="100%",)) do
                    vcat(html_tr([html_th("State",style=(width="40%",)),
                                  html_th("County",style=(width="60%",))]),
                         [html_tr([html_td(dcc_dropdown(id="state-$n", options=[]), style=(width="40%",)),
                                  html_td(dcc_dropdown(id="county-$n", options=[]), style=(width="60%",))], id="scrow-$n")
                          for n in 1:max_lines])
                end
            end,
            dbc_col(width=4) do
                html_b("Options"),
                dbc_radioitems(id="type", options=[(label="Confirmed positive cases", value="cases"), (label="Confirmed deaths", value="deaths")], value="cases"),
                html_hr(style=(margin=".25em",)),
                dbc_radioitems(id="values", options=[(label="Cumulative", value="values"), (label="New daily cases", value="diff")], value="values"),
                html_hr(style=(margin=".25em",)),
                html_div(html_label((dbc_checkbox(id="realign", checked=true, style=(margin="0 .5em 0 .1em",)), "Realign by initial value"))),
                html_div(id="alignment_selector", style=(visibility="visible", display="block")) do
                    html_span("Align on", style=(var"padding-left"="1.5em",)),
                    dcc_input(id="alignment", type="number", placeholder="alignment",min=1, max=10000, step=1, value=10, style=(margin="0 .5em 0 .5em",)),
                    html_span("total "),
                    html_span("cases", id="cases_or_deaths")
                end,
                html_label((dbc_checkbox(id="logy", checked=true, style=(margin="0 .5em 0 .1em",)), "Use logarithmic y-axis"))
            end
        end,
        html_div(dcc_graph(id = "theplot", figure=Plot()), style = (width="80%", display="block", margin="auto")),
        html_br(),
        html_a("Code source (Julia + Plotly Dash + Dashboards.jl)", href="https://github.com/mbauman/covid19",
            style=(textAlign = "center", display = "block"))
    end
end
@info "Prepared"

callback!(app2, CallbackId([], [(:loader,:n_intervals)], [[(Symbol(:state,"-",n), :options) for n in 1:max_lines]; (:spinner, :children); (:loader,:max_intervals)])) do n
    isempty(df[]) && return [fill([], max_lines); dbc_spinner(); -1]
    states = sort!(unique(df[].state))
    return [fill([(label=s, value=s) for s in states], max_lines); html_p("Loaded data through $(Dates.format(maximum(df[].date), "U d"))", style=(height="2rem", lineHeight="2rem",margin="0")); 0]
end
hide_missing_row(::Nothing, ::Nothing) = (display="none",)
hide_missing_row(_, _) = (display="table-row",)
for n in 2:max_lines
    callback!(hide_missing_row, app2, CallbackId([], [(Symbol(:state,"-",n), :value), (Symbol(:state,"-",n-1), :value)], [(Symbol(:scrow,"-",n), :style)]))
end
for n in 1:max_lines
    callback!(counties, app2, CallbackId([], [(Symbol(:state,"-",n), :value)], [(Symbol(:county,"-",n), :options)]))
end
callback!(plotit, app2, CallbackId([], [(:values, :value); (:logy, :checked); (:type, :value); (:realign, :checked); (:alignment, :value); [(Symbol(t,"-",n), :value) for n in 1:max_lines for t in (:state, :county)]], [(:theplot, :figure)]))
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
@info "Hollared back at"

handler = make_handler(app2, debug = true)
@info "Setup and now serving..."
HTTP.serve(handler, ip"0.0.0.0", parse(Int, length(ARGS) > 0 ? ARGS[1] : "8080"))
