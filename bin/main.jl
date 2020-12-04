using CovidCountyDash

@info "fetching the data"
df = download_and_preprocess()
@info "Got the data"

app = create_app(df)
@info "Setup and now serving..."
# Heroku passes the port as the first argument; JuliaHub as a PORT ENV var
port = something(tryparse(Int, get(ARGS, 1, "")), tryparse(Int, get(ENV, "PORT", "")), 8080)
run_server(app, "0.0.0.0", port)
