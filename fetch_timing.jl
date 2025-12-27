#!/usr/bin/env julia
# Fetch Julia CI timing data from Buildkite API

using HTTP
using JSON3
using Dates
using Statistics

const BUILDKITE_ORG = "julialang"
const PIPELINE = "julia-master"
const API_BASE = "https://api.buildkite.com/v2"

function get_token()
    token = get(ENV, "BUILDKITE_API_TOKEN", nothing)
    if token === nothing
        token_file = joinpath(homedir(), ".buildkite_token")
        if isfile(token_file)
            token = strip(read(token_file, String))
        end
    end
    token === nothing && error("Set BUILDKITE_API_TOKEN env var or create ~/.buildkite_token")
    return token
end

function api_get(endpoint; token=get_token(), params=Dict())
    url = "$API_BASE/$endpoint"
    if !isempty(params)
        query = join(["$k=$v" for (k, v) in params], "&")
        url = "$url?$query"
    end
    headers = ["Authorization" => "Bearer $token"]
    resp = HTTP.get(url, headers; status_exception=false)
    if resp.status != 200
        @warn "API request failed" url resp.status String(resp.body)
        return nothing
    end
    return JSON3.read(resp.body)
end

function fetch_builds(; branch="master", state="passed", per_page=100, pages=3)
    builds = []
    for page in 1:pages
        params = Dict(
            "branch" => branch,
            "state" => state,
            "per_page" => per_page,
            "page" => page
        )
        data = api_get("organizations/$BUILDKITE_ORG/pipelines/$PIPELINE/builds"; params)
        data === nothing && break
        isempty(data) && break
        append!(builds, data)
        @info "Fetched page $page (julia-master)" num_builds=length(data)
    end
    return builds
end

const SCHEDULED_PIPELINE = "julia-master-scheduled"

function fetch_scheduled_builds(; branch="master", state="passed", per_page=100, pages=30)
    builds = []
    for page in 1:pages
        params = Dict(
            "branch" => branch,
            "state" => state,
            "per_page" => per_page,
            "page" => page
        )
        data = api_get("organizations/$BUILDKITE_ORG/pipelines/$SCHEDULED_PIPELINE/builds"; params)
        data === nothing && break
        isempty(data) && break
        append!(builds, data)
        @info "Fetched page $page (julia-master-scheduled)" num_builds=length(data)
    end
    return builds
end

function parse_datetime(s::AbstractString)
    # Buildkite returns ISO 8601 timestamps
    return DateTime(s[1:19], dateformat"yyyy-mm-ddTHH:MM:SS")
end
parse_datetime(::Nothing) = nothing

function job_duration_seconds(job)
    started = get(job, :started_at, nothing)
    finished = get(job, :finished_at, nothing)
    (started === nothing || finished === nothing) && return nothing
    start_dt = parse_datetime(started)
    end_dt = parse_datetime(finished)
    return Dates.value(end_dt - start_dt) / 1000  # milliseconds to seconds
end

function extract_job_timings(builds)
    # Group job durations by job name
    job_timings = Dict{String, Vector{@NamedTuple{
        commit::String,
        build_number::Int,
        created_at::DateTime,
        duration_seconds::Float64,
        message::String,
        author::String
    }}}()

    cutoff_date = DateTime(2025, 11, 1)

    for build in builds
        build_num = build.number
        commit = String(build.commit)[1:min(8, length(build.commit))]
        created = parse_datetime(build.created_at)

        # Skip builds before cutoff date
        created < cutoff_date && continue

        # Extract commit message (first line only)
        raw_message = get(build, :message, "")
        message = isnothing(raw_message) ? "" : split(String(raw_message), '\n')[1]
        message = length(message) > 80 ? message[1:77] * "..." : message

        # Extract author from creator
        creator = get(build, :creator, nothing)
        author = if creator !== nothing
            get(creator, :name, "")
        else
            ""
        end
        author = isnothing(author) ? "" : String(author)

        jobs = get(build, :jobs, [])
        for job in jobs
            name = get(job, :name, nothing)
            name === nothing && continue
            name = String(name)

            # Skip non-script jobs (like wait, block, trigger)
            get(job, :type, nothing) == "script" || continue

            # Skip musl jobs
            occursin("musl", name) && continue

            duration = job_duration_seconds(job)
            duration === nothing && continue

            entry = (
                commit = commit,
                build_number = build_num,
                created_at = created,
                duration_seconds = duration,
                message = message,
                author = author
            )

            if haskey(job_timings, name)
                push!(job_timings[name], entry)
            else
                job_timings[name] = [entry]
            end
        end
    end

    return job_timings
