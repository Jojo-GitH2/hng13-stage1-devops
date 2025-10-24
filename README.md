# hng13-stage1-devops

### README

#### Overview
This shell script automates deployment of a Dockerized application from a remote Git HTTPS repository to a remote server over SSH. It can:
- Clone or update a repository using a Personal Access Token for private repos.
- Detect Docker context and build/run a Docker image on the remote host.
- Install Docker and Nginx on the remote host (Debian/Ubuntu via apt) if missing.
- Sync repository files to the remote host using rsync or scp.
- Configure Nginx as a reverse proxy forwarding port 80 to the application port.
- Provide a cleanup mode to remove deployed app files, Docker image/container, and nginx site config.

---

#### Requirements
- Local machine:
  - /bin/sh compatible shell
  - git, sed, ssh, scp, rsync (optional), nc (optional)
- Remote host:
  - SSH access with a private key
  - Debian/Ubuntu-compatible package manager for automated installs
  - Passwordless sudo is recommended for automated installs and nginx reloads

---

#### Usage
- Deploy:
  1. Run the script without arguments.
  2. Enter the prompted values:
     - Git repository HTTPS URL
     - Personal Access Token (PAT)
     - Branch (defaults to main)
     - Remote SSH username
     - Remote server IP or hostname
     - SSH private key path
     - Application internal container port (numeric)
     - Application name (defaults to app)
  3. Script clones to /tmp/<app>_deploy, finds Docker context, syncs files to remote, builds and runs a Docker container, and configures Nginx.

- Cleanup:
  1. Run the script with --cleanup.
  2. Enter remote SSH username, host, SSH key path, and application name.
  3. Script removes container, image, application files, and nginx site config on the remote host.

---

#### Configuration and defaults
- DEFAULT_BRANCH: main
- Local clone dir: /tmp/${APP_NAME}_deploy
- Remote app dir: /home/${REMOTE_USER}/${APP_NAME}
- Nginx site file: /etc/nginx/sites-available/${APP_NAME}.conf
- Container EXPOSE detection: reads EXPOSE from Dockerfile if present; defaults to 80

---

#### Security notes
- The script avoids writing the raw PAT to logs but uses it to clone private repos via an embedded URL.
- Keep SSH private keys secure with appropriate file permissions.
- For production, use proper secrets management and HTTPS/TLS for public-facing services.

---

#### Troubleshooting
- SSH issues: confirm key, username, host, and port 22 access; test with ssh -i <key> user@host.
- Git clone failures: confirm PAT has repo read permission and the requested branch exists.
- Docker install failures: script assumes apt-based systems; adapt the remote install block for other distributions.
- Nginx reload failures: if passwordless sudo is not available, nginx may require manual reload on the remote host; the cleanup mode prints the manual commands to run remotely.
- Logs: a timestamped log file is created under /tmp named deploy_YYYYMMDD_HHMMSS.log; consult it for detailed output.
- Out Of Memory (OOM) during remote Docker build: a Docker image build on a low-memory remote host can fail with OOM errors during compilation or multi-stage builds. Solution: choose a remote server with higher memory and CPU resources and retry the build. If upgrading the server is not possible, reduce build memory usage by simplifying the Dockerfile, using smaller base images, splitting heavy build steps into smaller steps, or performing the build on a more capable CI/build host and pushing the finished image to a registry for the remote host to pull.

---

#### Recommendations
- For automated deployments, convert interactive prompts to CLI flags or environment variables.
- Build large or resource-intensive images in a CI pipeline or on a machine with more RAM and CPU, then push the image to a container registry for deployment.
- Add TLS termination with a certificate manager or Let's Encrypt in front of Nginx for secure production deployments.

---

#### Example
- Deploy:
  1. ./deploy.sh
  2. Follow prompts for repository, PAT, remote host, SSH key, app port, and app name.
  3. Check /tmp/deploy_<timestamp>.log for the full deployment log.

- Cleanup:
  1. ./deploy.sh --cleanup
  2. Provide remote details and app name when prompted.

---

