module CovidCountyDash
import HTTP, CSV
using Dash
using DataFrames, Dates, PlotlyBase, Statistics
using DataStructures: OrderedDict
using Base: splat

export download_and_preprocess, create_app, HTTP, DataFrame, run_server

const POP = CSV.read(joinpath(@__DIR__, "..", "data", "pop2019.csv"), DataFrame)
const STATES = OrderedDict(f=>s for (s, f) in eachrow(select(filter(x->ismissing(x.county), POP), :state, :fips)))
const COUNTIES = OrderedDict(sf=>OrderedDict(cf=>c for (c, cf) in eachrow(select(filter(x->sf == x.fips÷1000, POP), :county, :fips))) for sf in keys(STATES))

counties(::Nothing) = []
counties(statefips) = if length(statefips) == 1
    [(label=c, value=fips) for s in statefips for (fips, c) in get(COUNTIES, s, [])]
else
    [(label=string(c, ", ", SHORTSTATE[s]), value=fips) for s in statefips for (fips, c) in get(COUNTIES, s, [])]
end

const SHORTSTATE = Dict(
     1 => "AL",  2 => "AK",  4 => "AZ",  5 => "AR",  6 => "CA",  8 => "CO",  9 => "CT",
    10 => "DE", 11 => "DC", 12 => "FL", 13 => "GA", 15 => "HI", 16 => "ID", 17 => "IL",
    18 => "IN", 19 => "IA", 20 => "KS", 21 => "KY", 22 => "LA", 23 => "ME", 24 => "MD",
    25 => "MA", 26 => "MI", 27 => "MN", 28 => "MS", 29 => "MO", 30 => "MT", 31 => "NE",
    32 => "NV", 33 => "NH", 34 => "NJ", 35 => "NM", 36 => "NY", 37 => "NC", 38 => "ND",
    39 => "OH", 40 => "OK", 41 => "OR", 42 => "PA", 44 => "RI", 45 => "SC", 46 => "SD",
    47 => "TN", 48 => "TX", 49 => "UT", 50 => "VT", 51 => "VA", 53 => "WA", 54 => "WV",
    55 => "WI", 56 => "WY", 60 => "AS", 66 => "GU", 69 => "MP", 72 => "PR", 78 => "VI", )

labelname(::Nothing) = nothing
labelname(fips) = fips < 1000 ? SHORTSTATE[fips] : COUNTIES[fips ÷ 1000][fips]

function label(fips)
    locs = String[]
    samestate = all(>=(1000), fips) && length(unique(fips .÷ 1000)) == 1
    if all(<(1000), fips)
        # only states; look for a subgroup
        if length(fips) >= minimum(length, values(STATE_GROUPS))
            for (name, group) in STATE_GROUPS
                if group ⊆ fips
                    push!(locs, uppercasefirst(name))
                    fips = setdiff(fips, group)
                end
            end
        end
        append!(locs, labelname.(fips))
    elseif all(>=(1000), fips)
        append!(locs, samestate ? labelname.(fips) : labelname.(fips) .* ", " .* labelname.(fips .÷ 1000))
    else
        return "Strange mix of states and counties"
    end
    b = IOBuffer()
    cur_len = write(b, locs[1])
    didbreak = false
    for i in 2:length(locs)
        remaining_len = mapreduce(length, +, locs[i+1:end], init=0) + (length(locs)-i+1)*3
        cutoff_txt = " + $(length(locs)-i+1) others"
        if cur_len + length(cutoff_txt) > 40 && cur_len + remaining_len > cur_len + length(cutoff_txt)
            print(b, cutoff_txt)
            didbreak = true
            break
        end
        cur_len += write(b, " + ", locs[i])
    end
    samestate && print(b, didbreak ? " in " : ", ", labelname(first(fips) ÷ 1000))
    return String(take!(b))
end

const STATE_GROUPS = OrderedDict{String, Vector{Int}}(
    "all" => sort!(collect(keys(STATES))),
    "lower49" => sort!(collect(filter(<(60), setdiff(keys(STATES), (2, 15))))),
    "northeast" => [9, 23, 25, 33, 34, 36, 42, 44, 50],
    "midwest" => [17, 18, 19, 20, 26, 27, 29, 31, 38, 39, 46, 55],
    "south" => [1, 5, 10, 11, 12, 13, 21, 22, 24, 28, 37, 40, 45, 47, 48, 51, 54],
    "west" => [4, 6, 8, 16, 30, 32, 35, 41, 49, 53, 56],
    )

