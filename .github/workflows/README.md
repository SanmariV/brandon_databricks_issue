# GitHub Actions CI setup guide

Covers two situations: setting this up for a solo/personal repo (what's
already built — `dbt_ci.yml`), and setting it up for a shared team repo,
where a personal token is the wrong credential to use.

## Part 1 — Personal account

This is already done for this repo, but here's the checklist for
reusing the pattern elsewhere:

1. **Generate a Databricks Personal Access Token**: Databricks →
   **Settings → Developer → Access tokens**.
2. **Add five repo secrets**: GitHub repo → **Settings → Secrets and
   variables → Actions → New repository secret**:

   | Secret | Value |
   |---|---|
   | `DATABRICKS_HOST` | bare hostname, no `https://` |
   | `DATABRICKS_HTTP_PATH` | SQL Warehouse's HTTP path |
   | `DATABRICKS_TOKEN` | the PAT from step 1 |
   | `DATABRICKS_CATALOG` | your dev catalog |
   | `DATABRICKS_CI_SCHEMA` | a schema separate from your local dev schema |

3. Open a PR touching `models/`, `macros/`, `seeds/`, or `snapshots/`
   and check the **Actions** tab.

The catch with this setup: the token is tied to one person's account.
If that person leaves, changes their password, or has their token
revoked, CI silently breaks for everyone else on the repo — fine for a
solo prototype, not fine for a team.

## Part 2 — Team / shared repo, with a Databricks service principal

A service principal is Databricks' non-human identity for automation —
it isn't tied to any one person's account, survives someone leaving,
and can be scoped to only the permissions CI actually needs (not
whatever a real person's account happens to have).

### 1. Create the service principal

This step needs a Databricks **account admin** — if that's not you,
this is the part to hand to whoever is.

**Account Console** (admin.databricks.com, or via workspace admin
settings) → **User management → Service principals → Add service
principal**. Give it a clear name, e.g. `ci-brandon-databricks-issue`.

### 2. Grant it access

The service principal needs exactly what CI needs to run `dbt seed` /
`dbt build` — nothing more:

- **Add it to the workspace** the SQL Warehouse and catalog live in.
- **SQL Warehouse**: grant it **Can Use** on the warehouse (Compute →
  SQL Warehouses → the warehouse → Permissions).
- **Unity Catalog**: grant it `USE CATALOG`, `USE SCHEMA`,
  `CREATE TABLE`, `MODIFY`, and `SELECT` on the specific dev/CI
  catalog and schema — not broader than that. This can be done via SQL
  (`GRANT ... ON SCHEMA ... TO \`ci-brandon-databricks-issue\`;`) or
  through Catalog Explorer's Permissions tab.

### 3. Generate credentials for it

Two supported approaches — pick one, don't mix:

**Option A — a token, reusing the exact setup already built (simplest)**

Databricks supports generating a Personal Access Token *for* a service
principal (not tied to a human). In the Account Console, open the
service principal → generate a token for it. This slots directly into
the same `DATABRICKS_TOKEN` secret and the same `profiles.yml`
template already in `dbt_ci.yml` — no workflow changes needed, just
swap which token value the secret holds.

**Option B — OAuth machine-to-machine (client ID + secret)**

Databricks' more modern recommendation for non-interactive/automated
auth specifically. Requires changing the generated `profiles.yml` in
the workflow to use `auth_type: oauth` with `client_id`/`client_secret`
instead of `token`. More setup, but avoids a long-lived static token
altogether (OAuth tokens are short-lived and auto-refreshed). Worth
the extra step if the team already has OAuth M2M conventions elsewhere;
Option A is fine otherwise.

This guide uses **Option A**, since it requires zero changes to the
existing workflow.

### 4. Store the credential where the team can actually use it

For a shared repo, repo-level secrets still work, but two GitHub
features are worth knowing about once more than one repo or more than
a couple of people are involved:

- **Environment secrets** (repo → **Settings → Environments** → create
  e.g. `ci`) — lets you require approval before a workflow can use the
  secret, useful if you want a human to approve the first run on a new
  branch.
- **Organization secrets** (org → **Settings → Secrets and variables →
  Actions**) — one set of Databricks credentials shared across every
  repo in the org that needs them, instead of re-adding the same five
  secrets per repo. Worth using once there's more than one dbt project
  reusing the same service principal.

For most team setups, start with repo-level secrets (same five names
as Part 1, just pointing at the service principal's token) and move to
org-level secrets once a second project needs the same credentials.

### 5. Make CI actually block bad merges

Running CI is only useful if a failing run stops a merge. Without this
step, `dbt_ci.yml` runs and reports status but nothing enforces it:

Repo → **Settings → Branches → Add branch protection rule** → branch
name pattern `main` → enable **Require status checks to pass before
merging** → select the `dbt-build` check (the job name from
`dbt_ci.yml`) → save.

Now a PR that breaks a test, reintroduces a bug like the original
watermark issue, or fails to build can't be merged until it's fixed —
which is the actual point of CI, not just running the pipeline
somewhere.
