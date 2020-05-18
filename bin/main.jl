using CovidCountyDash

const df = download_and_preprocess(joinpath(@__DIR__, "..", "data", "pop2019.csv"))
@info "Got the data"

handler = make_handler(create_app(df))
@info "Setup and now serving..."
HTTP.serve(handler, ip"0.0.0.0", parse(Int, length(ARGS) > 0 ? ARGS[1] : "8080"))
