# FuguHub Stress Harness

Create the isolated stress deployment from the repository root:

```cmd
create-stress-deploy.cmd
```

On Linux, where `zip`, `unzip`, and `python3` are available:

```sh
sh ./create-stress-deploy.sh
```

The command builds the plugin-free core CMS and theme ZIP packages, lets
FuguHub initialize a fresh database, creates ten published benchmark entries
through the admin HTTP API, verifies every rendered response, and writes:

```text
deploy-stress/
  cms.zip
  themes/
    default.zip
    embedded-dashboard.zip
  data/
    cms.sqlite.db
  stress-urls.txt
```

The database has five pages and five posts in sizes from approximately 2 KiB
through 512 KiB. Exactly five entries use `render_mode='lsp'` and execute
deterministic Lua code on every request. The CMS-required editable 404 page is
also present but is not part of the benchmark corpus.

This is a benchmark fixture, not a production database. It intentionally has
no admin users or MCP token. Use it only on localhost or an isolated test
network.

Start the target server from `deploy-stress`:

```cmd
mako -l::cms.zip
```

Run the load generator from another computer when measuring constrained target
hardware. Running the generator on the target consumes CPU and network
resources and distorts the result.

```cmd
stress\stress-test.cmd --host localhost --concurrency 32 --requests 10000
```

Linux:

```sh
python3 ./stress/stress-test.py --host localhost --concurrency 32 --requests 10000
```

Remote target:

```cmd
stress\stress-test.cmd --host 192.168.1.50 --port 80 --concurrency 64 --requests 50000
```

```sh
python3 ./stress/stress-test.py --host 192.168.1.50 --port 80 --concurrency 64 --requests 50000
```

Named CMS mount:

```cmd
stress\stress-test.cmd --host test.example.com --base /mybase/ --concurrency 32
```

```sh
python3 ./stress/stress-test.py --host test.example.com --base /mybase/ --concurrency 32
```

HTTPS with a development certificate:

```cmd
stress\stress-test.cmd --scheme https --port 443 --insecure
```

```sh
python3 ./stress/stress-test.py --scheme https --port 443 --insecure
```

The default client requests deflate compression and keeps one HTTP connection
per worker. Use `--encoding identity` to compare uncompressed responses and
`--no-keepalive` to include a new connection in every measured GET. Use
`--csv result.csv` to save per-request timings.

## SQLite WAL Comparison

The WAL comparison keeps FuguHub's dedicated writer thread and transaction
model unchanged. It varies only SQLite's persistent journal mode, then mixes
concurrent public GET requests with repeated page updates through the real
admin HTMX endpoint:

```powershell
.\create-stress-deploy.cmd
python .\stress\sqlite-wal-test.py
```

The test clones `deploy-stress` beneath `.test-runtime/sqlite-wal`, rotates the
mode order between rounds, rejects HTTP or SQLite failures, and reports median
GET throughput plus read and write latency. It compares rollback journaling,
WAL with SQLite's default synchronous setting, and WAL with
`synchronous=NORMAL`. The latter is injected only into the cloned test archive;
the production database and CMS database module are not modified.
