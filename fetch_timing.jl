#!/usr/bin/env julia
# Fetch Julia CI timing data from Buildkite API

using HTTP
using JSON3
using Dates
using Statistics
using DataStructures: SortedDict

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

function fetch_builds(; branch="master", per_page=100, max_pages=30, fully_captured_below=0)
    builds = []
    
    for page in 1:max_pages
        params = Dict(
            "branch" => branch,
            "per_page" => per_page,
            "page" => page
        )
        data = api_get("organizations/$BUILDKITE_ORG/pipelines/$PIPELINE/builds"; params)
        data === nothing && break
        isempty(data) && break

        new_in_page = 0
        oldest_in_page = typemax(Int)
        for build in data
            oldest_in_page = min(oldest_in_page, build.number)
            # Only skip builds that are definitely fully captured (below threshold)
            if build.number >= fully_captured_below
                push!(builds, build)
                new_in_page += 1
            end
        end
        @info "Fetched page $page (julia-master)" new_or_updated=new_in_page skipped=length(data)-new_in_page oldest=oldest_in_page threshold=fully_captured_below

        # If we've gone past the threshold and all builds are known, we can stop
        if oldest_in_page < fully_captured_below && new_in_page == 0
            @info "Reached fully captured region, stopping early"
            break
        end
    end
    return builds
end

const SCHEDULED_PIPELINE = "julia-master-scheduled"

function fetch_scheduled_builds(; branch="master", per_page=100, max_pages=10, fully_captured_below=0)
    builds = []
    for page in 1:max_pages
        params = Dict(
            "branch" => branch,
            "per_page" => per_page,
            "page" => page
        )
        data = api_get("organizations/$BUILDKITE_ORG/pipelines/$SCHEDULED_PIPELINE/builds"; params)
        data === nothing && break
        isempty(data) && break

        new_in_page = 0
        oldest_in_page = typemax(Int)
        for build in data
            oldest_in_page = min(oldest_in_page, build.number)
            # Only skip builds that are definitely fully captured (below threshold)
            if build.number >= fully_captured_below
                push!(builds, build)
                new_in_page += 1
            end
        end
        @info "Fetched page $page (julia-master-scheduled)" new_or_updated=new_in_page skipped=length(data)-new_in_page oldest=oldest_in_page threshold=fully_captured_below

        # If we've gone past the threshold and all builds are known, we can stop
        if oldest_in_page < fully_captured_below && new_in_page == 0
            @info "Reached fully captured region, stopping early"
            break
        end
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

