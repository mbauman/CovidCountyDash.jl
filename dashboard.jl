import HTTP, CSV
using Plots, DataFrames, Dates, PlotlyJS, Dashboards
df = CSV.read(IOBuffer(String(HTTP.get("https://raw.githubusercontent.com/nytimes/covid-19-data/master/us-counties.csv").body)), normalizenames=true)

states = sort!(unique(df.state))
max_lines = 4

# utilities to compute the cases by day, subseted and aligned
precompute(df, state, county; kwargs...) = DataFrame(days=Int[0],cases=Int[1],location=String[""])
function precompute(df, state::String, county::String; alignment = 10, type=:cases)
    subdf = df[(df.county .== county) .& (df.state .== state), :]
    vals = subdf[:, type]
    dates = subdf[:, :date]
    idx = findfirst(vals .>= alignment)
    idx === nothing && return precompute(df, nothing, nothing)
    return DataFrame(days=(x->x.value).(dates .- dates[idx]),cases=vals, location="$county, $state")
end
# Given a state, list its counties
counties(state) = NamedTuple{(:label, :value),Tuple{String,String}}[]
counties(state::String) = [(label=c, value=c) for c in sort!(unique(df[df.state .== state, :].county))]
# put together the plot given a sequence of alternating state/county pairs
function plotit(pp...)
    data = reduce(vcat, [precompute(df, state, county) for (state, county) in Iterators.partition(pp, 2)])
    return PlotlyJS.Plot(PlotlyJS.scatter(data,
            x = :days,
            y = :cases,
            group = :location,
            mode = "lines+markers",
            marker_size = 5,
            marker_line_width = 2,
            marker_opacity = 0.6
        ), Layout(
            xaxis_title = "Days since 10 cases",
            yaxis_title = "Number of cases",
            hovermode = "closest",
            title = "Cases",
            height = "40%",
            yaxis_type="log"
        )
    )
end

# The app itself:
app2 = Dash("🦠 COVID-19 Tracked by County 🗺️") do
    html_div() do
        #Sets and styles heading/title
        html_h1("🦠 COVID-19 Tracked by County 🗺️",
            style=(
               textAlign = "center",
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
                                dcc_dropdown(id="state-$n", options=[(label=s, value=s) for s in states])
                            end,
                            html_td(style=(width="60%",)) do
                                dcc_dropdown(id="county-$n", options=[])
                            end
                        end for n in 1:max_lines
                    ]
                )
            end,
            html_div(style = (width="80%", display="block", padding="2% 10%")) do
                dcc_graph(
                    id = "theplot",
                    figure=plotit(nothing, nothing)
                    )
            end
            ]
        end
    end
end


for n in 1:max_lines
    callback!(counties, app2, CallbackId([], [(Symbol(:state,"-",n), :value)], [(Symbol(:county,"-",n), :options)]))
end
callback!(plotit, app2, CallbackId([], [(Symbol(t,"-",n), :value) for n in 1:max_lines for t in (:state, :county)], [(:theplot, :figure)]))


handler = make_handler(app2, debug = true)
HTTP.serve(handler, HTTP.Sockets.localhost, parse(Int, length(ARGS) > 0 ? ARGS[1] : "8080"))
