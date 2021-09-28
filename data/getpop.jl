import HTTP, CSV, XLSX, Unicode
using DataFrames, StringEncodings
# US States
r = HTTP.get("https://www2.census.gov/programs-surveys/popest/datasets/2010-2019/counties/totals/co-est2019-alldata.csv")
countydata = CSV.read(IOBuffer(decode(r.body, enc"Latin1")), DataFrame; types=Dict(:POPESTIMATE2019=>Union{Int, Missing},))
pop = select(countydata,
    [:STATE, :COUNTY] => ByRow((s, c)->s*(c > 0 ? 1000 : 1) + c) => :fips,
    :POPESTIMATE2019 => :pop,
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
# 2019 estimated pop for KCMO: https://www.census.gov/quickfacts/fact/table/kansascitycitymissouri/PST045218
push!(pop, (fips=29998, pop=495327, state= "Missouri", county="Kansas City²"))
# subtract out 2019 estimates of KCMO from counties: https://www.marc.org/Data-Economy/Metrodataline/Population/Current-Population-Data
pop[pop.fips .== 29037, :pop] .-= 200    # Cass
pop[pop.fips .== 29047, :pop] .-= 128232 # Clay
pop[pop.fips .== 29095, :pop] .-= 316836 # Jackson
pop[pop.fips .== 29165, :pop] .-= 50059  # Platte
pop[pop.fips .∈ ((29037, 29047, 29095, 29165),), :county] .*= '³'

# # Joplin, MO
# "Starting June 25, cases and deaths for Joplin are reported separately from Jasper and Newton counties. The cases and deaths reported for those counties are only for the portions exclusive of Joplin. Joplin cases and deaths previously appeared in the counts for those counties or as Unknown."
# 2019 estimate: https://www.census.gov/quickfacts/fact/table/joplincitymissouri,US/PST045219
push!(pop, (fips=29997, pop=50925, state= "Missouri", county="Joplin⁴"))
# Very little of Joplin is in Newton; cannot find exact figures. Guess a 95/5 split?
pop[pop.fips .== 29097, :pop] .-= 50798 * 95 ÷ 100 # Jasper
pop[pop.fips .== 29145, :pop] .-= 50798 *  5 ÷ 100 # Newton
pop[pop.fips .∈ ((29097, 29145),), :county] .*= '⁵'

# Puerto Rico
prxlsx = download("https://www2.census.gov/programs-surveys/popest/tables/2010-2019/municipios/totals/prm-est2019-annres.xlsx")
prdata = DataFrame(XLSX.gettable(XLSX.readxlsx(prxlsx)[1], "A:M", first_row=4, infer_eltypes=true)...)
idxs = findall(endswith("Puerto Rico"), prdata[:, 1])
prdata = prdata[idxs, [1, end]]
transform!(prdata, :missing=>(x->replace.(x, r"(^\.| Municipio, Puerto Rico$)"=>""))=>:county)
prfips = CSV.read("prfips.csv", DataFrame)
prpops = leftjoin(prdata, prfips, on=:county)
@assert !any(ismissing.(prpops.fips))
append!(pop, select(prpops,
    :fips,
    "2019" => :pop,
    []=>(()->"Puerto Rico")=>:state,
    :county=>ByRow(x->x=="Puerto Rico" ? missing : x)=>:county))

# US Virgin Islands don't seem to have 2019 estimates available...
# and they're estimated to have changed significantly. Would be nice to do better... https://stjohnsource.com/2019/11/28/usvi-population-likely-lower-as-2020-census-ramps-up/
# https://www.census.gov/data/tables/time-series/dec/cph-series/cph-t/cph-t-8.html
append!(pop, DataFrame(
    [78    "Virgin Islands" missing      106405
     78010 "Virgin Islands" "St. Croix"   50601
     78020 "Virgin Islands" "St. John"     4170
     78030 "Virgin Islands" "St. Thomas"  51634],
    [:fips, :state,         :county,       :pop]))

# Guam is a July 2020 estimate from the CIA: https://www.cia.gov/library/publications/the-world-factbook/geos/gq.html
push!(pop, (fips=66, pop=168485, state="Guam", county=missing))

# American Samoa is a July 2021 estimate from the CIA: https://www.cia.gov/the-world-factbook/countries/american-samoa/
push!(pop, (fips=60, pop=46366, state="American Samoa", county=missing))

# Northern Mariana Islands have 2017 estimates via this crazy HTML/js table
# https://commerce.gov.mp/lfp-2017-population-characteristics-introduction/
append!(pop, DataFrame(
    [69    "Northern Mariana Islands" missing  52263
     69100 "Northern Mariana Islands" "Rota"    2072
     69110 "Northern Mariana Islands" "Saipan" 47565
     69120 "Northern Mariana Islands" "Tinian"  2626],
    [:fips, :state,                   :county,  :pop]))

# Add "Unknowns" with a fake fips to the popfile
for row in eachrow(filter(x->ismissing(x.county), pop))
    push!(pop, (fips=row.fips*1000+999, pop=missing, state=row.state, county="Unknown"))
end

CSV.write("pop2019.csv", sort(pop))
