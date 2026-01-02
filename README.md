# Julia CI Timing Dashboard

A dashboard tracking build and test times for the Julia programming language's CI on [Buildkite](https://buildkite.com/julialang/julia-master).

## Live Dashboard

Visit: **https://JuliaCI.github.io/julia-ci-timing/**

## Features

- **Interactive Charts** — Visualize timing trends for all CI jobs with zoom, pan, and filtering
- **Moving Averages** — Toggle between raw data and 7/30/90-day smoothed trends
- **Statistical Analysis** — Linear regression with p-values to detect significant trends
- **Host Filtering** — Filter by build agent to isolate host-specific performance
- **State Filtering** — Show/hide passed, failed, timed_out, and canceled jobs
- **Code Coverage** — Track Codecov coverage trends alongside timing data
- **Comparison Mode** — Compare PR builds against master baseline with visual overlays

## Comparison Tool

Compare a PR or specific build against the baseline:

```bash
export BUILDKITE_API_TOKEN="your-token"
julia --project=. compare_build.jl <build_number> [options]
```

**Options:**
- `--baseline-commits N` — Number of baseline commits to compare (default: 20)
- `--base-build N` — Override automatic base detection
- `--threshold PERCENT` — Minimum percent change for significance (default: 10)
- `--json` — Output as JSON
- `--markdown` — Output as Markdown (for GitHub PR comments)

For PR builds, the tool automatically detects the merge base using git and compares against commits from that point in history. Results include a URL to visualize the comparison on the dashboard.

**Exit codes:** 0 = no regressions, 1 = regressions detected, 2 = error

## GitHub Actions Integration

See [ci-timing-check.yml](ci-timing-check.yml) for a GitHub Actions workflow that automatically checks PR builds for timing regressions and posts results as PR comments.

## Data Sources

The dashboard fetches data from two Buildkite pipelines:
- **julia-master** — Regular builds and tests on every commit
- **julia-master-scheduled** — Coverage jobs run on periodic commits

## License

MIT
