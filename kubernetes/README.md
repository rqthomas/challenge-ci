# Kubernetes

No jobs run on Kubernetes. Every scheduled stage runs in GitHub Actions
(`.github/workflows/`), with heavy jobs on the self-hosted runner named by
`ci$large_runner` in `challenge_configuration.yaml`. The bundling and stage 1–2
driver CronJobs that used to be here duplicated the Actions workflows on the
same schedule, so both wrote the same data; they were removed.

If a stage ever needs more memory than a runner offers, run it as a CronJob
that clones the challenge repository and runs the same command the workflow
does, e.g. `Rscript -e 'challengeci::run_stage()' bundle forecasts`, in the
image named by the challenge's `ci$docker_image`. Then comment out the trigger
workflow's `schedule`, so the stage still has a single owner.

## Secrets

Create secrets in the namespace if they do not already exist:

```
kubectl create secret generic github-secrets --from-literal=GITHUB_PAT=<your-github-token> -n <namespace>
kubectl create secret generic osn-secrets --from-literal=OSN_KEY=<your-osn-key> --from-literal=OSN_SECRET=<your-osn-secret> -n <namespace>
```

Edit or view secrets:

```
kubectl get secrets -n <namespace>
kubectl edit secret github-secrets -n <namespace>
```
