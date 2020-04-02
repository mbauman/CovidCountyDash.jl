import HTTP, CSV
using Plots, DataFrames
df = CSV.read(IOBuffer(String(HTTP.get("https://raw.githubusercontent.com/nytimes/covid-19-data/master/us-counties.csv").body)), normalizenames=true)

"""
    plotbyloc(df, locs)

Given an array of (County, State) tuples, plot the history for each

Example:

    plotbyloc(df, (("New York City", "New York"),("Cook", "Illinois"), ("Fremont", "Wyoming")))
"""
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

"""
    plotbystate(df, locs)

Given an array of states, plot the combined history (over all counties) for each

Example:

    plotbystate(df, ("New York","Tennessee", "Wyoming", "Montana", "Mississippi", "Georgia", "Oklahoma"))
"""
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

"""
    plotbyregion(df, locs)

Given an array of (Counties, State, name) tuples, sum the array of counties

Example:

    plotbyregion(df, [(["San Francisco","San Mateo","Santa Clara","Alameda","Contra Costa"],"California", "Bay Area"),(["New York City"], "New York", "NYC")])
"""
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
