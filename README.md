# CovidCountyDash

Visualization of [data] from [The New York Times], based on reports from state and local
health agencies; inspired by [John Burn-Murdoch]'s [FT analyses] of national-level data.

This has become significantly more complicated with successive iterations; see an earlier
version in the history (like [2633d5b]) for a simpler example.

## Data

Note the geographical [caveats in the NYT dataset]; the most annoying of which are the fact
that the 5 NYC boroughs are all lumped together and Kansas City, MO reports its numbers
separately of the 4 counties it touches.  Further, note that US territories and the District
of Columbia are listed as "states."

This dataset is joined with the US Census [population estimates for 2019] to facilitate
rates per population, but special care is needed for those caveats. In particular, the city
of KCMO is split between portions of 4 different counties (Cass, Clay, Jackson and Platte)
and does not wholly encompass any one of them. Since KCMO is reported separately, we pull
its population estimate from the [census' 2018 estimate](https://www.census.gov/quickfacts/fact/table/kansascitycitymissouri/PST045218)
(2019 is not yet available), and then remove population as appropriate from each of those
four counties (using the 2018 breakdown [available at MARC]).

Population estimates are not applied to US territories (so population normalization is not
available for them), and some states report cases from "Unknown" counties (with 0 population).

## Deployment

This is setup to be hosted on free-tier Heroku dyno. In the free tier, the app gets killed
after 30 minutes of inactivity and we're given terribly anemic access to the CPU. To reduce
startup costs, a special [heroku buildpack] that uses [PackageCompiler.jl] is under development.

[data]: https://github.com/nytimes/covid-19-data
[The New York Times]: https://www.nytimes.com/interactive/2020/us/coronavirus-us-cases.html
[John Burn-Murdoch]: https://twitter.com/jburnmurdoch
[FT analyses]: https://www.ft.com/coronavirus-latest
[2633d5b]: https://github.com/mbauman/CovidCountyDash.jl/blob/2633d5b665b3e053b8a01411b6adb270ef2fe60f/dashboard.jl
[caveats in the NYT dataset]: https://github.com/nytimes/covid-19-data#geographic-exceptions
[population estimates for 2019]: https://www2.census.gov/programs-surveys/popest/datasets
[available at MARC]: https://www.marc.org/Data-Economy/Metrodataline/Population/Current-Population-Data
[heroku buildpack]: https://github.com/mbauman/heroku-buildpack-julia
[PackageCompiler.jl]: https://github.com/JuliaLang/PackageCompiler.jl