const YEARS = ["2020", "2021", "2022", "2023"]
const URIBASE = "https://raw.githubusercontent.com/nytimes/covid-19-data/master"
function download_and_preprocess()
    states = CSV.read(IOBuffer(String(HTTP.get(URIBASE * "/us-states.csv").body)), DataFrame, normalizenames=true)
    states[!, :county] .= missing
    county_yrs = [CSV.read(IOBuffer(String(HTTP.get(URIBASE * "/us-counties-" * year * ".csv").body)), DataFrame, normalizenames=true)
                    for year in YEARS]
    d = transform!(vcat(states, county_yrs...),
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
function subset(df, fips)
    subset = combine(groupby(filter(:fips=>∈(fips), df; view=true), :date, sort=true), :cases=>sum, :deaths=>sum, renamecols=false)
    return subset, sum(filter(:fips=>∈(fips), POP; view=true).pop)
end
const EMPTY = DataFrame(values=Float32[], popvalues=Float32[], dates=Date[],location=String[])
function precompute(df, states, counties; type=:cases, roll=1, value="values")
    !isset(states) && return EMPTY
    fips = BitSet(isset(counties) ? counties : states)
    subdf, pop = subset(df, fips)
    isempty(subdf) && return EMPTY
    vals = subdf[!, type]
    values = Float32.(coalesce.(value == "diff" ? [NaN32; rolling(mean, diff(vals), roll)] : vals, NaN32))
    popvalues = values .* Float32(100 / coalesce(pop, NaN32))
    loc = label(fips)
    return DataFrame(values=replace(values, NaN=>nothing), popvalues=replace(popvalues, NaN=>nothing), dates=subdf.date, location=loc)
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
        showlegend = true,
        yaxis_type= logy ? "log" : "linear",
        yaxis_automargin = true,
    )
    isempty(data) && return Plot(collect(extrema(df.date)), [nothing, nothing], layout, mode="lines", name="", showlegend=false)
    y, customdata = popnorm ? (:popvalues, :values) : (:values, :popvalues)
    valtrace, poptrace = popnorm ? (:customdata, :y) : (:y, :customdata)
    perday = roll > 1 && value == "diff" ? "/day" : ""
    return Plot(data, layout,
        x = :dates,
        y = y,
        customdata = customdata,
        group = :location,
        hovertemplate = "%{x|%b %d}: %{$valtrace:,$(roll == 1 || value == "values" ? "d" : ".1f")} $type$perday (%{$poptrace:.2g}%)",
        mode = "lines",
    )
