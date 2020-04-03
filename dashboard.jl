@info "Launched"
import HTTP, CSV
using DataFrames, Dates, PlotlyBase, Dashboards, Sockets

@info "Loaded"
const df = Ref(DataFrame(state=[], county=[], cases=[], deaths=[]))
@async df[] = CSV.read(IOBuffer(String(HTTP.get("https://raw.githubusercontent.com/nytimes/covid-19-data/master/us-counties.csv").body)), normalizenames=true)
const max_lines = 4

# utilities to compute the cases by day, subseted and aligned
subset(df, state, county) = df[(df.county .== county) .& (df.state .== state), :]
subset(df, state, county::Nothing) = by(df[df.state .== state, :], :date, cases=:cases=>sum, deaths=:deaths=>sum)
precompute(df, ::Nothing, ::Nothing; kwargs...) = DataFrame(days=Int[0],cases=Int[1],location=String[""])
function precompute(df, state, county; alignment = 10, type=:cases)
    subdf = subset(df, state, county)
    vals = subdf[:, type]
    dates = subdf[:, :date]
    idx = findfirst(vals .>= alignment)
    idx === nothing && return precompute(df, nothing, nothing)
    return DataFrame(days=(x->x.value).(dates .- dates[idx]),cases=vals, location=county===nothing ? state : "$county, $state")
end
# Given a state, list its counties
counties(state) = NamedTuple{(:label, :value),Tuple{String,String}}[]
counties(state::String) = [(label=c, value=c) for c in sort!(unique(df[][df[].state .== state, :].county))]
# put together the plot given a sequence of alternating state/county pairs
function plotit(ytransform, type, alignment, pp...)
    alignment = something(alignment, 10)
    data = reduce(vcat, [precompute(df[], state, county, type=Symbol(type), alignment=alignment) for (state, county) in Iterators.partition(pp, 2)])
    return Plot(data,
        Layout(
            xaxis_title = "Days since $alignment $(type)",
            yaxis_title = "Number of $(type)",
            hovermode = "closest",
            title = uppercasefirst(type),
            height = "40%",
            yaxis_type= ytransform,
        ),
        x = :days,
        y = :cases,
        group = :location,
        mode = "lines+markers",
        marker_size = 5,
        marker_line_width = 2,
        marker_opacity = 0.6,
    )
end
@info "Defined"
# The app itself:
app2 = Dash("🦠 COVID-19 Tracked by County 🗺️") do
    html_div() do
        #Sets and styles heading/title
        html_h1("🦠 COVID-19 Tracked by County 🗺️",
            style=(
               textAlign = "center",
            )
        ),
        dcc_interval(id="loader", interval=1000, max_intervals=-1),
        html_a("Source data (loading...)", id="source_link", href="https://github.com/nytimes/covid-19-data",
            style=(
               textAlign = "center",
               display = "block",
            )
        ),
        html_div(style = (width="80%", display="block", padding="2% 10%")) do
            [html_table(style=(width="100%",)) do
                vcat(
                    [html_tr([html_th("State",style=(width="40%",)),
                              html_th("County",style=(width="60%",))])],
                    [
                        html_tr() do
                            html_td(style=(width="40%",)) do
                                dcc_dropdown(id="state-$n", options=[])
                            end,
                            html_td(style=(width="60%",)) do
                                dcc_dropdown(id="county-$n", options=[])
                            end
                        end for n in 1:max_lines
                    ]
                )
            end,
            html_b("Options"),
            dcc_radioitems(id="type", options=[(label="Confirmed positive cases", value="cases"), (label="Confirmed deaths", value="deaths")], value="cases"),
            "Align on:",
            dcc_input(id="alignment", type="number", placeholder="alignment",min=1, max=10000, step=1, value=10),
            html_br(),
            "Y-axis transformation:",
            dcc_radioitems(id="ytransform", options=[(label="Logarithmic", value="log"), (label="Linear", value="linear")], value="log"),
            html_div(style = (width="80%", display="block", padding="2% 10%")) do
                dcc_graph(
                    id = "theplot",
                    figure=Plot()
                    )
            end
            ]
        end,
        html_a("Code source (Julia + Plotly Dash + Dashboards.jl)", href="https://github.com/mbauman/covid19",
            style=(
               textAlign = "center",
               display = "block",
            )
        )
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
callback!(plotit, app2, CallbackId([], [(:ytransform, :value); (:type, :value); (:alignment, :value); [(Symbol(t,"-",n), :value) for n in 1:max_lines for t in (:state, :county)]], [(:theplot, :figure)]))
@info "Hollared back at"

handler = make_handler(app2, debug = true)
@info "Setup and now serving..."
HTTP.serve(handler, ip"0.0.0.0", parse(Int, length(ARGS) > 0 ? ARGS[1] : "8080"))
