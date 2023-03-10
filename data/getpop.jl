import HTTP, CSV, XLSX, Unicode
using DataFrames, StringEncodings
# US States
r = HTTP.get("https://www2.census.gov/programs-surveys/popest/datasets/2020-2021/counties/totals/co-est2021-alldata.csv")
countydata = CSV.read(IOBuffer(decode(r.body, enc"Latin1")), DataFrame; types=Dict(:POPESTIMATE2020=>Union{Int, Missing},))
pop = select(countydata,
    [:STATE, :COUNTY] => ByRow((s, c)->s*(c > 0 ? 1000 : 1) + c) => :fips,
    :POPESTIMATE2020 => :pop,
    :STNAME => :state,
    [:CTYNAME, :COUNTY] => ByRow() do county, fips
        fips == 0 ? missing : replace(county, r"( County| Parish)$"=>"")
    end => :county)

# # New York City
# All cases for the five boroughs of New York City (New York, Kings, Queens, Bronx and Richmond counties) are assigned to a single area called New York City.
boroughs = findall(pop.fips .∈ ((36061,    # New York
                                 36047,    # Kings
                                 36081,    # Queens
                                 36005,    # Bronx
                                 36085),)) # Richmond
push!(pop, (fips=36998, pop=sum(pop[boroughs, :pop]), state="New York", county="New York City¹"))
delete!(pop, boroughs)

# # Kansas City, Mo
# Four counties (Cass, Clay, Jackson and Platte) overlap the municipality of Kansas City, Mo. The cases and deaths that we show for these four counties are only for the portions exclusive of Kansas City. Cases and deaths for Kansas City are reported as their own line.
# Note that the KCMO numbers from the US Census (508090, https://www.census.gov/quickfacts/fact/table/kansascitycitymissouri/PST045218)
# differ from MARC (497159, https://web.archive.org/web/20211229011722/https://www.marc.org/Data-Economy/Metrodataline/assets/Population_Estimates_as_of_July_1.aspx)
# We'll use MARC's numbers since those have the county breakdowns (but they're off by about 2%)
push!(pop, (fips=29998, pop=497159, state= "Missouri", county="Kansas City²"))
# subtract out 2020 estimates of KCMO from counties:
pop[pop.fips .== 29037, :pop] .-= 200    # Cass
pop[pop.fips .== 29047, :pop] .-= 129900 # Clay
pop[pop.fips .== 29095, :pop] .-= 316610 # Jackson
pop[pop.fips .== 29165, :pop] .-= 50449  # Platte
pop[pop.fips .∈ ((29037, 29047, 29095, 29165),), :county] .*= '³'

# # Joplin, MO
# "Starting June 25, cases and deaths for Joplin are reported separately from Jasper and Newton counties. The cases and deaths reported for those counties are only for the portions exclusive of Joplin. Joplin cases and deaths previously appeared in the counts for those counties or as Unknown."
# 2020 Census: https://www.census.gov/quickfacts/fact/table/joplincitymissouri,US/PST045219
push!(pop, (fips=29997, pop=51762, state= "Missouri", county="Joplin⁴"))
# Very little of Joplin is in Newton; cannot find exact figures. Guess a 95/5 split?
pop[pop.fips .== 29097, :pop] .-= 51762 * 95 ÷ 100 # Jasper
pop[pop.fips .== 29145, :pop] .-= 51762 *  5 ÷ 100 # Newton
pop[pop.fips .∈ ((29097, 29145),), :county] .*= '⁵'

# # Alaska's data combine three pairs of county-equivalents:
# Bristol Bay Borough (2060) and Lake and Peninsula Borough (2164), with a phony fips
push!(pop, (fips=2997, pop=sum(pop[pop.fips .∈ [[2060, 2164]], :pop]),
    state= "Alaska", county="Bristol Bay plus Lake and Peninsula"))
# Yakutat City and Borough (2282) and Hoonah-Angoon Census Area (2105), with a phony fips
push!(pop, (fips=2998, pop=sum(pop[pop.fips .∈ [[2282, 2105]], :pop]),
    state= "Alaska", county="Yakutat plus Hoonah-Angoon"))
# Chugach (2063) and Copper River Census Areas (2066), using thier former combined name and fips
push!(pop, (fips=2261, pop=sum(pop[pop.fips .∈ [[2063, 2066]]], :pop]),
    state= "Alaska", county="Valdez-Cordova Census Area"))
delete!(pop, findall(pop.fips .∈ [[2060, 2164, 2282, 2105, 2063, 2066]]))

# Puerto Rico
prxlsx = download("https://www2.census.gov/programs-surveys/popest/tables/2020-2021/municipios/totals/prm-est2021-pop.xlsx")
prdata = DataFrame(XLSX.gettable(XLSX.readxlsx(prxlsx)[1], "A:D", first_row=4, infer_eltypes=true))
idxs = findall(endswith("Puerto Rico"), prdata[:, 1])
prdata = prdata[idxs, [1, 3]]
transform!(prdata, :missing=>(x->replace.(x, r"(^\.| Municipio, Puerto Rico$)"=>""))=>:county)
prfips = CSV.read("prfips.csv", DataFrame)
prpops = leftjoin(prdata, prfips, on=:county)
@assert !any(ismissing.(prpops.fips))
append!(pop, select(prpops,
    :fips,
    "2020" => :pop,
    []=>(()->"Puerto Rico")=>:state,
    :county=>ByRow(x->x=="Puerto Rico" ? missing : x)=>:county))

# US Virgin Islands has a wonky "CSV file" that's really just a crappy XLSX so I won't attempt to parse, but it has data for 2020:
# https://www2.census.gov/programs-surveys/decennial/2020/data/island-areas/us-virgin-islands/population-and-housing-unit-counts/us-virgin-islands-phc-table01.csv
# Easier to just read the PDF here: https://www.census.gov/data/tables/2020/dec/2020-us-virgin-islands.html
append!(pop, DataFrame(
    [78    "Virgin Islands" missing       87146
     78010 "Virgin Islands" "St. Croix"   41004
     78020 "Virgin Islands" "St. John"     3881
     78030 "Virgin Islands" "St. Thomas"  42261],
    [:fips, :state,         :county,       :pop]))

# Guam is similar to VI and from https://www.census.gov/data/tables/2020/dec/2020-guam.html
push!(pop, (fips=66, pop=153836, state="Guam", county=missing))

# American Samoa is https://www.census.gov/data/tables/2020/dec/2020-american-samoa.html
push!(pop, (fips=60, pop=49710, state="American Samoa", county=missing))

# Northern Mariana Islands is https://www.census.gov/data/tables/2020/dec/2020-commonwealth-northern-mariana-islands.html
append!(pop, DataFrame(
    [69    "Northern Mariana Islands" missing  47329
     69100 "Northern Mariana Islands" "Rota"    1893
     69110 "Northern Mariana Islands" "Saipan" 43385
     69120 "Northern Mariana Islands" "Tinian"  2044],
    [:fips, :state,                   :county,  :pop]))

# Add "Unknowns" with a fake fips to the popfile
for row in eachrow(filter(x->ismissing(x.county), pop))
    push!(pop, (fips=row.fips*1000+999, pop=missing, state=row.state, county="Unknown"))
end

CSV.write("pop2020.csv", sort(pop))