function extract_job_timings(builds, pipeline::String)
    # Group job durations by job name
    job_timings = Dict{String, Vector{@NamedTuple{
        commit::String,
        build_number::Int,
        created_at::DateTime,
        duration_seconds::Float64,
        message::String,
        author::String,
        state::String,
        agent::String,
        pipeline::String
    }}}()

    for build in builds
        build_num = build.number
        commit = String(build.commit)[1:min(8, length(build.commit))]
        created = parse_datetime(build.created_at)

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

            # Get job state (passed, failed, etc.)
            job_state = String(get(job, :state, "unknown"))

            # Get agent hostname
            agent_info = get(job, :agent, nothing)
            agent_hostname = if agent_info !== nothing
                String(get(agent_info, :hostname, ""))
            else
                ""
            end

            entry = (
                commit = commit,
                build_number = build_num,
                created_at = created,
                duration_seconds = duration,
                message = message,
                author = author,
                state = job_state,
                agent = agent_hostname,
                pipeline = pipeline
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

function get_known_build_numbers(existing_data)
    # Returns (master_builds, scheduled_builds) since the pipelines have independent numbering
    # These are builds we've seen before - but we should refetch builds that may have more jobs now
    master_builds = Set{Int}()
    scheduled_builds = Set{Int}()
    jobs = get(existing_data, :jobs, Dict())
    for (name, job) in pairs(jobs)
        recent = get(job, :recent, [])
        for record in recent
            build = get(record, :build, nothing)
            build === nothing && continue
            # Use the pipeline field to determine which set to add to
            pipeline = get(record, :pipeline, "julia-master")
            if pipeline == "julia-master-scheduled"
                push!(scheduled_builds, build)
            else
                push!(master_builds, build)
            end
        end
    end
    return (master=master_builds, scheduled=scheduled_builds)
end

# Get the minimum build number we should consider "fully captured"
# This is based on the oldest build in the most recent N entries of key jobs
function get_fully_captured_threshold(existing_data; key_jobs=[":linux: test x86_64-linux-gnu", ":linux: build x86_64-linux-gnu"], lookback=50)
    master_min = typemax(Int)
    scheduled_min = typemax(Int)
    jobs = get(existing_data, :jobs, Dict())
    
    for job_name in key_jobs
        job = get(jobs, Symbol(job_name), nothing)
        job === nothing && continue
        recent = get(job, :recent, [])
        isempty(recent) && continue
        
        # Look at the last N entries and find the minimum build number
        for r in recent[1:min(lookback, length(recent))]
            build = get(r, :build, nothing)
            build === nothing && continue
            pipeline = get(r, :pipeline, "julia-master")
            if pipeline == "julia-master-scheduled"
                scheduled_min = min(scheduled_min, build)
            else
                master_min = min(master_min, build)
            end
        end
    end
    
    return (master=master_min == typemax(Int) ? 0 : master_min, 
            scheduled=scheduled_min == typemax(Int) ? 0 : scheduled_min)
end

function generate_json_output(job_timings; output_dir="data")
    mkpath(output_dir)

    # Load existing data to preserve history beyond Buildkite's window
    existing = load_existing_data(output_dir)
    existing_jobs = get(existing, :jobs, Dict())

    summary = SortedDict{String, Any}()
    summary["jobs"] = SortedDict{String, Any}()

    # Collect all job names from both sources
    all_job_names = union(keys(job_timings), String.(keys(existing_jobs)))

    for name in all_job_names
        # Start with new data
        new_timings = get(job_timings, name, [])
        new_records = [
            SortedDict(
                "agent" => t.agent,
                "author" => t.author,
                "build" => t.build_number,
                "commit" => t.commit,
                "date" => Dates.format(t.created_at, dateformat"yyyy-mm-dd HH:MM"),
                "duration" => round(t.duration_seconds, digits=1),
                "message" => t.message,
                "pipeline" => t.pipeline,
                "state" => t.state
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
                    push!(new_records, SortedDict(
                        "agent" => get(old, :agent, ""),
                        "author" => get(old, :author, ""),
                        "build" => build,
                        "commit" => get(old, :commit, ""),
                        "date" => get(old, :date, ""),
                        "duration" => get(old, :duration, 0.0),
                        "message" => get(old, :message, ""),
                        "pipeline" => get(old, :pipeline, "julia-master"),
                        "state" => get(old, :state, "passed")
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

        summary["jobs"][name] = SortedDict(
            "recent" => sorted,
            "stats" => SortedDict(
                "count" => stats.count,
                "max_seconds" => round(stats.max, digits=1),
                "mean_seconds" => round(stats.mean, digits=1),
                "median_seconds" => round(stats.median, digits=1),
                "min_seconds" => round(stats.min, digits=1),
                "std_seconds" => round(stats.std, digits=1)
            )
        )
    end

    # Only write if jobs data actually changed (ignore generated_at timestamp)
    summary_file = joinpath(output_dir, "timing_summary.json")

    # Compare serialized jobs data (normalize by re-serializing both sides)
    new_jobs_json = sprint(io -> JSON3.pretty(io, summary["jobs"]))
    if isfile(summary_file)
        existing_content = read(summary_file, String)
        existing_parsed = JSON3.read(existing_content)
        existing_jobs = get(existing_parsed, :jobs, nothing)
        if existing_jobs !== nothing
            existing_jobs_json = sprint(io -> JSON3.pretty(io, existing_jobs))
            if existing_jobs_json == new_jobs_json
                @info "No changes to job data, skipping write" file=summary_file
                return summary_file
            end
        end
    end

    # Update timestamp and write
    summary["generated_at"] = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SSZ")
    open(summary_file, "w") do f
        JSON3.pretty(f, summary)
    end
    @info "Wrote summary" file=summary_file num_jobs=length(summary["jobs"])

    return summary_file
end

function main()
    # Load existing data first to enable early stopping
    @info "Loading existing data..."
    existing = load_existing_data("data")
    
    # Get threshold: builds below this number are fully captured (have all expected jobs)
    threshold = get_fully_captured_threshold(existing)
    @info "Fully captured threshold" master=threshold.master scheduled=threshold.scheduled

    @info "Fetching builds from Buildkite..."
    builds = fetch_builds(; max_pages=30, fully_captured_below=threshold.master)
    @info "Fetched julia-master builds" count=length(builds)

    scheduled_builds = fetch_scheduled_builds(; max_pages=10, fully_captured_below=threshold.scheduled)
    @info "Fetched julia-master-scheduled builds" count=length(scheduled_builds)

    if isempty(builds) && isempty(scheduled_builds) && threshold.master == 0 && threshold.scheduled == 0
        @error "No builds fetched and no existing data - check your token and permissions"
        return 1
    end

    @info "Extracting job timings..."
    master_timings = extract_job_timings(builds, "julia-master")
    scheduled_timings = extract_job_timings(scheduled_builds, "julia-master-scheduled")

    # Merge timings from both pipelines
    job_timings = master_timings
    for (name, timings) in scheduled_timings
        if haskey(job_timings, name)
            append!(job_timings[name], timings)
        else
            job_timings[name] = timings
        end
    end
    @info "Found jobs in new builds" count=length(job_timings)

    @info "Generating JSON output..."
    generate_json_output(job_timings)

    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