end
function create_app(df;max_lines=6)
    app = dash(external_stylesheets=["https://stackpath.bootstrapcdn.com/bootstrap/4.4.1/css/bootstrap.min.css"])
    app.title = "🦠 COVID-19 Tracked by US County"
    app.layout =
        html_div(style=(padding="2% 5% 0% 5%",), [
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
            html_div(style = (display="block", margin="0 5% 0 5%"), [
                dcc_graph(id = "theplot", figure=plotit(df, "values", "cases", 7, ["popnorm"], [], [])),
                ]),
            html_div(className="row", [
                html_div(className="col-9",
                    html_table(style=(width="100%",),
                        vcat(html_tr([html_th("State",style=(width="40%",)),
                                      html_th("County",style=(width="60%",))]),
                             [html_tr([
                                 html_td(dcc_dropdown(id="state-$n", options=
                                     [(label=s, value=f) for (f, s) in STATES], multi=true,
                                     placeholder="Select or right click..."), style=(width="40%",)),
                                 html_td(dcc_dropdown(id="county-$n", options=[], multi=true,
                                     placeholder="Select or right click..."), style=(width="60%",))
                                 ], id="scrow-$n") for n in 1:max_lines])
                    )
                ),
                html_div(className="col-3", contextMenu="menu", [
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
            html_div(style = (display="block", margin="0 5% 0 5%"), [
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
                style=(textAlign = "center", display = "block")),
            html_div([
                [html_div(id="menu-state-$n", className="menu", style=(display="none", zIndex=100, position="absolute", border="1px solid", boxShadow="4px 3px 8px 1px #969696"), [
                    html_button("All States & Territories", style=(width="100%",), id="all-$n"), html_br(),
                    html_button("Contiguous 48 States + DC", style=(width="100%",), id="lower49-$n"),
                    html_button("Northeast", style=(width="100%",), id="northeast-$n"),
                    html_button("Midwest", style=(width="100%",), id="midwest-$n"),
                    html_button("South", style=(width="100%",), id="south-$n"),
                    html_button("West", style=(width="100%",), id="west-$n"),
                ]) for n in 1:max_lines];
                [html_div(id="menu-county-$n", className="menu", style=(display="none", zIndex=100, position="absolute", border="1px solid", boxShadow="4px 3px 8px 1px #969696", backgroundColor="#e0e0e0"), [
                    html_p("Population percentile:", style=(width="100%",padding="0 8em 0 8em")), html_br(),
                    dcc_rangeslider(id="popslider-$n", className="popslider", min=0, max=100, step=.5, value=[90,100], marks=Dict((0:10:100) .=> string.(0:10:100, "%"))),
                    html_button("Apply", id="apply-pop-$n", style=(width="100%",))
                ]) for n in 1:max_lines]]),
            dcc_interval(id="jsloader", interval=1),
        ])

    callback!("""
        function (n) {
            if (typeof n === 'undefined' || typeof document.getElementById('state-1') == 'undefined') { return false; };
            $(["document.getElementById('state-$n').addEventListener('contextmenu',function(event){
                event.preventDefault();
                var menu = document.getElementById('menu-state-$n');
                menu.style.display = 'block';
                menu.style.left = (event.pageX - 10)+'px';
                menu.style.top = (event.pageY - 10)+'px';
                return false;
            },false);" for n in 1:max_lines]...)
            $(["document.getElementById('county-$n').addEventListener('contextmenu',function(event){
                event.preventDefault();
                var menu = document.getElementById('menu-county-$n');
                menu.style.display = 'block';
                menu.style.left = (event.pageX - 10)+'px';
                menu.style.top = (event.pageY - 10)+'px';
                return false;
            },false);" for n in 1:max_lines]...)
            document.addEventListener("click",function(event){
                var menus = document.getElementsByClassName("menu");
                for (let i = 0; i < menus.length; i++) {
                    if (menus[i].contains(event.target) && !event.target.matches("button")) { return false; }
                    menus[i].style.display = "none";
                    menus[i].style.left = "";
                    menus[i].style.top = "";
                }
                return false;
            },false);
            return true;
        }""", app, Output("jsloader", "disabled"), Input("jsloader", "n_intervals"))
    for n in 1:max_lines
        callback!(app, Output("state-$n", "value"), Input.(["all-$n", "lower49-$n", "northeast-$n", "midwest-$n", "south-$n", "west-$n"], "n_clicks")) do buttons...
            all(isnothing, buttons) && return []
            changed_id = get([p.prop_id for p in callback_context().triggered], 1, "")
            return get(STATE_GROUPS, split(changed_id, '-')[1], Dash.NoUpdate())
        end
    end
    for n in 1:max_lines
        callback!(app, Output("county-$n", "value"), [Input("popslider-$n", "value"), Input("apply-pop-$n", "n_clicks"), Input("county-$n", "options")]) do slider, click, opts
            (isnothing(click) || isempty(opts)) && return []
            changed_id = get([p.prop_id for p in callback_context().triggered], 1, "")
            if startswith(changed_id, "apply")
                pops = filter(:fips=>∈(BitSet(getproperty.(opts, :value))), POP)
                lower, upper = quantile(skipmissing(pops.pop), sort(slider)./100)
                return pops.fips[coalesce.(lower .<= pops.pop .<= upper, false)]
            else
                return Dash.NoUpdate()
            end
        end
    end
    hide_missing_row(s, c) = !isset(s) && !isset(c) ? (display="none",) : (display="table-row",)
    for n in 2:max_lines
        callback!(hide_missing_row, app, Output("scrow-$n", "style"), [Input("state-$n", "value"), Input("state-$(n-1)", "value")])
    end
    for n in 1:max_lines
        callback!(counties, app, Output("county-$n", "options"), Input("state-$n", "value"))
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
