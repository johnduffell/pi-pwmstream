<!-- SPDX-License-Identifier: Apache-2.0 -->

# Local pi-pwmstream development container

Guardian devenv is pinned in `../.tool-versions`. From the project root:

```sh
mise exec -- devenv generate
mise exec -- devenv check
```

Edit `devenv.yaml` or `escapehatch.json`, not generated JSON.
Open the project root in your IDE and select
`.devcontainer/shared/devcontainer.json` (project configuration) or
`.devcontainer/user/devcontainer.json` (merged personal preferences).
Review personal preferences before use: they can add mounts or dotfiles.
Docker's container name is explicitly `pi-pwmstream`; the devcontainer `name`
alone only sets a display label. Only one container with this Docker name can
exist at a time. Remove a previous stopped project container through the IDE
before recreating, or change the configured name if running multiple copies.

The image override selects the standard Debian 13 devcontainer base image.
A post-create command installs C/Make, device-tree tools, Python, kmod and
OpenSSH using sudo/apt. It requires package-network access on each fresh
container creation; restarting an existing container does not repeat it.
There is no project Dockerfile or dependency image build.
Guardian's mise/Copilot modules install mise, gh and Copilot CLI.
The generator version is pinned; the base-image tag, apt packages and module
tool downloads are not immutable pins yet. No Docker socket, privileged
mode, hardware devices or entire host home directory are explicitly mounted.
The project is writable and its changes persist on the host.

Workspace mounting, workspace path and remote user are now selected by the
IDE/image defaults, not overridden here. Choose Mount Sources and the
`vscode` development user in the IDE if it offers that choice. Verify
`whoami` is `vscode`: the mise/Copilot setup expects that user's home.
Setup runs relative to the IDE's workspace directory, not a fixed path.

Creation forces Linux userspace binaries to rebuild before running checks:
the moved workspace can contain macOS binaries. These rebuilds replace the
shared workspace binaries; force rebuild again if returning to Mac checks.
Raspberry Pi kernel headers are installed by the last post-create step
(`sh dev-tools/fetch-kernel-headers.sh --install`, then `make
check-kbuild`); it needs network and sudo, and a failure is logged as
`[setup] Errored!` without failing creation, so inspect `/var/log/post-create.log`.
To redo it manually, run the same two commands from the project root. Downloads
are SHA256-verified HTTPS fetches; Debian 13 apt rejects the Pi archive's
SHA1-bound signing key, so the archive is not added as an apt source.
`check-kbuild` also fails if the container's gcc differs from the compiler
recorded in the kernel headers (image drift: `debian-13` is a moving tag).
Hardware-free checks do not load the module, deploy or emit output. Inspect creation logs and run
the command below manually if setup reports errors; Guardian's generated
setup wrapper can log errors without failing container creation.

```sh
# In the IDE's mounted project root:
sudo apt-get update
sudo apt-get install -y --no-install-recommends build-essential device-tree-compiler python3 kmod openssh-client sparse shellcheck cppcheck dkms lintian
make -B cli abi-test
make check check-install check-harness check-preflight check-overlay
/home/vscode/.local/bin/mise exec -- copilot --version
ssh -V
```

## Pi SSH access

The user generated a dedicated Ed25519 key inside the container at
`~/.ssh/pi_pwmstream`, and used the Mac's existing SSH access to install only
its public key on the Pi. Access was reported working. The host's shared
`id_rsa` was not copied into the container. The SSH configuration is:

```sshconfig
Host raspberrypi
    User user
    IdentityFile ~/.ssh/pi_pwmstream
    IdentitiesOnly yes
```

The private key and SSH configuration live only in the container, not the
image or project. Recreating the container loses them; generate/authorise
a replacement and remove the retired public key from the Pi as appropriate.
Do not include private keys/passphrases in project files. Agent forwarding
was considered but the forwarded agent had no identities; it is not needed
for the chosen container-local key.

Before first connection, independently verify the Pi's SSH host-key
fingerprint, then connect with `ssh user@raspberrypi` and accept only that
verified key. Never disable host-key checking. The container must be able
to resolve `raspberrypi`; use a verified IP via `--host` if Docker DNS does
not resolve the hostname. Host SSH aliases/config are not mounted.

Explicit deployment from the container:

```sh
cd <project root>  # the IDE's mounted workspace
bash dev-tools/deploy.sh --host user@raspberrypi --install-reload --test
```

This changes the Pi and emits test waveforms; it is never automatic at
container creation. The existing remote directory default is retained.
SSH known_hosts in the container home is not persisted across rebuilds
by this configuration; verify the fingerprint again when necessary.

## Copilot and session continuity

Authenticate Copilot manually after opening the container (start `copilot`
and follow its login instructions). Copilot state is kept only in the
container's writable layer: no Copilot volume or host session directory is
mounted. Deleting/recreating the container loses its local sessions and
settings. No host credentials or session state are automatically copied.

Use `copilot --help` to inspect resume options for the installed version.
The same GitHub account does not guarantee transfer of local conversation
history. The chosen continuation method is a new CLI session reading
the maintainer's private `plan/` notes (not in the repository) and the READMEs, not copying the host session.
Authentication stored outside
`.copilot` may need repeating after rebuild.

If a noninteractive shell reports `copilot: not found`, use
`/home/vscode/.local/bin/mise exec -- copilot` to start it. Guardian installs
Copilot through mise and activates shims in bashrc, which noninteractive
setup shells do not necessarily read. Project setup therefore uses mise
explicitly rather than relying on inherited shell activation.
