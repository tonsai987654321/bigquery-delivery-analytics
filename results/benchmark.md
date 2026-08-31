# Benchmark — partitioning and clustering

run_id: `bench20260831113440` · project: `bq-scg-portfolio` · generated: 2026-08-31T04:35:07Z

| Query | Layout | dry-run bytes | real bytes | slot ms |
|---|---|---:|---:|---:|
| Q1  3-month range, all states | plain table | 1929400 | 1929400 | 25 |
|  | partition + cluster | 412540 | 412540 | 53 |
| | **reduction (real bytes)** | | **78.6%** | |
| Q2  one state, full history | plain table | 2701160 | 2701160 | 22 |
|  | partition + cluster | 2701160 | 2701104 | 151 |
| | **reduction (real bytes)** | | **0.0%** | |
| Q3  6-month range + one state | plain table | 5209380 | 5209380 | 27 |
|  | partition + cluster | 2174580 | 2174580 | 50 |
| | **reduction (real bytes)** | | **58.3%** | |