end

function compute_stats(timings)
    durations = [t.duration_seconds for t in timings]
    return (
        count = length(durations),
        mean = mean(durations),
        median = median(durations),
        min = minimum(durations),
        max = maximum(durations),
        std = length(durations) > 1 ? std(durations) : 0.0
    )
end

function load_existing_data(output_dir)
    summary_file = joinpath(output_dir, "timing_summary.json")
    !isfile(summary_file) && return Dict{String, Any}()
    try
        data = JSON3.read(read(summary_file, String))
        @info "Loaded existing data" file=summary_file num_jobs=length(get(data, :jobs, Dict()))
        return data
    catch e
        @warn "Failed to load existing data, starting fresh" error=e
        return Dict{String, Any}()
    end
end

function generate_json_output(job_timings; output_dir="data")
    mkpath(output_dir)

    # Load existing data to preserve history beyond Buildkite's window
    existing = load_existing_data(output_dir)
    existing_jobs = get(existing, :jobs, Dict())

    summary = Dict{String, Any}()
    summary["generated_at"] = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SSZ")
    summary["jobs"] = Dict{String, Any}()

    # Collect all job names from both sources
    all_job_names = union(keys(job_timings), String.(keys(existing_jobs)))

    for name in all_job_names
        # Start with new data
        new_timings = get(job_timings, name, [])
        new_records = [
            Dict(
                "commit" => t.commit,
                "build" => t.build_number,
                "date" => Dates.format(t.created_at, dateformat"yyyy-mm-dd HH:MM"),
                "duration" => round(t.duration_seconds, digits=1),
                "message" => t.message,
                "author" => t.author
            )
            for t in new_timings
        ]

        # Merge with existing records (by build number to dedupe)
        existing_job = get(existing_jobs, Symbol(name), nothing)
        if existing_job !== nothing
            existing_recent = get(existing_job, :recent, [])
            new_builds = Set(r["build"] for r in new_records)
            for old in existing_recent
                build = get(old, :build, nothing)
                if build !== nothing && build ∉ new_builds
                    push!(new_records, Dict(
                        "commit" => get(old, :commit, ""),
                        "build" => build,
                        "date" => get(old, :date, ""),
                        "duration" => get(old, :duration, 0.0),
                        "message" => get(old, :message, ""),
                        "author" => get(old, :author, "")
                    ))
                end
            end
        end

        isempty(new_records) && continue

        # Sort by date descending and compute stats
        sorted = sort(new_records, by=r->r["date"], rev=true)
        durations = [r["duration"] for r in sorted]
        stats = (
            count = length(durations),
            mean = mean(durations),
            median = median(durations),
            min = minimum(durations),
            max = maximum(durations),
            std = length(durations) > 1 ? std(durations) : 0.0
        )

        summary["jobs"][name] = Dict(
            "stats" => Dict(
                "count" => stats.count,
                "mean_seconds" => round(stats.mean, digits=1),
                "median_seconds" => round(stats.median, digits=1),
                "min_seconds" => round(stats.min, digits=1),
                "max_seconds" => round(stats.max, digits=1),
                "std_seconds" => round(stats.std, digits=1)
            ),
            "recent" => sorted  # Keep all historical data
        )
    end

    # Write summary JSON
    summary_file = joinpath(output_dir, "timing_summary.json")
    open(summary_file, "w") do f
        JSON3.pretty(f, summary)
    end
    @info "Wrote summary" file=summary_file num_jobs=length(summary["jobs"])

    return summary_file
end

function main()
    @info "Fetching builds from Buildkite..."
    builds = fetch_builds(; pages=30)
    @info "Fetched julia-master builds" count=length(builds)

    scheduled_builds = fetch_scheduled_builds(; pages=10)
    @info "Fetched julia-master-scheduled builds" count=length(scheduled_builds)

    all_builds = vcat(builds, scheduled_builds)
    @info "Total builds" count=length(all_builds)

    if isempty(all_builds)
        @error "No builds fetched - check your token and permissions"
        return 1
    end

    @info "Extracting job timings..."
    job_timings = extract_job_timings(all_builds)
    @info "Found jobs" count=length(job_timings)

    @info "Generating JSON output..."
    generate_json_output(job_timings)

    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
