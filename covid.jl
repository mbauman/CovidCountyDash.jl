import HTTP, CSV
using Plots, DataFrames
df = CSV.read(IOBuffer(String(HTTP.get("https://raw.githubusercontent.com/nytimes/covid-19-data/master/us-counties.csv").body)), normalizenames=true)
# df = CSV.read("covid-19-data/us-counties.csv")

function plotbyloc(df, locs; type=:cases, alignment=10)
    plot(legend=:topleft)
    for loc in locs
        subdf = df[(df.county .== loc[1]) .& (df.state .== loc[2]), :]
        vals = subdf[:, type]
        dates = subdf[:, :date]
        plot!(dates .- dates[findfirst(vals .>= alignment)], vals, label=join(loc, ", "), yaxis=:log)
    end
    xlabel!("Days since reporting $alignment $type")
    xlims!(-1, 25)
    ylims!(alignment*.9, last(ylims()))
    ylabel!("Number of $type")
end

plotbyloc(df, (("New York City", "New York"),("Laramie", "Wyoming"), ("Fremont", "Wyoming")))
plot!([0, maximum(xlims())], [10, 10*1.57^maximum(xlims())], color=:black, style=:dash, label="NYC trend 1 (2x every 1.5 days)")
plot!([17, maximum(xlims())], [16000, 16000*1.17^(maximum(xlims())-17)], color=:green, style=:dash, label="NYC trend 2 (2x every 4.4 days)")

function plotbystate(df, locs; type=:cases, alignment=10)
    plot(legend=:topleft)
    for loc in locs
        subdf = by(df[df.state .== loc, :], :date) do d
           (cases=sum(d.cases), deaths=sum(d.deaths))
        end
        vals = subdf[:, type]
        dates = subdf[:, :date]
        plot!(dates .- dates[findfirst(vals .>= alignment)], vals, label=loc, yaxis=:log)
    end
    xlabel!("Days since reporting $alignment $type")
    xlims!(-1, 30)
    ylims!(alignment*.9, last(ylims()))
    ylabel!("Number of $type")
end
plotbystate(df, ("New York","Tennessee", "Wyoming", "Montana", "Mississippi", "Georgia", "Oklahoma"))
plot!([0, maximum(xlims())], [10, 10*1.333521432163324^maximum(xlims())], color=:black, style=:dash, label="10x every 8 days")



function plotbyregion(df, locs; type=:cases, alignment=10)
    plot(legend=:topleft)
    for loc in locs
        subdf = by(df[(df.county .∈ (loc[1],)) .& (df.state .== loc[2]), :], :date) do d
           (cases=sum(d.cases), deaths=sum(d.deaths))
        end
        vals = subdf[:, type]
        dates = subdf[:, :date]
        plot!(dates .- dates[findfirst(vals .>= alignment)], vals, label=loc[3], yaxis=:log)
    end
    xlabel!("Days since reporting $alignment $type")
    xlims!(-1, 30)
    ylims!(alignment*.9, last(ylims()))
    ylabel!("Number of $type")
end
plotbyregion(df, [(["San Francisco","San Mateo","Santa Clara","Alameda","Contra Costa"],"California", "Bay Area"),(["New York City"], "New York", "NYC")])

#######
using Dashboards, PlotlyJS
import HTTP

states = sort!(unique(df.state))
nothing
app = Dash("🦠 Coronavirus Tracked by County 🗺️") do
    html_div() do
        #Sets and styles heading/title
        html_h1("🦠 Coronavirus Tracked by County 🗺️",
            style=(
               textAlign = "center",
            )
        ),
        #Second graph (CO2 emissions over time), basic line graph
        html_div(style = (width="80%", display="block", padding="2% 10%")) do
            dcc_dropdown(id="state", options=[(label=s, value=s) for s in states]),
            dcc_dropdown(id="county", options=[]),
            dcc_graph(
                id = "theplot",
                figure= Plot(compute(df, nothing, nothing),
                    Layout(
                        xaxis_title = "Days since 10 cases",
                        yaxis_title = "Number of cases",
                        hovermode = "closest",
                        title = "Cases",
                        height = "40%"
                    ),
                    x = :days,
                    y = :cases,
                    mode = "lines+markers",
                    marker_size = 5,
                    marker_line_width = 2,
                    marker_line_color = "orange",
                    marker_color = "orange",
                    marker_opacity = 0.6
                )
            )
        end
    end
