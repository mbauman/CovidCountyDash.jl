# CovidCountyDash

Visualization of [data] from [The New York Times], based on reports from state and local
health agencies; inspired by [John Burn-Murdoch]'s [FT analyses] of national-level data.

This has become significantly more complicated with successive iterations; see an earlier
version in the history (like [2633d5b]) for a simpler example.

## Data

Note the geographical [caveats in the NYT dataset]; the most annoying of which are the fact
that the 5 NYC boroughs are all lumped together and Joplin and Kansas City, MO report thier numbers
separately of counties they span.  Further, note that US territories and the District
of Columbia are listed as "states."

This dataset is joined with the [2020 US Census numbers] as mucch as possible to facilitate
rates per population, but special care is needed for some caveats. In particular, the city
of KCMO is split between portions of 4 different counties (Cass, Clay, Jackson and Platte)
and does not wholly encompass any one of them. Since KCMO is reported separately, we pull
its population estimate from [its metro region association's estimates](https://web.archive.org/web/20211229011722/https://www.marc.org/Data-Economy/Metrodataline/Population/Current-Population-Data), and then remove population as appropriate from each of those four counties.

Some states report cases from "Unknown" counties (with 0 population).

## Deployment

This was setup to be hosted on free-tier Heroku dyno. In the free tier, the app gets killed
after 30 minutes of inactivity and we're given terribly anemic access to the CPU. To reduce
startup costs, a special [heroku buildpack] that uses [PackageCompiler.jl] is under development.

[![Deploy](https://www.herokucdn.com/deploy/button.svg)](https://heroku.com/deploy)

[data]: https://github.com/nytimes/covid-19-data
[The New York Times]: https://www.nytimes.com/interactive/2020/us/coronavirus-us-cases.html
[John Burn-Murdoch]: https://twitter.com/jburnmurdoch
[FT analyses]: https://www.ft.com/coronavirus-latest
[2633d5b]: https://github.com/mbauman/CovidCountyDash.jl/blob/2633d5b665b3e053b8a01411b6adb270ef2fe60f/dashboard.jl
[caveats in the NYT dataset]: https://github.com/nytimes/covid-19-data#geographic-exceptions
[2020 US Census numbers]: https://www.census.gov/programs-surveys/decennial-census/decade/2020/2020-census-main.html
[heroku buildpack]: https://github.com/mbauman/heroku-buildpack-julia
[PackageCompiler.jl]: https://github.com/JuliaLang/PackageCompiler.jl