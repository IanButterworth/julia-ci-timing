# Julia CI Timing Dashboard

A dashboard tracking build and test times for the Julia programming language's CI on [Buildkite](https://buildkite.com/julialang/julia-master).

## Live Dashboard

Visit: **https://julialang.github.io/julia-ci-timing/** (once deployed)

## Features

- 📊 Historical job duration charts
- 📈 Trend analysis (faster/slower than previous run)
- 🔍 Filter by job type (build, test, etc.)
- ⏱️ Stats: median, mean, min, max, standard deviation
- 🔄 Updated every 2 hours via GitHub Actions

## Local Development

### Prerequisites

- Julia 1.11+
- A Buildkite API token with `read_builds` scope

### Setup

1. Create a Buildkite API token at https://buildkite.com/user/api-access-tokens
   - Enable "Read Builds" scope
   - (Optionally enable access to the julialang org specifically)

2. Set the token:
   ```bash
   export BUILDKITE_TOKEN="bkua_xxxx..."
   # Or create ~/.buildkite_token
   ```

3. Install Julia dependencies:
   ```bash
   julia -e 'using Pkg; Pkg.add(["HTTP", "JSON3"])'
   ```

4. Fetch data:
   ```bash
   julia fetch_timing.jl
   ```

5. Serve locally:
   ```bash
   python3 -m http.server 8000
   # Open http://localhost:8000
   ```

## GitHub Actions Setup

To enable automatic updates:

1. Add `BUILDKITE_TOKEN` as a repository secret
2. Enable GitHub Pages (Settings → Pages → Source: GitHub Actions)

## Data Format

The fetcher generates `data/timing_summary.json` with:

```json
{
  "generated_at": "2024-12-26T12:00:00Z",
  "jobs": {
    "Job Name": {
      "stats": {
        "count": 100,
        "mean_seconds": 1234.5,
        "median_seconds": 1200.0,
        "min_seconds": 900.0,
        "max_seconds": 1800.0,
        "std_seconds": 150.0
      },
      "recent": [
        {
          "commit": "abc12345",
          "build": 12345,
          "date": "2024-12-26 10:00",
          "duration": 1234.5
        }
      ]
    }
  }
}
```

## License

MIT
