# Node.js Jenkins Pipeline Examples

These examples demonstrate a development pipeline and a production-oriented release pipeline for a containerized Node.js application. They are designed for the Jenkins and Docker-in-Docker services in this repository and deploy to a remote Ubuntu host running Docker Compose.

They are reference templates, not universal production defaults. Copy the relevant Jenkinsfile into the application repository and adapt registry names, URLs, credential IDs, commands, approval policy, and deployment paths.

## Pipeline Model

The development pipeline builds the application, runs quality checks, creates an image tagged with the Git commit, pushes it to a registry, resolves the registry digest, deploys that digest automatically, and verifies the development health endpoint.

The production pipeline does not rebuild the source. It promotes an existing immutable image tag, scans it, waits for authorized approval, deploys it, verifies health, and rolls back to the previously recorded image when verification fails.

## Application Repository Requirements

The application repository must contain:

- `package.json` and `package-lock.json`
- A production `Dockerfile`
- An `npm run build` script
- Optional `lint` and `test` scripts
- A stable HTTP health endpoint

The development pipeline archives common `build`, `dist`, `coverage`, and JUnit report paths when present.

## Jenkins Credentials

Create these credentials in Jenkins before running the pipelines:

| Credential ID | Type | Purpose |
| --- | --- | --- |
| `docker-registry` | Username with password | Push and pull application images. |
| `development-deploy-ssh` | SSH username with private key | Deploy to the development host. |
| `development-known-hosts` | Secret file | Trusted SSH known-hosts entries for development. |
| `production-deploy-ssh` | SSH username with private key | Deploy to the production host. |
| `production-known-hosts` | Secret file | Trusted SSH known-hosts entries for production. |

Do not disable strict host-key verification. Create each known-hosts file through a trusted administrative channel and verify its fingerprint before storing it in Jenkins.

The Jenkins image includes `openssh-client` so the examples can use SSH without an additional Jenkins plugin.

## Registry and Scanner

Replace `registry.example.com/team/node-app` through the build parameters. The development job prints the immutable digest reference after a successful push. Pass its `sha256:...` portion to the production `IMAGE_DIGEST` parameter. Production deploys `repository@sha256:...` and never rebuilds or deploys `latest`.

The production pipeline requires `TRIVY_IMAGE` to use a digest-pinned Trivy image, for example:

```text
aquasec/trivy@sha256:REPLACE_WITH_VERIFIED_DIGEST
```

Obtain and review the digest through your approved image-management process. High or critical unfixed findings fail the production security gate.

## Remote Deployment Host

On each Ubuntu deployment host, create the deployment directory and save `compose.deploy.example.yaml` as `compose.yaml`. Create a local `.env` containing application-specific settings, for example:

```dotenv
APP_PORT=8080
CONTAINER_PORT=3000
NODE_ENV=production
```

The remote SSH user must be able to run Docker Compose and modify the deployment directory. Grant only the permissions required for this application.

The Compose service must remain named `app` because both Jenkinsfiles deploy that service explicitly.

## Suggested Job Configuration

Use a multibranch Pipeline for development and load `examples/node-app/Jenkinsfile.development` through the Jenkins Script Path setting while evaluating the template. After copying it to an application repository, use the copied path.

Use a separate, access-restricted Pipeline job for production. Restrict build permission and the `release-managers` approval group to authorized operators. Production deployment is limited to `main` or a release tag when multibranch metadata is available.

Before the first production release, test health-check failure and rollback in a disposable environment. Automatic rollback requires a previous successful release recorded in `.release-image`.

## Required Customization Checklist

- Replace registry, host, path, and health URL defaults.
- Create and scope all Jenkins credentials.
- Pin and approve the Node.js and Trivy images used by the pipelines.
- Confirm the remote Compose service is named `app`.
- Confirm the application image exposes the configured container port.
- Configure firewall, DNS, TLS, backup, and log retention on deployment hosts.
- Add organization-specific notifications, change records, and approval policy.
- Test deployment, failed health checks, and rollback before production use.
