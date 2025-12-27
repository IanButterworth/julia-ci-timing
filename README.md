# Julia CI Timing Dashboard

A dashboard tracking build and test times for the Julia programming language's CI on [Buildkite](https://buildkite.com/julialang/julia-master).

## Live Dashboard

Visit: **https://IanButterworth.github.io/julia-ci-timing/**

## Features

- 📊 Historical job duration charts with time-accurate x-axis
- 🎯 Matrix-based job selector (platform × type, including coverage jobs)
- 🌓 Automatic light/dark mode (follows system preference)
- 🔗 Click data points to see commit details and links to GitHub/Buildkite
- ⏱️ Stats: median, mean, min, max, standard deviation
- 🔄 Updated every 2 hours via GitHub Actions
- 📦 Preserves historical data beyond Buildkite's API window

## Data Sources

The dashboard fetches data from two Buildkite pipelines:
- **julia-master** — Regular builds and tests on every commit
- **julia-master-scheduled** — Coverage jobs run on periodic commits

## Local Development

### Prerequisites

- Julia 1.11+
- A Buildkite API token with `read_builds` scope

### Setup

1. Create a Buildkite API token at https://buildkite.com/user/api-access-tokens
   - Enable "Read Builds" scope
   - (Optionally limit access to the julialang org)

2. Set the token:
   ```bash
   export BUILDKITE_API_TOKEN="bkua_xxxx..."
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

1. Add `BUILDKITE_API_TOKEN` as a repository secret
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
          "duration": 1234.5,
          "message": "Commit title",
          "author": "username"
        }
      ]
    }
  }
}
```

Data is merged on each fetch—new builds are added while historical builds are preserved, deduplicated by build number.

## License

MIT
