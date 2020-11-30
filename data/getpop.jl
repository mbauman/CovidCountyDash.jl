import HTTP, CSV, XLSX, Unicode
using DataFrames
# US States
alldata = CSV.read(IOBuffer(String(HTTP.get("https://www2.census.gov/programs-surveys/popest/datasets/2010-2019/counties/totals/co-est2019-alldata.csv").body)), DataFrame)
countydata = alldata[alldata.COUNTY .!= 0, [:STATE, :COUNTY, :STNAME, :CTYNAME, :POPESTIMATE2019]]

# Puerto Rico
prxlsx = download("https://www2.census.gov/programs-surveys/popest/tables/2010-2019/municipios/totals/prm-est2019-annres.xlsx")
prdata = DataFrame(XLSX.gettable(XLSX.readxlsx(prxlsx)[1], "A:M", first_row=4, infer_eltypes=true)...)
idxs = findall(startswith("."), prdata[:, 1])
prdata = prdata[idxs, [1, end]]
transform!(prdata, :missing=>(x->replace.(x, r"(^.| Municipio, Puerto Rico$)"=>""))=>:county)
prfips = CSV.read("prfips.csv", DataFrame)
prpops = leftjoin(prdata, prfips, on=:county)
@assert !any(ismissing.(prpops.fips))

# US Virgin Islands don't seem to have 2019 estimates available...
# and they're estimated to have changed significantly. Would be nice to do better... https://stjohnsource.com/2019/11/28/usvi-population-likely-lower-as-2020-census-ramps-up/
others = DataFrame(
    [78010  50601   # St. Croix
     78020   4170   # St. John
     78030  51634], # St. Thomas
    [:fips, :pop])

# Guam is a July 2020 estimate from the CIA: https://www.cia.gov/library/publications/the-world-factbook/geos/gq.html
push!(others, [66000 168485]) # No county data

# Northern Mariana Islands have 2017 estimates for Saipan, 2010 for Tinian
push!(others, [69110 52263]) # Saipan
push!(others, [69120 3136])  # Tinian

CSV.write("pop2019.csv", sort(vcat(
    DataFrame(fips = countydata.STATE.*1000 .+ countydata.COUNTY, pop = countydata.POPESTIMATE2019),
    DataFrame(fips = prpops.fips, pop=prpops."2019"),
    others
    )))
