# Terraform for the "brandon_databricks_issue - dbt build" job, matching
# the config that was manually built and verified working in the
# Databricks UI first (git source, serverless compute, environment with
# requirements.txt, catalog/schema, SQL warehouse).
#
# NOT YET APPLIED — review with `terraform plan` before `terraform apply`.
#
# environment_version confirmed as "5" from the working job's own
# Environments panel (Environment version: 5, Dependencies: 1).
#
# warehouse_id is looked up by name below instead of hardcoded, so this
# stays correct if the warehouse is ever recreated (which changes its
# id, but not its name).

terraform {
  required_providers {
    databricks = {
      source = "databricks/databricks"
    }
  }
}

data "databricks_sql_warehouses" "starter" {
  warehouse_name_contains = "Serverless Starter Warehouse"
}

# A bare "-r requirements.txt" in the environment's dependencies does
# NOT resolve against the git-cloned checkout — confirmed by a real
# apply, which failed with "No such file or directory: '/tmp/requirements.txt'".
# The environment's dependency installer runs in a different working
# directory than the dbt task itself. Reading the file's content here
# instead and baking the actual package list into the job config keeps
# requirements.txt as the single source of truth (matching what's
# pinned for local dev) without depending on a runtime file lookup
# that doesn't work for git-sourced jobs.
locals {
  requirements = [
    for line in split("\n", trimspace(file("${path.module}/../requirements.txt"))) :
    trimspace(line) if trimspace(line) != ""
  ]
}

resource "databricks_job" "brandon_databricks_issue_dbt_build" {
  name               = "brandon_databricks_issue - dbt build"
  performance_target = "PERFORMANCE_OPTIMIZED" # preserves the manually-created job's current setting

  git_source {
    url      = "https://github.com/SanmariV/brandon_databricks_issue"
    provider = "gitHub"
    branch   = "main"
  }

  environment {
    environment_key = "dbt_env"

    spec {
      environment_version = "5"
      dependencies         = local.requirements
    }
  }

  task {
    task_key        = "dbt_build"
    environment_key = "dbt_env"

    dbt_task {
      commands          = ["dbt seed", "dbt build"]
      source            = "GIT"
      project_directory = "."
      catalog           = "dev"
      schema            = "brandon_databricks_issue"
      warehouse_id      = tolist(data.databricks_sql_warehouses.starter.ids)[0]
    }
  }
}
