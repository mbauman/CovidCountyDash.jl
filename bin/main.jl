using CovidCountyDash

const df = Ref(DataFrame(state=[], county=[], cases=[], deaths=[], pop=[]))
@async df[] = (d = download_and_preprocess(); @info "got the data"; d)

handler = make_handler(create_app(df), debug = true)
@info "Setup and now serving..."
HTTP.serve(handler, ip"0.0.0.0", parse(Int, length(ARGS) > 0 ? ARGS[1] : "8080"))
