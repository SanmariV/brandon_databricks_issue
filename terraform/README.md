# Terraform setup guide — brandon_databricks_issue dbt job

This walks through linking this repo's Databricks job (the one running
`dbt seed` + `dbt build` against the bronze snapshots and `crm_pit_spine`)
to Terraform, importing the job that was first built manually in the
Databricks UI, and every error hit getting there — so the next person
doing this doesn't have to rediscover each one.

**Recommended order**: build the job manually in the Databricks UI
first, confirm it actually runs, *then* write the Terraform for it and
import the existing job. Writing Terraform against a config that's
never been proven to work means debugging the job and the Terraform
syntax at the same time.

## 1. Install Terraform

On Windows, via `winget` (built in, no separate install needed):

```powershell
winget install Hashicorp.Terraform
```

Close and reopen your terminal afterward — a newly-installed binary
isn't visible in a terminal that was already open before the install
(PATH is only re-read when a new terminal process starts).

```powershell
terraform version
```

## 2. Authenticate Terraform to Databricks

The Terraform Databricks provider reads credentials from two
environment variables — **not** from `~/.dbt/profiles.yml`, which is
dbt-specific and Terraform doesn't touch:

```powershell
[System.Environment]::SetEnvironmentVariable("DATABRICKS_HOST", "https://<your-workspace-hostname>", "User")
[System.Environment]::SetEnvironmentVariable("DATABRICKS_TOKEN", "<your token>", "User")
```

Two things that differ from the dbt setup:
- `DATABRICKS_HOST` needs the **full URL with `https://`** — dbt's
  `profiles.yml` `host` field just wants the bare hostname, this one
  doesn't.
- You can reuse the same Personal Access Token already generated for
  dbt — no need for a second one.

Same gotcha as any `SetEnvironmentVariable(..., "User")` call: it
writes permanently to the registry, but a terminal that was already
open won't see it. Close and reopen the terminal, then confirm both
are visible before moving on:

```powershell
if ($env:DATABRICKS_HOST) { "HOST OK" } else { "HOST MISSING" }
if ($env:DATABRICKS_TOKEN) { "TOKEN OK" } else { "TOKEN MISSING" }
```

To check a token's actual value later (e.g. to reuse it somewhere
else) without regenerating it — Databricks only shows a PAT once at
creation — print it in your own terminal (never paste the value into
a chat or anywhere else):

```powershell
$env:DBT_DATABRICKS_TOKEN
# or, if that's empty in the current session:
[System.Environment]::GetEnvironmentVariable("DBT_DATABRICKS_TOKEN", "User")
```

## 3. Initialize Terraform

From inside the `terraform/` folder:

```powershell
cd terraform
terraform init
```

This downloads the Databricks provider plugin and writes
`.terraform.lock.hcl` (commit this file — it pins the exact provider
version so everyone gets the same one). Only needs running once per
folder, or again later if a new provider/module is added.

## 4. Plan — and import the existing manually-built job

Run a first plan:

```powershell
terraform plan
```

If a job was already built manually in the Databricks UI (as
recommended above), this plan will show **`1 to add`** — Terraform has
no way of knowing that job already exists, since nothing has told it
so yet. Applying at this point would create a **second, duplicate
job**, not take over the existing one.

Instead, **import** the existing job by its Job ID (visible in the
Databricks UI under the job's **Job details** panel):

```powershell
terraform import databricks_job.<resource_name> <job-id>
```

Then plan again — it should now show `0 to add`, and either `0 to
change` (config matches exactly) or a diff of whatever's actually
different between the real job and what's declared in the `.tf` file.

## 5. Review the diff — don't apply blindly

A post-import diff is genuinely useful, not just noise — it surfaces
real drift between what's in Databricks and what's declared in code.
From doing this once, the diff fell into three categories:

- **Cosmetic** — internal identifiers (`environment_key`, `task_key`)
  being renamed. Safe, no functional change.
- **Real drift worth preserving** — an attribute set in the UI
  (`performance_target = "PERFORMANCE_OPTIMIZED"`) that wasn't yet
  declared in the `.tf` file, which would have been silently reverted
  to default on apply. Fix: add it to the resource explicitly rather
  than let the diff go through.
- **An actual bug the diff caught** — the manually-built job's
  `commands` were `["dbt deps", "dbt seed", "dbt run"]`, not the
  intended `["dbt seed", "dbt build"]`. `dbt run` only builds models —
  it does **not** run snapshots or tests. The job had been "succeeding"
  while silently skipping the snapshots and every custom test in this
  project. The diff caught this; applying it was the fix.

Read every line of a post-import diff before typing `yes`.

## 6. Apply

```powershell
terraform apply
```

Review the plan it shows one more time, type `yes` to confirm.
**Immediately afterward**, go into the Databricks UI and click **Run
now** on the job and watch it live — `terraform apply` succeeding only
means the job's *configuration* was written correctly, not that the
job actually runs successfully end to end.

## 7. Troubleshooting — errors hit along the way

| Error | Cause | Fix |
|---|---|---|
| `Inconsistent dependency lock file` | `terraform init` was never run in this folder | Run `terraform init` before `plan`/`apply` |
| `Invalid index` on `...ids[0]` | A data source's `ids` attribute is a Terraform **set**, not a list — sets are unordered and can't be indexed directly | Wrap it: `tolist(data.databricks_sql_warehouses.x.ids)[0]` |
| `cannot configure default credentials` | `DATABRICKS_HOST`/`DATABRICKS_TOKEN` env vars not set (or set in a terminal that predates them) | Set both (see step 2), then use a fresh terminal |
| `No configuration files` | Running `terraform plan`/`apply` from the repo root instead of the `terraform/` subfolder where the `.tf` files actually live | `cd terraform` first |
| `Library installation failed ... /tmp/requirements.txt` | A relative `-r requirements.txt` path in a job's `environment` dependencies does **not** resolve against the git-cloned checkout — it resolves against a different working directory the environment installer uses, unrelated to the dbt task's own `project_directory` | Don't reference a file path at all — read `requirements.txt`'s content into Terraform via `file()` and a `locals` block, and pass the resulting package list directly as `dependencies`. Keeps `requirements.txt` as the single source of truth without needing a runtime file lookup that doesn't work for git-sourced jobs. |
| `source_relationships_...` test fails intermittently, run log shows the test finishing *before* the seed that populates the same table finishes loading | The table was declared as a dbt `source()` (implying it's populated by something outside dbt's control) but was actually populated by a `dbt seed` in the same run — dbt has no way of linking a seed to a same-named source, so it schedules them as unrelated, concurrent nodes | Reference the seed via `ref('seed_name')` instead of `source(...)` wherever it's actually the seed populating that data — this gives dbt a real DAG edge so downstream reads correctly wait for the seed to finish |
| `git push` fails with `Filename too long`, pointing at a path under `terraform/.terraform/providers/.../*.exe` | Terraform's local provider plugin cache (`.terraform/`) was about to be committed — a long nested path plus a Windows path-length limit broke the git index write | Add `**/.terraform/*`, `*.tfstate`, `*.tfstate.*`, and related Terraform artifacts to `.gitignore`. `.terraform/` is regenerated by `terraform init`, and `.tfstate` files can contain sensitive values — neither belongs in git. `.terraform.lock.hcl` is the exception: that one **should** be committed. |

## 8. `.gitignore` additions for Terraform

```gitignore
# Terraform
**/.terraform/*
*.tfstate
*.tfstate.*
*.tfvars
*.tfvars.json
crash.log
crash.*.log
override.tf
override.tf.json
*_override.tf
*_override.tf.json
```
