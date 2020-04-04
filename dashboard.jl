@info "Launched"
import HTTP, CSV
using DataFrames, Dates, PlotlyBase, Dashboards, Sockets

@info "Loaded"
const df = Ref(DataFrame(state=[], county=[], cases=[], deaths=[]))
@async df[] = CSV.read(IOBuffer(String(HTTP.get("https://raw.githubusercontent.com/nytimes/covid-19-data/master/us-counties.csv").body)), normalizenames=true)
const max_lines = 5

# utilities to compute the cases by day, subseted and aligned
subset(df, state, county) = df[(df.county .== county) .& (df.state .== state), :]
subset(df, state, county::Nothing) = by(df[df.state .== state, :], :date, cases=:cases=>sum, deaths=:deaths=>sum)
precompute(df, ::Nothing, ::Nothing; kwargs...) = DataFrame(days=Int[],values=Int[],dates=Date[],location=String[])
function precompute(df, state, county; alignment = 10, type=:cases)
    subdf = subset(df, state, county)
    vals = subdf[:, type]
    dates = subdf[:, :date]
    idx = findfirst(vals .>= alignment)
    idx === nothing && return precompute(df, nothing, nothing)
    return DataFrame(days=(x->x.value).(dates .- dates[idx]),values=vals, dates = dates, location=county===nothing ? state : "$county, $state")
end
# Given a state, list its counties
counties(state) = NamedTuple{(:label, :value),Tuple{String,String}}[]
counties(state::String) = [(label=c, value=c) for c in sort!(unique(df[][df[].state .== state, :].county))]
# put together the plot given a sequence of alternating state/county pairs
function plotit(ytransform, type, align_or_timeline, alignment, pp...)
    align = align_or_timeline == "align"
    alignment = something(alignment, 10)
    data = reduce(vcat, [precompute(df[], state, county, type=Symbol(type), alignment=alignment) for (state, county) in Iterators.partition(pp, 2)])
    isempty(data) && return Plot()
    return Plot(data,
        Layout(
            xaxis_title = align ? "Days since $alignment $(type)" : "Date",
            yaxis_title = "Number of $(type)",
            xaxis = align ? Dict(:range=>[-1, ceil(maximum(data.days)/5)*5]) : Dict(),
            hovermode = "closest",
            title = uppercasefirst(type),
            height = "40%",
            yaxis_type= ytransform,
        ),
        x = align ? :days : :dates,
        y = :values,
        group = :location,
        mode = "lines+markers",
        marker_size = 5,
        marker_line_width = 2,
        marker_opacity = 0.6,
    )
end
@info "Defined"
# The app itself:
app2 = Dash("🦠 COVID-19 Tracked by County 🗺️", external_stylesheets=["https://stackpath.bootstrapcdn.com/bootstrap/4.4.1/css/bootstrap.min.css"]) do
    html_div(style=(padding="2%",)) do
        dcc_interval(id="loader", interval=1000, max_intervals=-1),
        html_h1("🦠 COVID-19 Tracked by County 🗺️", style=(textAlign = "center",)),
        html_a("Source data (loading...)", id="source_link", href="https://github.com/nytimes/covid-19-data",
            style=(textAlign = "center", display = "block",)),
        dbc_row() do
            dbc_col(width=8) do
                html_table(style=(width="100%",)) do
                    vcat(html_tr([html_th("State",style=(width="40%",)),
                                  html_th("County",style=(width="60%",))]),
                         [html_tr([html_td(dcc_dropdown(id="state-$n", options=[]), style=(width="40%",)),
                                  html_td(dcc_dropdown(id="county-$n", options=[]), style=(width="60%",))])
                          for n in 1:max_lines])
                end
            end,
            dbc_col(width=4) do
                html_b("Options"),
                dbc_radioitems(id="type", options=[(label="Confirmed positive cases", value="cases"), (label="Confirmed deaths", value="deaths")], value="cases"),
                html_hr(style=(margin=".25em",)),
                dbc_radioitems(id="align_or_time", options=[(label="No alignment", value="timeline"), (label="Align by initial value", value="align"), ], value="align"),
                html_div(id="alignment_selector", style=(visibility="visible", height="auto")) do
                    "Align on",
                    dcc_input(id="alignment", type="number", placeholder="alignment",min=1, max=10000, step=1, value=10, style=(margin="0 1em 0 1em",)),
                    html_span("cases", id="cases_or_deaths")
                end,
                html_br(),
                html_hr(style=(margin=".25em",)),
                "Y-axis transformation:",
                dbc_radioitems(id="ytransform", options=[(label="Logarithmic", value="log"), (label="Linear", value="linear")], value="log")
            end
        end,
        html_div(dcc_graph(id = "theplot", figure=Plot()), style = (width="80%", display="block", margin="auto")),
        html_br(),
        html_a("Code source (Julia + Plotly Dash + Dashboards.jl)", href="https://github.com/mbauman/covid19",
            style=(textAlign = "center", display = "block"))
    end
end
@info "Prepared"

callback!(app2, CallbackId([], [(:loader,:n_intervals)], [[(Symbol(:state,"-",n), :options) for n in 1:max_lines]; (:source_link, :children); (:loader,:max_intervals)])) do n
    isempty(df[]) && return [[[] for i in 1:max_lines]; "Source data (loading...)"; -1]
    states = sort!(unique(df[].state))
    return [[[(label=s, value=s) for s in states] for i in 1:max_lines]; "Source data (loaded data through $(maximum(df[].date)))"; 0]
end
for n in 1:max_lines
    callback!(counties, app2, CallbackId([], [(Symbol(:state,"-",n), :value)], [(Symbol(:county,"-",n), :options)]))
end
callback!(plotit, app2, CallbackId([], [(:ytransform, :value); (:type, :value); (:align_or_time, :value); (:alignment, :value); [(Symbol(t,"-",n), :value) for n in 1:max_lines for t in (:state, :county)]], [(:theplot, :figure)]))
callback!(identity, app2, callid"type.value => cases_or_deaths.children")
callback!(app2, callid"align_or_time.value => alignment_selector.style") do val
    if val == "align"
        return (visibility="visible", height="auto")
    else
        return (visibility="hidden", height="0")
    end
end
@info "Hollared back at"

handler = make_handler(app2, debug = true)
@info "Setup and now serving..."
HTTP.serve(handler, ip"0.0.0.0", parse(Int, length(ARGS) > 0 ? ARGS[1] : "8080"))
