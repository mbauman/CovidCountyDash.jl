import HTTP, CSV
alldata = CSV.read(IOBuffer(String(HTTP.get("https://www2.census.gov/programs-surveys/popest/datasets/2010-2019/counties/totals/co-est2019-alldata.csv").body)))

countydata = alldata[alldata.COUNTY .!= 0, [:STATE, :COUNTY, :STNAME, :CTYNAME, :POPESTIMATE2019]]
CSV.write("pop2019.csv", DataFrame(fips = countydata.STATE.*1000 .+ countydata.COUNTY, pop = countydata.POPESTIMATE2019))