end
using Dates
compute(df, state, county; kwargs...) = DataFrame(days=Int[],cases=Int[])
function compute(df, state::String, county::String; alignment = 10, type=:cases)
    subdf = df[(df.county .== county) .& (df.state .== state), :]
    vals = subdf[:, type]
    dates = subdf[:, :date]
    idx = findfirst(vals .>= alignment)
    idx === nothing && return compute(df, nothing, nothing)
    return DataFrame(days=(x->x.value).(dates .- dates[idx]),cases=vals)
end

#Callback for when slider is used, updates the scatterplot based on selected year
callback!(app, callid"state.value => county.options") do state_picked
    state_picked === nothing && return NamedTuple{(:label, :value),Tuple{String,String}}[]
    return [(label=c, value=c) for c in sort!(unique(df[df.state .== state_picked, :].county))]
end
callback!(app, callid"state.value, county.value => theplot.figure") do state, county
    data = compute(df, state, county)
    return Plot(data,
        Layout(
            xaxis_title = "Days since 10 cases",
            yaxis_title = "Number of cases",
            hovermode = "closest",
            title = "Cases",
            height = "40%"
        ),
        x = :days,
        y = :cases,
        mode = "lines+markers",
        marker_size = 5,
        marker_line_width = 2,
        marker_line_color = "orange",
        marker_color = "orange",
        marker_opacity = 0.6
    )
end



handler = make_handler(app, debug = true)
HTTP.serve(handler, HTTP.Sockets.localhost, 8080)


nothing
#=
df = CSV.read(IOBuffer(String(HTTP.get("https://covid.ourworldindata.org/data/total_cases.csv").body)), normalizenames=true)
df = CSV.read(IOBuffer(String(HTTP.get("https://raw.githubusercontent.com/CSSEGISandData/COVID-19/master/csse_covid_19_data/csse_covid_19_time_series/time_series_19-covid-Confirmed.csv").body)))
df = stack(df, Not(1:4), 1:2)
df2 = DataFrame(
    date=Date.(String.(df.variable), DateFormat("m/dd/yy")).+Year(2000),
    value=df.value,
    loc=string.(coalesce.(df[:,Symbol("Province/State")],""),
                ifelse.(ismissing.(df[:,Symbol("Province/State")]), "", "; "),
                df[:,  Symbol("Country/Region")]))
df3 = unstack(df2, :date, :loc, :value)

const states = Dict(
    "AK" => "Alaska",
    "AL" => "Alabama",
    "AZ" => "Arizona",
    "CA" => "California",
    "CO" => "Colorado",
    "CT" => "Connecticut",
    "D.C." => "D.C.",
    "DE" => "Delaware",
    "FL" => "Florida",
    "GA" => "Georgia",
    "HI" => "Hawaii",
    "IA" => "Iowa",
    "ID" => "Idaho",
    "IL" => "Illinois",
    "IN" => "Indiana",
    "KS" => "Kansas",
    "KY" => "Kentucky",
    "LA" => "Louisiana",
    "MA" => "Massachussetts",
    "MD" => "Maryland",
    "MI" => "Michigan",
    "MN" => "Minnesota",
    "MO" => "Missouri",
    "MS" => "Mississippi",
    "NC" => "North Carolina",
    "ND" => "North Dakota",
    "NE" => "Nebraska",
    "NH" => "New Hampshire",
    "NJ" => "New Jersey",
    "NM" => "New Mexico",
    "NV" => "Nevada",
    "NY" => "New York",
    "OH" => "Ohio",
    "OK" => "Oklahoma",
    "OR" => "Oregon",
    "PA" => "Pennsylvania",
    "RI" => "Rhode Island",
    "SC" => "South Carolina",
    "SD" => "South Dakota",
    "TN" => "Tennessee",
    "TX" => "Texas",
    "UT" => "Utah",
    "VA" => "Virginia",
    "VT" => "Vermont",
    "WA" => "Washington",
    "WI" => "Wisconsin",
    "WY" => "Wyoming")
county_to_state(c) = states[strip(last(split(c, ", ")))]

=#
